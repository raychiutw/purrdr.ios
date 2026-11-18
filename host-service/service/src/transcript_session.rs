//! 一條 app 連線上的對話紀錄操作(#59):記住這條連線定位過的路徑，視窗與追蹤只接受這些路徑。

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::mpsc::UnboundedSender;
use tokio::task::JoinHandle;

use crate::http::blocking;
use crate::protocol::{
    ErrorCode, ErrorMessage, ServerMessage, TranscriptFollow, TranscriptFollowResult, TranscriptLocateResult, TranscriptRecord, TranscriptStreamEnd,
    TranscriptUnfollow, TranscriptUnfollowResult, TranscriptUpdate, TranscriptWindow, TranscriptWindowResult,
};
use crate::transcript::{self, AgentSessionInfo, Record, Tail, TranscriptEnvironment, TranscriptFailure};

/// 追蹤中的對話紀錄多久檢查一次(主機本機的檔案大小，不經 herdr)。
const FOLLOW_INTERVAL: Duration = Duration::from_millis(250);

pub(crate) struct TranscriptSession {
    environment: TranscriptEnvironment,
    located: HashSet<String>,
    /// 追蹤中的串流;連線結束(drop)時全部停止。
    streams: HashMap<String, JoinHandle<()>>,
    /// 推送給 app 的訊息。
    pushes: UnboundedSender<ServerMessage>,
}

impl Drop for TranscriptSession {
    fn drop(&mut self) {
        for stream in self.streams.values() {
            stream.abort();
        }
    }
}

impl TranscriptSession {
    pub fn new(environment: TranscriptEnvironment, pushes: UnboundedSender<ServerMessage>) -> Self {
        TranscriptSession {
            environment,
            located: HashSet::new(),
            streams: HashMap::new(),
            pushes,
        }
    }

    /// 開始追蹤：回應帶游標之後已有的完整行，之後新增的行以 `transcript.update` 推送。
    pub async fn follow(&mut self, request: TranscriptFollow) -> ServerMessage {
        if !self.located.contains(&request.path) {
            return failure_message(request.request_id, TranscriptFailure::NotAllowed);
        }
        if self.streams.contains_key(&request.stream_id) {
            return invalid(request.request_id, "stream_id is already in use");
        }
        let (Ok(from), Ok(limit)) = (u64::try_from(request.from), u64::try_from(request.limit)) else {
            return invalid(request.request_id, "from and limit must not be negative");
        };
        let path = PathBuf::from(&request.path);
        let reading = path.clone();
        let tail = blocking(move || {
            let anchor = transcript::anchor(&reading, from)?;
            transcript::tail(&reading, from, limit, &anchor)
        })
        .await;
        let tail = match tail {
            Ok(tail) => tail,
            Err(failure) => return failure_message(request.request_id, failure),
        };
        let update = StreamUpdate::from_tail(from, tail);
        if update.ended.is_none() {
            let task = tokio::spawn(track(path, update.cursor, update.anchor, limit, request.stream_id.clone(), self.pushes.clone()));
            self.streams.insert(request.stream_id.clone(), task);
        }
        ServerMessage::TranscriptFollowResult(TranscriptFollowResult {
            request_id: request.request_id,
            stream_id: request.stream_id,
            size: update.size as i64,
            start: from as i64,
            records: protocol_records(update.records),
            ended: update.ended,
        })
    }

    /// 停止追蹤(不認得的串流也回成功)。
    pub fn unfollow(&mut self, request: TranscriptUnfollow) -> ServerMessage {
        if let Some(stream) = self.streams.remove(&request.stream_id) {
            stream.abort();
        }
        ServerMessage::TranscriptUnfollowResult(TranscriptUnfollowResult {
            request_id: request.request_id,
        })
    }

    /// 定位並取得大小;成功後這個路徑才可讀。
    pub async fn locate(&mut self, request_id: String, session: AgentSessionInfo, header: bool) -> ServerMessage {
        let environment = self.environment.clone();
        let located = blocking(move || {
            let path = transcript::locate(&environment, &session)?;
            let size = transcript::probe(&path)?;
            let header = if header { Some(transcript::header_lines(&path)?) } else { None };
            Ok::<_, TranscriptFailure>((path, size, header))
        })
        .await;
        match located {
            Ok((path, size, header)) => {
                let path = path.to_string_lossy().into_owned();
                self.located.insert(path.clone());
                ServerMessage::TranscriptLocateResult(TranscriptLocateResult {
                    request_id,
                    path,
                    size: size as i64,
                    header,
                })
            }
            Err(failure) => failure_message(request_id, failure),
        }
    }

    /// 讀視窗;路徑必須是這條連線定位過的。
    pub async fn window(&self, request: TranscriptWindow) -> ServerMessage {
        if !self.located.contains(&request.path) {
            return failure_message(request.request_id, TranscriptFailure::NotAllowed);
        }
        let (Ok(end), Ok(lines)) = (u64::try_from(request.end), usize::try_from(request.lines)) else {
            return invalid(request.request_id, "end and lines must not be negative");
        };
        if lines == 0 {
            return invalid(request.request_id, "lines must be positive");
        }
        let path = PathBuf::from(&request.path);
        match blocking(move || transcript::window(&path, end, lines)).await {
            Ok(chunk) => ServerMessage::TranscriptWindowResult(TranscriptWindowResult {
                request_id: request.request_id,
                start: chunk.start as i64,
                end: chunk.end as i64,
                records: protocol_records(chunk.records),
            }),
            Err(failure) => failure_message(request.request_id, failure),
        }
    }
}

/// 一次檢查的結果。
struct StreamUpdate {
    size: u64,
    records: Vec<Record>,
    /// 下一次從這裡讀。
    cursor: u64,
    /// 下一次讀時比對的游標前內容。
    anchor: Vec<u8>,
    ended: Option<TranscriptStreamEnd>,
}

impl StreamUpdate {
    fn from_tail(from: u64, tail: Tail) -> Self {
        let ended = |size, reason| StreamUpdate {
            size,
            records: Vec::new(),
            cursor: from,
            anchor: Vec::new(),
            ended: Some(reason),
        };
        match tail {
            Tail::Lines { size, chunk, anchor } => StreamUpdate {
                size,
                records: chunk.records,
                cursor: chunk.end,
                anchor,
                ended: None,
            },
            Tail::Shrank { size } => ended(size, TranscriptStreamEnd::Shrank),
            Tail::Replaced { size } => ended(size, TranscriptStreamEnd::Replaced),
            Tail::TooFarBehind { size } => ended(size, TranscriptStreamEnd::TooFarBehind),
        }
    }

    fn from_failure(from: u64, failure: TranscriptFailure) -> Self {
        let reason = match failure {
            TranscriptFailure::Absent => TranscriptStreamEnd::Absent,
            _ => TranscriptStreamEnd::Unreadable,
        };
        StreamUpdate {
            size: 0,
            records: Vec::new(),
            cursor: from,
            anchor: Vec::new(),
            ended: Some(reason),
        }
    }
}

/// 定期檢查檔案，有新的完整行就推送;檔案變小、被換掉、落後太多、讀不到時推送結束原因後停止。
async fn track(path: PathBuf, mut cursor: u64, mut anchor: Vec<u8>, limit: u64, stream_id: String, pushes: UnboundedSender<ServerMessage>) {
    loop {
        tokio::time::sleep(FOLLOW_INTERVAL).await;
        let reading = path.clone();
        let from = cursor;
        let comparing = anchor.clone();
        let update = match blocking(move || transcript::tail(&reading, from, limit, &comparing)).await {
            Ok(tail) => StreamUpdate::from_tail(from, tail),
            Err(failure) => StreamUpdate::from_failure(from, failure),
        };
        if update.ended.is_none() && update.records.is_empty() {
            continue;
        }
        let ended = update.ended.is_some();
        cursor = update.cursor;
        anchor = update.anchor;
        let message = ServerMessage::TranscriptUpdate(TranscriptUpdate {
            stream_id: stream_id.clone(),
            size: update.size as i64,
            start: from as i64,
            records: protocol_records(update.records),
            ended: update.ended,
        });
        if pushes.send(message).is_err() || ended {
            return;
        }
    }
}

fn protocol_records(records: Vec<Record>) -> Vec<TranscriptRecord> {
    records
        .into_iter()
        .map(|record| TranscriptRecord {
            length: record.length as i64,
            text: record.text,
        })
        .collect()
}

fn invalid(request_id: String, message: &str) -> ServerMessage {
    error_message(request_id, ErrorCode::InvalidMessage, message)
}

fn error_message(request_id: String, code: ErrorCode, message: &str) -> ServerMessage {
    ServerMessage::ErrorMessage(ErrorMessage {
        request_id: Some(request_id),
        code,
        message: message.to_owned(),
        herdr_code: None,
        supported_protocol_versions: None,
    })
}

fn failure_message(request_id: String, failure: TranscriptFailure) -> ServerMessage {
    let (code, message) = match failure {
        TranscriptFailure::Absent => (ErrorCode::TranscriptAbsent, "transcript does not exist yet"),
        TranscriptFailure::Unreadable => (ErrorCode::TranscriptUnreadable, "transcript is not readable"),
        TranscriptFailure::Ambiguous => (ErrorCode::TranscriptAmbiguous, "more than one transcript matches the session"),
        TranscriptFailure::Compressed => (ErrorCode::TranscriptCompressed, "only a compressed transcript exists"),
        TranscriptFailure::NotAllowed => (ErrorCode::TranscriptNotAllowed, "session reference is not allowed"),
        TranscriptFailure::Unsupported => (ErrorCode::TranscriptUnsupported, "host service cannot read this agent's transcript"),
    };
    error_message(request_id, code, message)
}
