//! 一條 app 的 WebSocket 連線：解析協定訊息，轉成 herdr 請求。只處理協定定義的訊息種類。

use std::time::{Duration, SystemTime};

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};

use crate::audit_log::{AuditEvent, AuditLog};
use crate::device_store::Device;
use crate::herdr_client::{HerdrClient, HerdrFailure};
use crate::http::{ServiceContext, blocking};
use crate::protocol::{
    Agent, AgentPrompt, AgentPromptResult, AgentSession, AgentStatus, AgentsListResult, ClientMessage, ErrorCode, ErrorMessage, HerdrServer, PROTOCOL_VERSION,
    PaneSendKeys, PaneSendKeysResult, PaneSendText, PaneSendTextResult, ServerMessage, Welcome, Workspace,
};

/// 權杖無效或已撤銷時的 close code(4000–4999 由應用程式自訂)。
pub const UNAUTHORIZED_CLOSE_CODE: u16 = 4401;

/// 主機服務內部錯誤的 close code(RFC 6455)。
const INTERNAL_ERROR_CLOSE_CODE: u16 = 1011;

/// 送出 close 後等 app 回 close 的上限。
const CLOSE_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);

/// 驗證權杖後處理到連線關閉為止。每個訊息都重新驗證，撤銷立即生效。
pub async fn serve(mut socket: WebSocket, context: ServiceContext, device_token: Option<String>) {
    let device = match context.authenticate(device_token.as_deref()).await {
        Ok(device) => device,
        Err(code) => return reject(socket, code).await,
    };
    let devices = context.devices.clone();
    let device_id = device.device_id.clone();
    if let Err(error) = blocking(move || devices.record_connection(&device_id, SystemTime::now())).await {
        eprintln!("cannot record connection: {error}");
    }
    context.audit.record(
        AuditEvent::Connected {
            device_id: device.device_id.clone(),
        },
        SystemTime::now(),
    );

    let mut connection = ClientConnection {
        herdr: context.herdr.clone(),
        audit: context.audit.clone(),
        handshaken: false,
    };
    while let Some(Ok(message)) = socket.recv().await {
        let reply = match message {
            Message::Text(text) => match context.authenticate(device_token.as_deref()).await {
                Ok(device) => connection.handle(text.as_str(), &device).await,
                Err(code) => return reject(socket, code).await,
            },
            Message::Binary(_) => error(None, ErrorCode::InvalidMessage, "binary messages are not supported"),
            Message::Close(_) => break,
            _ => continue,
        };
        if send(&mut socket, &reply).await.is_err() {
            break;
        }
    }
}

/// 送出錯誤訊息後以 close code 關閉。
async fn reject(mut socket: WebSocket, code: ErrorCode) {
    let (close_code, reason, message) = match code {
        ErrorCode::DeviceTokenRevoked => (UNAUTHORIZED_CLOSE_CODE, "device_token_revoked", "device token was revoked"),
        ErrorCode::DeviceTokenInvalid => (UNAUTHORIZED_CLOSE_CODE, "device_token_invalid", "missing or unknown device token"),
        _ => (INTERNAL_ERROR_CLOSE_CODE, "internal_error", "host service cannot read its device store"),
    };
    let _ = send(&mut socket, &error(None, code, message)).await;
    let _ = socket
        .send(Message::Close(Some(CloseFrame {
            code: close_code,
            reason: reason.into(),
        })))
        .await;
    // 等 app 回 close 再斷線;直接斷線會讓 app 收到 TCP reset 而讀不到 close code。
    let _ = tokio::time::timeout(CLOSE_HANDSHAKE_TIMEOUT, async {
        while let Some(Ok(message)) = socket.recv().await {
            if matches!(message, Message::Close(_)) {
                break;
            }
        }
    })
    .await;
}

async fn send(socket: &mut WebSocket, message: &ServerMessage) -> Result<(), axum::Error> {
    let text = serde_json::to_string(message).expect("協定訊息可序列化");
    socket.send(Message::Text(text.into())).await
}

/// 一條 app WebSocket 連線的狀態(不是 herdr 的 session)。
struct ClientConnection {
    herdr: HerdrClient,
    audit: AuditLog,
    handshaken: bool,
}

impl ClientConnection {
    async fn handle(&mut self, text: &str, device: &Device) -> ServerMessage {
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            return error(None, ErrorCode::InvalidMessage, "message is not valid JSON");
        };
        let request_id = value.get("request_id").and_then(Value::as_str).map(str::to_owned);
        let message = match serde_json::from_value::<ClientMessage>(value.clone()) {
            Ok(message) => message,
            Err(decoding_error) => return error(request_id, ErrorCode::InvalidMessage, &decoding_error.to_string()),
        };
        if message.is_write() {
            // 稽核只記操作種類與目標 Pane,不記按鍵或 prompt 內容。
            self.audit.record(
                AuditEvent::Write {
                    device_id: device.device_id.clone(),
                    operation: value["type"].as_str().unwrap_or_default().to_owned(),
                    pane_id: value["pane_id"].as_str().map(str::to_owned),
                    allowed: !device.read_only,
                },
                SystemTime::now(),
            );
            if device.read_only {
                return error(request_id, ErrorCode::ReadOnlyDevice, "this device is paired read-only");
            }
        }
        match message {
            ClientMessage::Hello(hello) => self.hello(hello.request_id, hello.protocol_version, device.read_only).await,
            ClientMessage::AgentsList(request) => self.agents_list(request.request_id).await,
            ClientMessage::PaneSendKeys(request) => self.pane_send_keys(request).await,
            ClientMessage::PaneSendText(request) => self.pane_send_text(request).await,
            ClientMessage::AgentPrompt(request) => self.agent_prompt(request).await,
        }
    }

    async fn pane_send_text(&self, request: PaneSendText) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request.request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        let params = json!({"pane_id": request.pane_id, "text": request.text});
        match self.herdr.request("pane.send_text", params).await {
            Ok(_) => ServerMessage::PaneSendTextResult(PaneSendTextResult {
                request_id: request.request_id,
            }),
            Err(failure) => herdr_error(request.request_id, "pane.send_text", failure),
        }
    }

    async fn agent_prompt(&self, request: AgentPrompt) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request.request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        let mut params = json!({"target": request.pane_id, "text": request.text});
        let mut herdr_wait = Duration::ZERO;
        if let Some(wait) = request.wait {
            herdr_wait = Duration::from_millis(u64::try_from(wait.timeout_ms).unwrap_or(0));
            params["wait"] = json!({"until": wait.until, "timeout_ms": wait.timeout_ms});
        }
        match self.herdr.request_waiting("agent.prompt", params, herdr_wait).await {
            Ok(result) => ServerMessage::AgentPromptResult(AgentPromptResult {
                request_id: request.request_id,
                delivery: result["delivery"].as_str().map(str::to_owned),
            }),
            Err(failure) => herdr_error(request.request_id, "agent.prompt", failure),
        }
    }

    async fn pane_send_keys(&self, request: PaneSendKeys) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request.request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        let params = json!({"pane_id": request.pane_id, "keys": request.keys});
        match self.herdr.request("pane.send_keys", params).await {
            Ok(_) => ServerMessage::PaneSendKeysResult(PaneSendKeysResult {
                request_id: request.request_id,
            }),
            Err(failure) => herdr_error(request.request_id, "pane.send_keys", failure),
        }
    }

    async fn hello(&mut self, request_id: String, protocol_version: i64, read_only: bool) -> ServerMessage {
        if protocol_version != PROTOCOL_VERSION {
            let mut unsupported = error_message(
                Some(request_id),
                ErrorCode::ProtocolVersionUnsupported,
                &format!("protocol version {protocol_version} is not supported"),
            );
            unsupported.supported_protocol_versions = Some(vec![PROTOCOL_VERSION]);
            return ServerMessage::ErrorMessage(unsupported);
        }
        let pong = match self.herdr.request("ping", json!({})).await {
            Ok(pong) => pong,
            Err(failure) => return herdr_error(request_id, "ping", failure),
        };
        let (Some(version), Some(protocol)) = (pong["version"].as_str(), pong["protocol"].as_i64()) else {
            return error(Some(request_id), ErrorCode::HerdrError, "herdr ping response has no version or protocol");
        };
        let mut capabilities: Vec<String> = pong["capabilities"]
            .as_object()
            .map(|flags| {
                flags
                    .iter()
                    .filter(|(_, enabled)| enabled.as_bool() == Some(true))
                    .map(|(name, _)| name.clone())
                    .collect()
            })
            .unwrap_or_default();
        capabilities.sort();
        self.handshaken = true;
        ServerMessage::Welcome(Welcome {
            request_id,
            protocol_version: PROTOCOL_VERSION,
            host_service_version: env!("CARGO_PKG_VERSION").to_owned(),
            herdr: HerdrServer {
                version: version.to_owned(),
                protocol,
                capabilities,
            },
            read_only,
        })
    }

    async fn agents_list(&self, request_id: String) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        match self.herdr.request("session.snapshot", json!({})).await {
            Ok(result) => ServerMessage::AgentsListResult(agents_list_result(request_id, result)),
            Err(failure) => herdr_error(request_id, "session.snapshot", failure),
        }
    }
}

/// herdr `session.snapshot` 的結果裡用到的部分(herdr 的 snake_case 原樣)。
/// 跟 app 端一樣寬鬆：欄位缺少或格式不對時用預設值，不讓整個列表失敗。
#[derive(Deserialize, Default)]
struct SnapshotResult {
    #[serde(default, deserialize_with = "lenient_value")]
    snapshot: HerdrSnapshot,
}

#[derive(Deserialize, Default)]
struct HerdrSnapshot {
    #[serde(default, deserialize_with = "lenient_list")]
    workspaces: Vec<HerdrWorkspace>,
    #[serde(default, deserialize_with = "lenient_list")]
    agents: Vec<HerdrAgent>,
}

#[derive(Deserialize, Default)]
struct HerdrWorkspace {
    #[serde(default, deserialize_with = "lenient_value")]
    workspace_id: String,
    #[serde(default, deserialize_with = "lenient_value")]
    label: String,
}

#[derive(Deserialize, Default)]
struct HerdrAgent {
    #[serde(default, deserialize_with = "lenient_value")]
    pane_id: String,
    #[serde(default, deserialize_with = "lenient_value")]
    workspace_id: String,
    #[serde(default, deserialize_with = "lenient_value")]
    tab_id: String,
    #[serde(default, deserialize_with = "lenient_value")]
    agent: Option<String>,
    #[serde(default, deserialize_with = "lenient_value")]
    agent_status: Option<AgentStatus>,
    #[serde(default, deserialize_with = "lenient_value")]
    terminal_title_stripped: Option<String>,
    #[serde(default, deserialize_with = "lenient_value")]
    cwd: Option<String>,
    #[serde(default, deserialize_with = "lenient_value")]
    agent_session: Option<AgentSession>,
}

/// 格式不對的值當成沒有(預設值)。
fn lenient_value<'de, D: Deserializer<'de>, T: DeserializeOwned + Default>(deserializer: D) -> Result<T, D::Error> {
    Ok(serde_json::from_value(Value::deserialize(deserializer)?).unwrap_or_default())
}

/// 不是陣列當成空的;陣列裡格式不對的項目用預設值。
fn lenient_list<'de, D: Deserializer<'de>, T: DeserializeOwned + Default>(deserializer: D) -> Result<Vec<T>, D::Error> {
    let items = match Value::deserialize(deserializer)? {
        Value::Array(items) => items,
        _ => Vec::new(),
    };
    Ok(items.into_iter().map(|item| serde_json::from_value(item).unwrap_or_default()).collect())
}

fn agents_list_result(request_id: String, result: Value) -> AgentsListResult {
    let snapshot = serde_json::from_value::<SnapshotResult>(result).unwrap_or_default().snapshot;
    let workspaces = snapshot
        .workspaces
        .into_iter()
        .map(|workspace| Workspace {
            workspace_id: workspace.workspace_id,
            label: workspace.label,
        })
        .collect();
    let agents = snapshot
        .agents
        .into_iter()
        .map(|agent| Agent {
            pane_id: agent.pane_id,
            workspace_id: agent.workspace_id,
            tab_id: agent.tab_id,
            agent: agent.agent,
            status: agent.agent_status.unwrap_or(AgentStatus::Unknown),
            title: agent.terminal_title_stripped,
            cwd: agent.cwd,
            session: agent.agent_session,
        })
        .collect();
    AgentsListResult {
        request_id,
        workspaces,
        agents,
    }
}

fn herdr_error(request_id: String, method: &str, failure: HerdrFailure) -> ServerMessage {
    if failure.is_unknown_method(method) {
        return error(
            Some(request_id),
            ErrorCode::HerdrCapabilityMissing,
            &format!("herdr server does not support {method}"),
        );
    }
    match failure {
        HerdrFailure::Unavailable(message) => error(Some(request_id), ErrorCode::HerdrUnavailable, &message),
        HerdrFailure::UnexpectedResponse(message) => error(Some(request_id), ErrorCode::HerdrError, &message),
        HerdrFailure::Herdr { code, message } => {
            let mut herdr_error = error_message(Some(request_id), ErrorCode::HerdrError, &message);
            herdr_error.herdr_code = Some(code);
            ServerMessage::ErrorMessage(herdr_error)
        }
    }
}

fn error_message(request_id: Option<String>, code: ErrorCode, message: &str) -> ErrorMessage {
    ErrorMessage {
        request_id,
        code,
        message: message.to_owned(),
        herdr_code: None,
        supported_protocol_versions: None,
    }
}

fn error(request_id: Option<String>, code: ErrorCode, message: &str) -> ServerMessage {
    ServerMessage::ErrorMessage(error_message(request_id, code, message))
}
