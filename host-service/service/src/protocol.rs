//! 由 protocol/host-service.schema.json 產生，不要手動修改。重新產生:cd host-service && cargo run -p protocol-codegen

use serde::{Deserialize, Serialize};

/// 協定版本(schema 的 `x-protocol-version`)。
pub const PROTOCOL_VERSION: i64 = 1;

/// app 送給主機服務的訊息，以 type 區分。標 x-write 的是寫入類操作，唯讀裝置送出時被拒絕(read_only_device)。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "hello")]
    Hello(Hello),
    #[serde(rename = "agents.list")]
    AgentsList(AgentsList),
    #[serde(rename = "pane.send_keys")]
    PaneSendKeys(PaneSendKeys),
    #[serde(rename = "pane.terminal.open")]
    PaneTerminalOpen(PaneTerminalOpen),
    #[serde(rename = "pane.terminal.input")]
    PaneTerminalInput(PaneTerminalInput),
    #[serde(rename = "pane.terminal.resize")]
    PaneTerminalResize(PaneTerminalResize),
    #[serde(rename = "pane.terminal.scroll")]
    PaneTerminalScroll(PaneTerminalScroll),
    #[serde(rename = "pane.terminal.close")]
    PaneTerminalClose(PaneTerminalClose),
}

impl ClientMessage {
    /// 寫入類訊息(schema 的 `x-write`);唯讀裝置送出時被拒絕。
    pub fn is_write(&self) -> bool {
        matches!(self, ClientMessage::PaneSendKeys(_) | ClientMessage::PaneTerminalInput(_) | ClientMessage::PaneTerminalResize(_) | ClientMessage::PaneTerminalScroll(_))
    }
}

/// 主機服務送給 app 的訊息，以 type 區分。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "welcome")]
    Welcome(Welcome),
    #[serde(rename = "agents.list.result")]
    AgentsListResult(AgentsListResult),
    #[serde(rename = "pane.send_keys.result")]
    PaneSendKeysResult(PaneSendKeysResult),
    #[serde(rename = "pane.terminal.open.result")]
    PaneTerminalOpenResult(PaneTerminalOpenResult),
    #[serde(rename = "pane.terminal.frame")]
    PaneTerminalFrame(PaneTerminalFrame),
    #[serde(rename = "pane.terminal.closed")]
    PaneTerminalClosed(PaneTerminalClosed),
    #[serde(rename = "error")]
    ErrorMessage(ErrorMessage),
}

/// 握手：連線後第一個請求，帶 app 使用的協定版本。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hello {
    /// 請求識別碼，回應帶回同一個值。
    pub request_id: String,
    pub protocol_version: i64,
    /// app 版本，只用於診斷。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
}

/// 握手成功：主機服務的協定版本、版本，以及 herdr 伺服器 ping 回報的版本與能力。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Welcome {
    pub request_id: String,
    pub protocol_version: i64,
    pub host_service_version: String,
    pub herdr: HerdrServer,
}

/// herdr 伺服器(不是 CLI)的版本與能力。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HerdrServer {
    pub version: String,
    pub protocol: i64,
    /// ping 的 capabilities 裡值為 true 的名稱。
    pub capabilities: Vec<String>,
}

/// 取得 Agent 列表(herdr session.snapshot)。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentsList {
    pub request_id: String,
}

/// Agent 列表與它們所在的 workspace。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentsListResult {
    pub request_id: String,
    pub workspaces: Vec<Workspace>,
    pub agents: Vec<Agent>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workspace {
    pub workspace_id: String,
    pub label: String,
}

/// herdr 在某個 Pane 偵測到的 Agent。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Agent {
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    /// herdr 的 agent 名稱，例如 claude、codex。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    pub status: AgentStatus,
    /// 去掉狀態符號的終端機標題。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<AgentSession>,
}

/// herdr 回報的 Agent 狀態。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AgentStatus {
    #[serde(rename = "idle")]
    Idle,
    #[serde(rename = "working")]
    Working,
    #[serde(rename = "blocked")]
    Blocked,
    #[serde(rename = "done")]
    Done,
    #[serde(rename = "unknown")]
    Unknown,
}

/// herdr 的 agent_session:定位對話紀錄用。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentSession {
    pub source: String,
    pub agent: String,
    pub kind: String,
    pub value: String,
}

/// 對 Pane 送出按鍵(herdr pane.send_keys)。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneSendKeys {
    pub request_id: String,
    pub pane_id: String,
    /// herdr 鍵名，例如 enter、esc、ctrl+c。
    pub keys: Vec<String>,
}

/// 按鍵已送到 Pane。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneSendKeysResult {
    pub request_id: String,
}

/// 開 Pane 終端機(ADR-0005):主機服務以子行程執行 herdr terminal session control;唯讀裝置改用 observe(只能看)。串流識別碼就是這個請求的 request_id。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalOpen {
    pub request_id: String,
    /// pane id 或 terminal id。
    pub target: String,
    pub columns: i64,
    pub rows: i64,
    /// 接管別人正在操作的 Pane(唯讀裝置忽略)。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub takeover: Option<bool>,
}

/// Pane 終端機已開啟;畫面更新接著以 pane.terminal.frame 送出，結束時送 pane.terminal.closed。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalOpenResult {
    pub request_id: String,
    /// 等於開啟請求的 request_id。
    pub stream_id: String,
    /// 唯讀裝置以 observe 接上：只能看，輸入會被拒絕。
    pub read_only: bool,
}

/// 一次畫面更新:herdr terminal.frame 原樣轉接。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalFrame {
    pub stream_id: String,
    /// 每條連線從 1 起算。
    pub seq: i64,
    pub width: i64,
    pub height: i64,
    /// true 是完整重繪。
    pub full: bool,
    /// ANSI 畫面 bytes 的標準 base64。
    pub bytes: String,
}

/// Pane 終端機結束，之後這個串流不再有訊息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalClosed {
    pub stream_id: String,
    pub ending: PaneTerminalEnding,
    /// ending 是 closed 時,herdr terminal.closed 的原文。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// ending 是 failed 時,herdr 的 exit code。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    /// ending 是 failed 時,herdr 的 stderr(給開發者看)。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// closed:herdr 送了 terminal.closed;disconnected:沒有 terminal.closed 就斷了(可重新連線);failed:herdr 沒跑起來。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PaneTerminalEnding {
    #[serde(rename = "closed")]
    Closed,
    #[serde(rename = "disconnected")]
    Disconnected,
    #[serde(rename = "failed")]
    Failed,
}

/// Pane 終端機的鍵盤輸入(herdr terminal.input)。不回應;稽核只在開啟時記一筆，不記內容。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalInput {
    pub stream_id: String,
    /// 輸入 bytes 的標準 base64,每則不超過 64 KiB。
    pub bytes: String,
}

/// 改變 viewport 格數(herdr terminal.resize)。不回應。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalResize {
    pub stream_id: String,
    pub columns: i64,
    pub rows: i64,
}

/// 捲動(herdr terminal.scroll,source 固定 wheel)。不回應。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalScroll {
    pub stream_id: String,
    pub direction: TerminalScrollDirection,
    pub lines: i64,
    pub column: i64,
    pub row: i64,
}

/// 捲動方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TerminalScrollDirection {
    #[serde(rename = "up")]
    Up,
    #[serde(rename = "down")]
    Down,
}

/// 關閉 Pane 終端機:control 關閉 stdin(等同 release),observe 結束子行程。不回應。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneTerminalClose {
    pub stream_id: String,
}

/// POST /v1/pair 的本文：以配對碼換裝置權杖。QR code 的內容是 purrdr://pair?address=<HTTPS 位址>&code=<配對碼>。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairRequest {
    /// 大小寫與連字號不拘，例如 K7QM-2XPA。
    pub pairing_code: String,
    /// 顯示在主機裝置列表的名稱。
    pub device_name: String,
}

/// 配對成功。device_token 只在這裡出現一次，主機只存雜湊。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairResponse {
    pub device_id: String,
    pub device_token: String,
    /// 唯讀裝置的寫入類操作會被拒絕(read_only_device)。
    pub read_only: bool,
}

/// 請求失敗(WSS 訊息，也是配對與撤銷 HTTPS 請求失敗時的本文)。訊息本身無法解析時沒有 request_id。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorMessage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub code: ErrorCode,
    /// 給開發者看的說明，不顯示給使用者。
    pub message: String,
    /// code 是 herdr_error 時，herdr 原本的錯誤碼。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub herdr_code: Option<String>,
    /// code 是 protocol_version_unsupported 時，主機服務支援的協定版本。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supported_protocol_versions: Option<Vec<i64>>,
}

/// 錯誤種類。WSS 收到 device_token_invalid／device_token_revoked 後，主機服務以 close code 4401 關閉連線;HTTPS 請求回 401。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ErrorCode {
    #[serde(rename = "invalid_message")]
    InvalidMessage,
    #[serde(rename = "handshake_required")]
    HandshakeRequired,
    #[serde(rename = "protocol_version_unsupported")]
    ProtocolVersionUnsupported,
    #[serde(rename = "herdr_unavailable")]
    HerdrUnavailable,
    #[serde(rename = "herdr_capability_missing")]
    HerdrCapabilityMissing,
    #[serde(rename = "herdr_error")]
    HerdrError,
    #[serde(rename = "device_token_invalid")]
    DeviceTokenInvalid,
    #[serde(rename = "device_token_revoked")]
    DeviceTokenRevoked,
    #[serde(rename = "read_only_device")]
    ReadOnlyDevice,
    #[serde(rename = "pairing_code_invalid")]
    PairingCodeInvalid,
    #[serde(rename = "pairing_code_expired")]
    PairingCodeExpired,
    #[serde(rename = "internal_error")]
    InternalError,
}
