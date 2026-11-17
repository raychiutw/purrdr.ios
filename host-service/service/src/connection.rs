//! 一條 app 的 WebSocket 連線：解析協定訊息，轉成 herdr 請求。只處理協定定義的訊息種類。

use futures_util::{SinkExt, StreamExt};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;

use crate::herdr_client::{HerdrClient, HerdrFailure};
use crate::protocol::{
    Agent, AgentSession, AgentStatus, AgentsListResult, ClientMessage, ErrorCode, ErrorMessage, HerdrServer, PROTOCOL_VERSION, ServerMessage, Welcome,
    Workspace,
};

/// app 連線的 WebSocket 路徑。
pub const WEBSOCKET_PATH: &str = "/v1/ws";

/// 只有協定路徑升級成 WebSocket,其他回 404。
#[allow(clippy::result_large_err)] // 回傳型別由 tungstenite 的 callback 規定。
fn only_protocol_path(request: &Request, response: Response) -> Result<Response, ErrorResponse> {
    if request.uri().path() == WEBSOCKET_PATH {
        Ok(response)
    } else {
        let mut not_found = ErrorResponse::new(None);
        *not_found.status_mut() = StatusCode::NOT_FOUND;
        Err(not_found)
    }
}

/// 接受一條連線並處理到它關閉為止。
pub async fn serve(stream: TcpStream, herdr: HerdrClient) {
    let Ok(mut websocket) = tokio_tungstenite::accept_hdr_async(stream, only_protocol_path).await else {
        return;
    };
    let mut connection = ClientConnection { herdr, handshaken: false };
    while let Some(Ok(message)) = websocket.next().await {
        let reply = match message {
            Message::Text(text) => connection.handle(text.as_str()).await,
            Message::Binary(_) => error(None, ErrorCode::InvalidMessage, "binary messages are not supported"),
            Message::Close(_) => break,
            _ => continue,
        };
        let text = serde_json::to_string(&reply).expect("協定訊息可序列化");
        if websocket.send(Message::text(text)).await.is_err() {
            break;
        }
    }
}

/// 一條 app WebSocket 連線的狀態(不是 herdr 的 session)。
struct ClientConnection {
    herdr: HerdrClient,
    handshaken: bool,
}

impl ClientConnection {
    async fn handle(&mut self, text: &str) -> ServerMessage {
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            return error(None, ErrorCode::InvalidMessage, "message is not valid JSON");
        };
        let message = match serde_json::from_value::<ClientMessage>(value.clone()) {
            Ok(message) => message,
            Err(decoding_error) => {
                let request_id = value.get("request_id").and_then(Value::as_str).map(str::to_owned);
                return error(request_id, ErrorCode::InvalidMessage, &decoding_error.to_string());
            }
        };
        match message {
            ClientMessage::Hello(hello) => self.hello(hello.request_id, hello.protocol_version).await,
            ClientMessage::AgentsList(request) => self.agents_list(request.request_id).await,
        }
    }

    async fn hello(&mut self, request_id: String, protocol_version: i64) -> ServerMessage {
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
