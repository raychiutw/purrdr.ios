//! 一條 app 的 WebSocket 連線：解析協定訊息，轉成 herdr 請求。只處理協定定義的訊息種類。

use std::collections::HashMap;
use std::time::{Duration, SystemTime};

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::audit_log::{AuditEvent, AuditLog};
use crate::device_store::Device;
use crate::herdr_cli::HerdrCli;
use crate::herdr_client::{HerdrClient, HerdrFailure, HerdrSubscription};
use crate::host_files::{self, FileAccessScope, FileSnapshot, Located};
use crate::http::{ServiceContext, blocking};
use crate::pane_terminal::{self, PaneTerminal};
use crate::protocol::{
    Agent, AgentPrompt, AgentPromptResult, AgentSession, AgentStatus, AgentsListResult, ClientMessage, ErrorCode, ErrorMessage, EventsEnded, EventsSubscribe,
    EventsSubscribeResult, EventsUnsubscribeResult, FileRead, FileReadResult, FileStat, FileStatResult, FileStatus, HerdrServer, PROTOCOL_VERSION,
    PaneSendKeys, PaneSendKeysResult, PaneSendText, PaneSendTextResult, PaneTerminalOpen, PaneTerminalOpenResult, ServerMessage, SubscribedEvent,
    TerminalScrollDirection, TerminalScrollSource, TranscriptLocate, Welcome, Workspace,
};
use crate::transcript::AgentSessionInfo;
use crate::transcript_session::TranscriptSession;

/// 權杖無效或已撤銷時的 close code(4000–4999 由應用程式自訂)。
pub const UNAUTHORIZED_CLOSE_CODE: u16 = 4401;

/// 主機服務內部錯誤的 close code(RFC 6455)。
const INTERNAL_ERROR_CLOSE_CODE: u16 = 1011;

/// 送出 close 後等 app 回 close 的上限。
const CLOSE_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);

/// 驗證權杖後處理到連線關閉為止。每個訊息都重新驗證，撤銷立即生效。
pub async fn serve(socket: WebSocket, context: ServiceContext, device_token: Option<String>) {
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

    // 讀取、處理、送出分開：處理請求(等 herdr)時仍持續收訊息、回 pong,事件與心跳也能隨時送出。
    let heartbeat = context.heartbeat;
    let (sink, mut incoming) = socket.split();
    let (outbound, outbound_queue) = mpsc::unbounded_channel();
    // 串流(對話紀錄追蹤)推送的訊息也由送出段送出;連線結束時 `connection` 一起 drop,串流隨之停止。
    let (pushes, pushed) = mpsc::unbounded_channel();
    // Pane 終端機的畫面更新：有界，送出段跟不上時 herdr 那端等(herdr 只送最新畫面)。
    let (terminal_frames, terminal_frame_queue) = mpsc::channel(TERMINAL_FRAME_CAPACITY);
    let writer = tokio::spawn(write_outbound(sink, outbound_queue, pushed, terminal_frame_queue, heartbeat.interval));
    let (requests, request_queue) = mpsc::unbounded_channel();
    let connection = ClientConnection {
        herdr: context.herdr.clone(),
        herdr_cli: context.herdr_cli.clone(),
        audit: context.audit.clone(),
        outbound: outbound.clone(),
        handshaken: false,
        transcripts: TranscriptSession::new(context.transcripts.clone(), pushes),
        subscriptions: HashMap::new(),
        accepted_subscription: None,
        terminals: HashMap::new(),
        terminal_frames,
        file_snapshot: None,
    };
    let handler = tokio::spawn(handle_requests(connection, request_queue, context, device_token));
    // 逾時沒收到任何 frame(含 pong)就當作 app 已經不在。
    while let Ok(Some(Ok(message))) = tokio::time::timeout(heartbeat.timeout, incoming.next()).await {
        match message {
            Message::Text(text) => {
                let _ = requests.send(text.to_string());
            }
            Message::Binary(_) => {
                let _ = outbound.send(Outbound::Message(error(None, ErrorCode::InvalidMessage, "binary messages are not supported")));
            }
            Message::Close(_) => break,
            _ => continue,
        }
    }
    // 結束處理就放掉這條連線的 herdr 訂閱，Pane 終端機的子行程一併收尾。
    handler.abort();
    writer.abort();
}

/// Pane 終端機畫面更新等待送出的上限。
const TERMINAL_FRAME_CAPACITY: usize = 32;

/// 要送給 app 的訊息。
enum Outbound {
    Message(ServerMessage),
    /// 送出 close frame 後不再送任何東西。
    Close(CloseFrame),
}

/// 依序送出訊息，並每 `ping_interval` 送一次 ping。
async fn write_outbound(
    mut sink: SplitSink<WebSocket, Message>,
    mut queue: mpsc::UnboundedReceiver<Outbound>,
    mut pushes: mpsc::UnboundedReceiver<ServerMessage>,
    mut terminal_frames: mpsc::Receiver<ServerMessage>,
    ping_interval: Duration,
) {
    let mut pings = tokio::time::interval_at(tokio::time::Instant::now() + ping_interval, ping_interval);
    loop {
        let (frame, last) = tokio::select! {
            item = queue.recv() => match item {
                Some(Outbound::Message(message)) => (Message::Text(serde_json::to_string(&message).expect("協定訊息可序列化").into()), false),
                Some(Outbound::Close(frame)) => (Message::Close(Some(frame)), true),
                None => return,
            },
            Some(push) = pushes.recv() => (Message::Text(serde_json::to_string(&push).expect("協定訊息可序列化").into()), false),
            Some(frame) = terminal_frames.recv() => (Message::Text(serde_json::to_string(&frame).expect("協定訊息可序列化").into()), false),
            _ = pings.tick() => (Message::Ping(Default::default()), false),
        };
        if sink.send(frame).await.is_err() || last {
            return;
        }
    }
}

/// 依序處理請求;每個訊息都重新驗證權杖，被拒時送錯誤與 close frame 後停止。
async fn handle_requests(mut connection: ClientConnection, mut queue: mpsc::UnboundedReceiver<String>, context: ServiceContext, device_token: Option<String>) {
    while let Some(text) = queue.recv().await {
        match context.authenticate(device_token.as_deref()).await {
            Ok(device) => connection.handle(&text, &device).await,
            Err(code) => {
                let (message, frame) = rejection(code);
                let _ = connection.outbound.send(Outbound::Message(message));
                let _ = connection.outbound.send(Outbound::Close(frame));
                return;
            }
        }
    }
}

/// 權杖被拒時的錯誤訊息與 close frame。
fn rejection(code: ErrorCode) -> (ServerMessage, CloseFrame) {
    let (close_code, reason, message) = match code {
        ErrorCode::DeviceTokenRevoked => (UNAUTHORIZED_CLOSE_CODE, "device_token_revoked", "device token was revoked"),
        ErrorCode::DeviceTokenInvalid => (UNAUTHORIZED_CLOSE_CODE, "device_token_invalid", "missing or unknown device token"),
        _ => (INTERNAL_ERROR_CLOSE_CODE, "internal_error", "host service cannot read its device store"),
    };
    (
        error(None, code, message),
        CloseFrame {
            code: close_code,
            reason: reason.into(),
        },
    )
}

/// 連線一開始權杖就被拒：送出錯誤訊息後以 close code 關閉。
async fn reject(mut socket: WebSocket, code: ErrorCode) {
    let (message, frame) = rejection(code);
    let _ = send(&mut socket, &message).await;
    let _ = socket.send(Message::Close(Some(frame))).await;
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

/// 一條 app WebSocket 連線的狀態(不是 herdr 的 session)。drop 時結束這條連線的 herdr 訂閱。
struct ClientConnection {
    herdr: HerdrClient,
    audit: AuditLog,
    outbound: mpsc::UnboundedSender<Outbound>,
    handshaken: bool,
    transcripts: TranscriptSession,
    /// 事件串流識別碼 → 轉送 herdr 事件的 task。
    subscriptions: HashMap<String, JoinHandle<()>>,
    /// herdr 剛接受、等訂閱結果送出後才開始轉送的訂閱。
    accepted_subscription: Option<(String, HerdrSubscription)>,
    herdr_cli: HerdrCli,
    /// 開著的 Pane 終端機，以串流識別碼(開啟請求的 request_id)為 key;drop 時子行程收尾。
    terminals: HashMap<String, PaneTerminal>,
    terminal_frames: mpsc::Sender<ServerMessage>,
    /// 主機取檔最近一次從頭讀的快照。
    file_snapshot: Option<FileSnapshot>,
}

impl Drop for ClientConnection {
    fn drop(&mut self) {
        for forwarding in self.subscriptions.values() {
            forwarding.abort();
        }
    }
}

impl ClientConnection {
    async fn handle(&mut self, text: &str, device: &Device) {
        // Pane 終端機的輸入與關閉沒有回應。
        if let Some(reply) = self.reply(text, device).await {
            let _ = self.outbound.send(Outbound::Message(reply));
        }
        // 訂閱結果送出後才開始轉送，事件不會比結果早到。
        if let Some((stream_id, subscription)) = self.accepted_subscription.take() {
            self.start_forwarding(stream_id, subscription);
        }
    }

    async fn reply(&mut self, text: &str, device: &Device) -> Option<ServerMessage> {
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            return Some(error(None, ErrorCode::InvalidMessage, "message is not valid JSON"));
        };
        let request_id = value.get("request_id").and_then(Value::as_str).map(str::to_owned);
        let message = match serde_json::from_value::<ClientMessage>(value.clone()) {
            Ok(message) => message,
            Err(decoding_error) => return Some(error(request_id, ErrorCode::InvalidMessage, &decoding_error.to_string())),
        };
        if message.is_write() {
            // 稽核只記操作種類與目標 Pane,不記按鍵或 prompt 內容;串流上的輸入(沒有請求識別碼，例如 Pane 終端機的按鍵)
            // 不逐則記，Pane 終端機只在開啟時記一筆。
            if request_id.is_some() {
                self.audit.record(
                    AuditEvent::Write {
                        device_id: device.device_id.clone(),
                        operation: value["type"].as_str().unwrap_or_default().to_owned(),
                        pane_id: value["pane_id"].as_str().map(str::to_owned),
                        allowed: !device.read_only,
                    },
                    SystemTime::now(),
                );
            }
            if device.read_only {
                return Some(error(request_id, ErrorCode::ReadOnlyDevice, "this device is paired read-only"));
            }
        }
        let reply = match message {
            ClientMessage::Hello(hello) => self.hello(hello.request_id, hello.protocol_version, device.read_only).await,
            ClientMessage::AgentsList(request) => self.agents_list(request.request_id).await,
            ClientMessage::PaneSendKeys(request) => self.pane_send_keys(request).await,
            ClientMessage::TranscriptLocate(request) => self.transcript_locate(request).await,
            ClientMessage::TranscriptWindow(request) => self.transcripts.window(request).await,
            ClientMessage::TranscriptFollow(request) => self.transcripts.follow(request).await,
            ClientMessage::TranscriptUnfollow(request) => self.transcripts.unfollow(request),
            ClientMessage::PaneSendText(request) => self.pane_send_text(request).await,
            ClientMessage::AgentPrompt(request) => self.agent_prompt(request).await,
            ClientMessage::EventsSubscribe(request) => self.events_subscribe(request).await,
            ClientMessage::EventsUnsubscribe(request) => {
                if let Some(forwarding) = self.subscriptions.remove(&request.stream_id) {
                    forwarding.abort();
                }
                ServerMessage::EventsUnsubscribeResult(EventsUnsubscribeResult {
                    request_id: request.request_id,
                })
            }
            ClientMessage::PaneTerminalOpen(request) => self.open_terminal(request, device),
            ClientMessage::PaneTerminalInput(input) => {
                if input.bytes.len() > pane_terminal::MAX_INPUT_BASE64_LENGTH {
                    return Some(error(None, ErrorCode::InvalidMessage, "terminal input is larger than 64 KiB"));
                }
                self.terminal(&input.stream_id)?.input(input.bytes).await;
                return None;
            }
            ClientMessage::PaneTerminalResize(resize) => {
                if !pane_terminal::is_valid_size(resize.columns, resize.rows) {
                    return Some(error(None, ErrorCode::InvalidMessage, "terminal size is out of range"));
                }
                self.terminal(&resize.stream_id)?.resize(resize.columns, resize.rows).await;
                return None;
            }
            ClientMessage::PaneTerminalScroll(scroll) => {
                let direction = match scroll.direction {
                    TerminalScrollDirection::Up => "up",
                    TerminalScrollDirection::Down => "down",
                };
                let source = match scroll.source {
                    Some(TerminalScrollSource::PageKey) => "page_key",
                    Some(TerminalScrollSource::Wheel) | None => "wheel",
                };
                self.terminal(&scroll.stream_id)?
                    .scroll(direction, scroll.lines, scroll.column, scroll.row, source)
                    .await;
                return None;
            }
            ClientMessage::FileStat(request) => self.file_stat(request, device).await,
            ClientMessage::FileRead(request) => self.file_read(request, device).await,
            ClientMessage::PaneTerminalClose(close) => {
                // drop:關閉 stdin(control 等同 release)並結束子行程。
                self.terminals.remove(&close.stream_id);
                return None;
            }
        };
        Some(reply)
    }

    /// 開著的 Pane 終端機;已關閉或不存在時略過那個訊息。
    fn terminal(&mut self, stream_id: &str) -> Option<&mut PaneTerminal> {
        self.terminals.get_mut(stream_id)
    }

    /// 以子行程執行 herdr;唯讀裝置用 observe(只能看)。
    fn open_terminal(&mut self, request: PaneTerminalOpen, device: &Device) -> ServerMessage {
        let request_id = request.request_id.clone();
        if !self.handshaken {
            return error(Some(request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        if !pane_terminal::is_valid_target(&request.target) || !pane_terminal::is_valid_size(request.columns, request.rows) {
            return error(Some(request_id), ErrorCode::InvalidMessage, "invalid terminal target or size");
        }
        if self.terminals.contains_key(&request_id) {
            return error(Some(request_id), ErrorCode::InvalidMessage, "stream is already open");
        }
        let observe = device.read_only;
        let terminal = match PaneTerminal::spawn(&self.herdr_cli, &request, observe, self.terminal_frames.clone()) {
            Ok(terminal) => terminal,
            Err(spawn_error) => return error(Some(request_id), ErrorCode::HerdrUnavailable, &format!("cannot run herdr: {spawn_error}")),
        };
        if !observe {
            // 接上 Pane 是寫入類操作(會改 Pane 尺寸、可能接管):記一筆，不記之後的按鍵。
            self.audit.record(
                AuditEvent::Write {
                    device_id: device.device_id.clone(),
                    operation: "pane.terminal.open".to_owned(),
                    pane_id: Some(request.target.clone()),
                    allowed: true,
                },
                SystemTime::now(),
            );
        }
        self.terminals.insert(request_id.clone(), terminal);
        ServerMessage::PaneTerminalOpenResult(PaneTerminalOpenResult {
            request_id: request_id.clone(),
            stream_id: request_id,
            read_only: observe,
        })
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

    /// 開 herdr 訂閱;herdr 接受後先回結果，再開始轉送事件(順序不會顛倒)。
    async fn events_subscribe(&mut self, request: EventsSubscribe) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request.request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        if self.subscriptions.contains_key(&request.stream_id) {
            return error(
                Some(request.request_id),
                ErrorCode::InvalidMessage,
                "stream_id is already used on this connection",
            );
        }
        let subscriptions: Vec<Value> = request
            .subscriptions
            .iter()
            .map(|subscription| match &subscription.pane_id {
                Some(pane_id) => json!({"type": subscription.event, "pane_id": pane_id}),
                None => json!({"type": subscription.event}),
            })
            .collect();
        let subscription = match self.herdr.subscribe(json!({"subscriptions": subscriptions})).await {
            Ok(subscription) => subscription,
            Err(failure) => return herdr_error(request.request_id, "events.subscribe", failure),
        };
        self.accepted_subscription = Some((request.stream_id.clone(), subscription));
        ServerMessage::EventsSubscribeResult(EventsSubscribeResult {
            request_id: request.request_id,
            stream_id: request.stream_id,
        })
    }

    /// 轉送 herdr 事件;herdr 結束訂閱時送 `events.ended`(失敗時帶錯誤碼)。
    fn start_forwarding(&mut self, stream_id: String, mut subscription: HerdrSubscription) {
        let outbound = self.outbound.clone();
        let forwarded_stream_id = stream_id.clone();
        let forwarding = tokio::spawn(async move {
            let mut ended = EventsEnded {
                stream_id: forwarded_stream_id.clone(),
                code: None,
                message: None,
                herdr_code: None,
            };
            loop {
                match subscription.next_event().await {
                    Ok(Some(event)) => {
                        let _ = outbound.send(Outbound::Message(ServerMessage::SubscribedEvent(SubscribedEvent {
                            stream_id: forwarded_stream_id.clone(),
                            event: event["event"].as_str().unwrap_or_default().to_owned(),
                            // 有些事件的 pane id 在 data 頂層，有些包在 pane 物件內。
                            pane_id: event["data"]["pane_id"]
                                .as_str()
                                .or_else(|| event["data"]["pane"]["pane_id"].as_str())
                                .map(str::to_owned),
                        })));
                    }
                    Ok(None) => break,
                    Err(HerdrFailure::Herdr { code, message }) => {
                        ended.code = Some(ErrorCode::HerdrError);
                        ended.message = Some(message);
                        ended.herdr_code = Some(code);
                        break;
                    }
                    Err(HerdrFailure::Unavailable(message) | HerdrFailure::UnexpectedResponse(message)) => {
                        ended.code = Some(ErrorCode::HerdrUnavailable);
                        ended.message = Some(message);
                        break;
                    }
                }
            }
            let _ = outbound.send(Outbound::Message(ServerMessage::EventsEnded(ended)));
        });
        self.subscriptions.insert(stream_id, forwarding);
    }

    /// 主機取檔的範圍:herdr snapshot 目前回報的工作目錄，與這條連線定位過的對話紀錄。
    async fn file_access_scope(&self) -> Result<FileAccessScope, HerdrFailure> {
        let result = self.herdr.request("session.snapshot", json!({})).await?;
        let snapshot = serde_json::from_value::<SnapshotResult>(result).unwrap_or_default().snapshot;
        Ok(FileAccessScope {
            working_directories: snapshot.agents.into_iter().filter_map(|agent| agent.cwd).collect(),
            transcripts: self.transcripts.located_paths(),
        })
    }

    /// 套用存取規則並讀出檔案與版本(在 blocking 執行緒)。
    async fn locate_file(&self, path: &str) -> Result<Located, HerdrFailure> {
        let scope = self.file_access_scope().await?;
        let path = path.to_owned();
        Ok(blocking(move || host_files::locate(&path, &scope)).await)
    }

    fn audit_file_access(&self, device: &Device, operation: &'static str, path: &str, result: String, size: Option<u64>) {
        self.audit.record(
            AuditEvent::FileAccess {
                device_id: device.device_id.clone(),
                operation,
                path: path.to_owned(),
                result,
                size,
            },
            SystemTime::now(),
        );
    }

    async fn file_stat(&mut self, request: FileStat, device: &Device) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request.request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        let located = match self.locate_file(&request.path).await {
            Ok(located) => located,
            Err(failure) => return herdr_error(request.request_id, "session.snapshot", failure),
        };
        let (status, version, size) = match located {
            Located::File { contents, version } => (FileStatus::File, Some(version), Some(contents.len() as u64)),
            Located::Unavailable { status, size } => (status, None, size),
        };
        self.audit_file_access(device, "file.stat", &request.path, status_name(status), size);
        ServerMessage::FileStatResult(FileStatResult {
            request_id: request.request_id,
            status,
            version,
            size: size.map(|size| size as i64),
        })
    }

    /// 從頭讀或還沒有這個版本的快照時重新檢查並建快照;之後的分塊從快照讀。
    async fn file_read(&mut self, request: FileRead, device: &Device) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request.request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        let (Ok(offset), Ok(length)) = (u64::try_from(request.offset), u64::try_from(request.length)) else {
            return error(Some(request.request_id), ErrorCode::InvalidMessage, "offset and length must not be negative");
        };
        let reusable = self
            .file_snapshot
            .as_ref()
            .is_some_and(|snapshot| offset > 0 && snapshot.path == request.path && snapshot.version == request.version);
        if !reusable {
            let located = match self.locate_file(&request.path).await {
                Ok(located) => located,
                Err(failure) => return herdr_error(request.request_id, "session.snapshot", failure),
            };
            let (contents, version) = match located {
                Located::File { contents, version } => (contents, version),
                Located::Unavailable { status, size } => {
                    self.audit_file_access(device, "file.read", &request.path, status_name(status), size);
                    return ServerMessage::FileReadResult(FileReadResult {
                        request_id: request.request_id,
                        status,
                        size: size.map(|size| size as i64),
                        offset: None,
                        bytes: None,
                    });
                }
            };
            let changed = version != request.version;
            let result = if changed { "changed".to_owned() } else { status_name(FileStatus::File) };
            self.audit_file_access(device, "file.read", &request.path, result, Some(contents.len() as u64));
            self.file_snapshot = Some(FileSnapshot {
                path: request.path.clone(),
                version,
                contents,
            });
            if changed {
                return error(Some(request.request_id), ErrorCode::FileChanged, "file changed since its status was read");
            }
        }
        let snapshot = self.file_snapshot.as_ref().expect("剛建好或可沿用的快照");
        ServerMessage::FileReadResult(FileReadResult {
            request_id: request.request_id,
            status: FileStatus::File,
            size: None,
            offset: Some(offset as i64),
            bytes: Some(BASE64.encode(snapshot.chunk(offset, length))),
        })
    }

    /// 對話紀錄只能依 herdr 目前回報的 agent_session 定位(#59)。
    async fn transcript_locate(&mut self, request: TranscriptLocate) -> ServerMessage {
        if !self.handshaken {
            return error(Some(request.request_id), ErrorCode::HandshakeRequired, "send hello first");
        }
        let result = match self.herdr.request("session.snapshot", json!({})).await {
            Ok(result) => result,
            Err(failure) => return herdr_error(request.request_id, "session.snapshot", failure),
        };
        let snapshot = serde_json::from_value::<SnapshotResult>(result).unwrap_or_default().snapshot;
        let reported = snapshot.agents.iter().find(|agent| {
            agent
                .agent_session
                .as_ref()
                .is_some_and(|session| session.kind == request.session.kind && session.value == request.session.value)
        });
        let Some(agent) = reported else {
            return error(Some(request.request_id), ErrorCode::TranscriptNotAllowed, "herdr does not report this session");
        };
        let session = AgentSessionInfo {
            agent: agent.agent.clone().unwrap_or_default(),
            cwd: agent.cwd.clone().unwrap_or_default(),
            kind: request.session.kind,
            value: request.session.value,
        };
        self.transcripts.locate(request.request_id, session, request.header).await
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

/// `FileStatus` 的協定名稱(稽核紀錄用)。
fn status_name(status: FileStatus) -> String {
    serde_json::to_value(status)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
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
