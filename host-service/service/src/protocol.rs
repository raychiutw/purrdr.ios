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
    #[serde(rename = "transcript.locate")]
    TranscriptLocate(TranscriptLocate),
    #[serde(rename = "transcript.window")]
    TranscriptWindow(TranscriptWindow),
    #[serde(rename = "transcript.follow")]
    TranscriptFollow(TranscriptFollow),
    #[serde(rename = "transcript.unfollow")]
    TranscriptUnfollow(TranscriptUnfollow),
}

impl ClientMessage {
    /// 寫入類訊息(schema 的 `x-write`);唯讀裝置送出時被拒絕。
    pub fn is_write(&self) -> bool {
        matches!(self, ClientMessage::PaneSendKeys(_))
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
    #[serde(rename = "transcript.locate.result")]
    TranscriptLocateResult(TranscriptLocateResult),
    #[serde(rename = "transcript.window.result")]
    TranscriptWindowResult(TranscriptWindowResult),
    #[serde(rename = "transcript.follow.result")]
    TranscriptFollowResult(TranscriptFollowResult),
    #[serde(rename = "transcript.update")]
    TranscriptUpdate(TranscriptUpdate),
    #[serde(rename = "transcript.unfollow.result")]
    TranscriptUnfollowResult(TranscriptUnfollowResult),
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

/// 定位對話紀錄(#59)。session 必須是 herdr snapshot 目前某個 Agent 的 agent_session;格式與 cwd 由主機服務從 snapshot 取得，app 不能指定路徑。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptLocate {
    pub request_id: String,
    pub session: SessionReference,
    /// 是否一併回傳檔案前兩行(Codex、Pi／OMP 的 header 檢查)。
    pub header: bool,
}

/// herdr agent_session 的 kind 與 value。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionReference {
    /// id 或 path。
    pub kind: String,
    pub value: String,
}

/// 對話紀錄的路徑與大小(byte)。之後這條連線才能以這個路徑讀視窗與追蹤。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptLocateResult {
    pub request_id: String,
    pub path: String,
    pub size: i64,
    /// 請求 header 時，檔案前兩行(原樣)。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<Vec<String>>,
}

/// 讀以 end 為終點的最後 lines 行完整的行(開啟與往上翻頁)。path 必須是這條連線定位過的。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptWindow {
    pub request_id: String,
    pub path: String,
    pub end: i64,
    pub lines: i64,
}

/// 視窗的 byte 範圍與範圍內的行。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptWindowResult {
    pub request_id: String,
    pub start: i64,
    pub end: i64,
    pub records: Vec<TranscriptRecord>,
}

/// 對話紀錄的一行：原始 byte 長度(不含換行)與剝除圖片後的內容(行為規格 R-B04、R-B06)。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptRecord {
    pub length: i64,
    pub text: String,
}

/// 開始追蹤對話紀錄尾端：從 from 起，主機服務把新增的完整行以 transcript.update 推送，直到 transcript.unfollow、追蹤結束或連線關閉。stream_id 由 app 指定，同一條連線內不可重複。path 必須是這條連線定位過的。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptFollow {
    pub request_id: String,
    pub stream_id: String,
    pub path: String,
    pub from: i64,
    /// 一次落後超過這麼多 byte 就結束追蹤(too_far_behind),由 app 改讀視窗。
    pub limit: i64,
}

/// 追蹤開始，帶目前的大小與 from 之後已有的完整行;ended 有值時主機服務沒有開始追蹤。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptFollowResult {
    pub request_id: String,
    pub stream_id: String,
    pub size: i64,
    /// records 第一行的位置(byte)。
    pub start: i64,
    pub records: Vec<TranscriptRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended: Option<TranscriptStreamEnd>,
}

/// 追蹤中的對話紀錄有了新的完整行，或追蹤結束(ended)。主機服務主動推送，沒有 request_id。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptUpdate {
    pub stream_id: String,
    pub size: i64,
    /// records 第一行的位置(byte)。
    pub start: i64,
    pub records: Vec<TranscriptRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended: Option<TranscriptStreamEnd>,
}

/// 主機服務停止追蹤的原因:shrank 檔案變小(換新)、too_far_behind 落後超過 limit、absent 檔案不見了、unreadable 讀不到。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TranscriptStreamEnd {
    #[serde(rename = "shrank")]
    Shrank,
    #[serde(rename = "too_far_behind")]
    TooFarBehind,
    #[serde(rename = "absent")]
    Absent,
    #[serde(rename = "unreadable")]
    Unreadable,
}

/// 停止追蹤(對話關閉)。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptUnfollow {
    pub request_id: String,
    pub stream_id: String,
}

/// 已停止追蹤;之後不再推送這個 stream_id。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptUnfollowResult {
    pub request_id: String,
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

/// 錯誤種類。WSS 收到 device_token_invalid／device_token_revoked 後，主機服務以 close code 4401 關閉連線;HTTPS 請求回 401。transcript_not_allowed:session 不是 herdr 目前回報的，或路徑不是這條連線定位過的;transcript_unsupported:這種 agent 的對話紀錄主機服務還讀不了;其他 transcript_* 對應行為規格 §4.7 的缺席、不可讀、有歧義、已壓縮。
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
    #[serde(rename = "transcript_not_allowed")]
    TranscriptNotAllowed,
    #[serde(rename = "transcript_unsupported")]
    TranscriptUnsupported,
    #[serde(rename = "transcript_absent")]
    TranscriptAbsent,
    #[serde(rename = "transcript_unreadable")]
    TranscriptUnreadable,
    #[serde(rename = "transcript_ambiguous")]
    TranscriptAmbiguous,
    #[serde(rename = "transcript_compressed")]
    TranscriptCompressed,
    #[serde(rename = "internal_error")]
    InternalError,
}
