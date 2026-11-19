//! 對話紀錄(#59):依 herdr 回報的 agent_session 定位、讀視窗、追蹤尾端(行為規格 §4)。
//!
//! 只讀 agent_session 指向的檔案：位置由 agent 種類、session 與 cwd 決定，app 不能指定路徑。

use std::fs::File;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::herdr_socket::{Platform, SocketEnvironment};

/// 找對話紀錄用到的位置;沒設定的變數用各 agent 的預設。
#[derive(Debug, Clone, Default)]
pub struct TranscriptEnvironment {
    /// 家目錄(Unix `HOME`、Windows `USERPROFILE`)。
    pub home: Option<PathBuf>,
    /// `CLAUDE_CONFIG_DIR`。
    pub claude_config_dir: Option<PathBuf>,
    /// `CODEX_HOME`。
    pub codex_home: Option<PathBuf>,
}

impl TranscriptEnvironment {
    /// 依平台的家目錄變數(Unix `HOME`、Windows `USERPROFILE`)與 agent 的設定目錄變數;空字串視同未設定。
    pub fn resolve(platform: Platform, environment: &SocketEnvironment) -> Self {
        let path = |value: &Option<String>| value.as_deref().filter(|text| !text.is_empty()).map(PathBuf::from);
        let home = match platform {
            Platform::Unix => &environment.home,
            Platform::Windows => &environment.user_profile,
        };
        TranscriptEnvironment {
            home: path(home),
            claude_config_dir: path(&environment.claude_config_dir),
            codex_home: path(&environment.codex_home),
        }
    }
}

/// 讀不到對話紀錄的原因(行為規格 §4.7 的 exit code)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptFailure {
    /// 還沒有檔案(新 session)或資料夾不在。
    Absent,
    /// 權限不足。
    Unreadable,
    /// 符合的檔案不只一個：不猜。
    Ambiguous,
    /// 只有壓縮過的檔案。
    Compressed,
    /// session 參照不安全，或這種 agent 不能用這種參照。
    NotAllowed,
    /// 主機服務還不支援這種 agent。
    Unsupported,
}

/// herdr 回報的一個 Agent 裡定位對話紀錄用到的部分。
pub struct AgentSessionInfo {
    /// herdr 的 agent 名稱(claude、codex…)。
    pub agent: String,
    pub cwd: String,
    pub kind: String,
    pub value: String,
}

/// 依 agent 種類與 session 找出對話紀錄。
pub fn locate(environment: &TranscriptEnvironment, session: &AgentSessionInfo) -> Result<PathBuf, TranscriptFailure> {
    match (session.agent.as_str(), session.kind.as_str()) {
        ("claude", "id") => {
            require_safe_id(&session.value)?;
            Ok(locate_claude(environment, &session.value, &session.cwd))
        }
        ("codex", "id") => {
            require_safe_id(&session.value)?;
            locate_codex(environment, &session.value)
        }
        ("agy", "id") => {
            require_safe_id(&session.value)?;
            let brain = home_relative(environment, &[".gemini", "antigravity-cli", "brain"]);
            Ok(joined(&brain, &[&session.value, ".system_generated", "logs", "transcript.jsonl"]))
        }
        // 只有 agy、Pi、OMP 的 integration 以路徑回報(行為規格 §4.0)。
        ("agy" | "pi" | "omp", "path") if is_safe_reported_path(&session.value) => Ok(PathBuf::from(&session.value)),
        (_, "path") => Err(TranscriptFailure::NotAllowed),
        _ => Err(TranscriptFailure::Unsupported),
    }
}

/// 回報的路徑：絕對(POSIX `/…` 或 Windows `C:\…`)、`.jsonl` 結尾、沒有 `..` 段與 NUL／CR／LF。
fn is_safe_reported_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    let absolute = path.starts_with('/') || (bytes.len() > 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && matches!(bytes[2], b'\\' | b'/'));
    absolute && path.ends_with(".jsonl") && !path.contains(['\0', '\r', '\n']) && !path.split(['/', '\\']).any(|component| component == "..")
}

/// `${CODEX_HOME:-~/.codex}` 的 sessions 與 archived_sessions 下的 `rollout-*-<id>.jsonl`(含倒帶的 `_<rolloutId>`,§4.2)。
/// 不只一個時不猜(SSH 路線會問 Codex 的狀態資料庫;主機服務不執行指令，所以回有歧義)。
fn locate_codex(environment: &TranscriptEnvironment, session_id: &str) -> Result<PathBuf, TranscriptFailure> {
    let codex_home = environment.codex_home.clone().unwrap_or_else(|| home_relative(environment, &[".codex"]));
    let mut rollouts = Vec::new();
    let mut compressed = false;
    for folder in ["sessions", "archived_sessions"] {
        let mut files = Vec::new();
        collect_files(&codex_home.join(folder), CODEX_SEARCH_DEPTH, &mut files);
        for file in files {
            let Some(name) = file.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if is_codex_rollout(name, session_id, ".jsonl") {
                rollouts.push(file);
            } else if is_codex_rollout(name, session_id, ".jsonl.zst") {
                compressed = true;
            }
        }
    }
    match rollouts.len() {
        0 if compressed => Err(TranscriptFailure::Compressed),
        0 => Err(TranscriptFailure::Absent),
        1 => Ok(rollouts.remove(0)),
        _ => Err(TranscriptFailure::Ambiguous),
    }
}

/// Codex 依日期分層(`年/月/日`),再多留一層餘裕。
const CODEX_SEARCH_DEPTH: usize = 5;

/// `rollout-…-<id><extension>` 或 `rollout-…-<id>_<rolloutId><extension>`。
fn is_codex_rollout(name: &str, session_id: &str, extension: &str) -> bool {
    let Some(stem) = name.strip_prefix("rollout-").and_then(|rest| rest.strip_suffix(extension)) else {
        return false;
    };
    if stem.ends_with(&format!("-{session_id}")) {
        return true;
    }
    stem.rsplit_once(&format!("-{session_id}_"))
        .is_some_and(|(_, rollout)| !rollout.is_empty() && rollout.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'))
}

/// 資料夾下的檔案(不跟隨符號連結)。
fn collect_files(folder: &Path, depth: usize, files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() && depth > 0 {
            collect_files(&entry.path(), depth - 1, files);
        } else if file_type.is_file() {
            files.push(entry.path());
        }
    }
}

/// 檔案目前的大小;資料夾或檔案不在是缺席，權限不足是不可讀。
pub fn probe(path: &Path) -> Result<u64, TranscriptFailure> {
    let folder_exists = path.parent().is_some_and(Path::is_dir);
    if !folder_exists {
        return Err(TranscriptFailure::Absent);
    }
    let file = File::open(path).map_err(|error| match error.kind() {
        ErrorKind::NotFound => TranscriptFailure::Absent,
        _ => TranscriptFailure::Unreadable,
    })?;
    file.metadata().map(|metadata| metadata.len()).map_err(|_| TranscriptFailure::Unreadable)
}

/// 一行對話紀錄：原始 byte 長度(不含換行)與剝除圖片後的內容。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub length: u64,
    pub text: String,
}

/// 一段完整的行：`[start, end)` 的 byte 範圍。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    pub start: u64,
    pub end: u64,
    pub records: Vec<Record>,
}

/// 視窗第一次往前讀的區塊大小;行數不夠時放大 4 倍再數(與 SSH 的視窗腳本相同)。
const WINDOW_CHUNK_BYTES: u64 = 4 << 20;

/// 以 `end` 為終點往前取恰好 `lines` 行完整的行;終點是 `end` 之前最後一個換行之後(未完成的行留給追蹤)。
pub fn window(path: &Path, end: u64, lines: usize) -> Result<Chunk, TranscriptFailure> {
    let mut file = File::open(path).map_err(|_| TranscriptFailure::Unreadable)?;
    let mut chunk_bytes = WINDOW_CHUNK_BYTES;
    loop {
        let chunk_start = end.saturating_sub(chunk_bytes);
        let bytes = read_range(&mut file, chunk_start, end)?;
        // 區塊開頭不是檔頭時，第一段可能是被切斷的行，不算。
        let mut line_starts = Vec::new();
        let mut line_start = 0_usize;
        let mut complete_end = 0_usize;
        for (index, byte) in bytes.iter().enumerate() {
            if *byte != b'\n' {
                continue;
            }
            if line_start > 0 || chunk_start == 0 {
                line_starts.push(line_start);
            }
            line_start = index + 1;
            complete_end = index + 1;
        }
        if line_starts.len() < lines && chunk_start > 0 {
            chunk_bytes *= 4;
            continue;
        }
        let first = line_starts.len().saturating_sub(lines);
        let window_start = line_starts.get(first).copied().unwrap_or(complete_end);
        return Ok(Chunk {
            start: chunk_start + window_start as u64,
            end: chunk_start + complete_end as u64,
            records: records(&bytes[window_start..complete_end]),
        });
    }
}

/// 游標之後的狀態(與 SSH 的分段接著讀相同的判斷，另外比對游標前的內容)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tail {
    /// 游標之後新增的完整行(可能沒有;最多 `limit` bytes,後面還有時下一次從新游標接著讀);`anchor` 是新游標之前的內容，下次讀時比對。
    Lines { size: u64, chunk: Chunk, anchor: Vec<u8> },
    /// 檔案比游標小：被換掉了。
    Shrank { size: u64 },
    /// 游標前的內容變了：被換成同長或更長的新檔。
    Replaced { size: u64 },
}

/// 比對換檔用的游標前內容長度。
const ANCHOR_BYTES: u64 = 64;

/// 找超過上限的單行結尾時，每次往後讀的區塊大小。
const LONG_LINE_BLOCK_BYTES: u64 = 1 << 20;

/// 游標前最多 `ANCHOR_BYTES` 的內容(開始追蹤時取，之後由 `tail` 接續)。
pub fn anchor(path: &Path, cursor: u64) -> Result<Vec<u8>, TranscriptFailure> {
    let mut file = File::open(path).map_err(|_| TranscriptFailure::Unreadable)?;
    read_range(&mut file, cursor.saturating_sub(ANCHOR_BYTES), cursor)
}

/// 游標處那一行超過上限、還沒寫完時的掃描進度(#173 review):下一次檢查從掃描到的位置接著找換行，
/// 不每 250ms 從頭重讀整行;記憶體只留截短後的內容(最多 `limit` bytes)與還沒決定的引號字串。
#[derive(Debug, Default)]
pub struct LongLineScan {
    progress: Option<LongLineProgress>,
}

#[derive(Debug)]
struct LongLineProgress {
    /// 這一行的起點(游標)。
    from: u64,
    /// 游標前的內容(換了檔就不接著用)。
    anchor: Vec<u8>,
    limit: u64,
    /// 已掃描到的位置(之前沒有換行)。
    scanned: u64,
    text: LineText,
}

impl LongLineScan {
    /// 已掃描到的位置(沒有進行中的超長行時是 `None`)。
    pub fn scanned(&self) -> Option<u64> {
        self.progress.as_ref().map(|progress| progress.scanned)
    }

    /// 為了接著掃描而留在記憶體的 byte 數(錨點不算)。
    pub fn retained_bytes(&self) -> usize {
        self.progress.as_ref().map_or(0, |progress| progress.text.retained_bytes())
    }
}

/// 逐塊剝除圖片並截短到 `limit` bytes:結果與整行 `strip_images` 後截短相同，但不留整行。
///
/// 兩段依序處理(與 `strip_images` 先換長 base64、再換 data URI 相同)，每段遇到 `"` 先暫存，到能判斷是否要換成
/// `""` 時才往下一段送。輸出滿了之後後面的內容不會再改變結果，只剩找換行。
#[derive(Debug)]
struct LineText {
    limit: usize,
    base64: Base64Stage,
    data_uri: DataUriStage,
    output: Vec<u8>,
}

impl LineText {
    fn new(limit: u64) -> Self {
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        LineText {
            limit,
            // 沒換掉的 base64 字串在第 5 個字元後一定原樣輸出(不可能是 `"data:`)，只要留住輸出還放得下的部分;
            // 判斷是不是圖片要數到 128 個字元。
            base64: Base64Stage::new(limit.max(BASE64_MIN_LENGTH).saturating_add(8)),
            data_uri: DataUriStage::new(limit),
            output: Vec::new(),
        }
    }

    fn is_full(&self) -> bool {
        self.output.len() >= self.limit
    }

    fn push(&mut self, bytes: &[u8]) {
        for byte in bytes {
            if self.is_full() {
                return;
            }
            let LineText {
                limit,
                base64,
                data_uri,
                output,
            } = self;
            base64.push(*byte, &mut |byte| data_uri.push(byte, &mut |byte| emit(output, *limit, byte)));
        }
    }

    fn finish(mut self) -> Vec<u8> {
        let LineText {
            limit,
            base64,
            data_uri,
            output,
        } = &mut self;
        base64.finish(&mut |byte| data_uri.push(byte, &mut |byte| emit(output, *limit, byte)));
        data_uri.finish(&mut |byte| emit(output, *limit, byte));
        self.output
    }

    fn retained_bytes(&self) -> usize {
        self.output.len() + self.base64.retained_bytes() + self.data_uri.retained_bytes()
    }
}

fn emit(output: &mut Vec<u8>, limit: usize, byte: u8) {
    if output.len() < limit {
        output.push(byte);
    }
}

/// base64 圖片字串至少的長度(`long_base64_end`)。
const BASE64_MIN_LENGTH: usize = 128;

fn is_base64(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'=')
}

/// 第一段：`"[A-Za-z0-9+/=]{128,}"` 換成 `""`。
#[derive(Debug)]
struct Base64Stage {
    /// 在引號裡：已讀的 base64 字元數與留住的部分;`None` 是在引號外。
    quoted: Option<(usize, Vec<u8>)>,
    keep: usize,
}

impl Base64Stage {
    fn new(keep: usize) -> Self {
        Base64Stage { quoted: None, keep }
    }

    fn push(&mut self, byte: u8, next: &mut impl FnMut(u8)) {
        let Some((count, kept)) = &mut self.quoted else {
            if byte == b'"' {
                self.quoted = Some((0, Vec::new()));
            } else {
                next(byte);
            }
            return;
        };
        if is_base64(byte) {
            *count += 1;
            if kept.len() < self.keep {
                kept.push(byte);
            }
            return;
        }
        if byte == b'"' && *count >= BASE64_MIN_LENGTH {
            self.quoted = None;
            next(b'"');
            next(b'"');
            return;
        }
        // 不是圖片：開頭的引號與字元原樣送出，這個字元從引號外重新判斷(可能是下一個字串的開頭)。
        self.flush(next);
        self.push(byte, next);
    }

    fn flush(&mut self, next: &mut impl FnMut(u8)) {
        if let Some((_, kept)) = self.quoted.take() {
            next(b'"');
            kept.into_iter().for_each(&mut *next);
        }
    }

    fn finish(&mut self, next: &mut impl FnMut(u8)) {
        self.flush(next);
    }

    fn retained_bytes(&self) -> usize {
        self.quoted.as_ref().map_or(0, |(_, kept)| kept.len())
    }
}

/// 第二段：`"data:[^"]*;base64,[^"]*"` 換成 `""`。
#[derive(Debug)]
struct DataUriStage {
    state: DataUriState,
    keep: usize,
}

#[derive(Debug)]
enum DataUriState {
    Outside,
    /// 引號後已對上 `data:` 的前幾個字元。
    Prefix(usize),
    /// `"data:` 之後的內容：留住的部分、最後幾個 byte(找 `;base64,`)與是否已看到它。
    Content {
        kept: Vec<u8>,
        recent: Vec<u8>,
        marked: bool,
    },
}

const DATA_PREFIX: &[u8] = b"data:";
const BASE64_MARKER: &[u8] = b";base64,";

impl DataUriStage {
    fn new(keep: usize) -> Self {
        DataUriStage {
            state: DataUriState::Outside,
            keep,
        }
    }

    fn push(&mut self, byte: u8, next: &mut impl FnMut(u8)) {
        match &mut self.state {
            DataUriState::Outside => {
                if byte == b'"' {
                    self.state = DataUriState::Prefix(0);
                } else {
                    next(byte);
                }
            }
            DataUriState::Prefix(matched) => {
                if byte == DATA_PREFIX[*matched] {
                    *matched += 1;
                    if *matched == DATA_PREFIX.len() {
                        self.state = DataUriState::Content {
                            kept: Vec::new(),
                            recent: Vec::new(),
                            marked: false,
                        };
                    }
                    return;
                }
                // 不是 data URI:開頭的引號與對上的字元原樣送出，這個字元從引號外重新判斷。
                self.flush(next);
                self.push(byte, next);
            }
            DataUriState::Content { kept, recent, marked } => {
                if byte == b'"' {
                    if *marked {
                        self.state = DataUriState::Outside;
                        next(b'"');
                        next(b'"');
                    } else {
                        // 沒有 `;base64,`:原樣送出，結尾的引號可能是下一個字串的開頭。
                        self.flush(next);
                        self.push(byte, next);
                    }
                    return;
                }
                if kept.len() < self.keep {
                    kept.push(byte);
                }
                if !*marked {
                    recent.push(byte);
                    if recent.len() > BASE64_MARKER.len() {
                        recent.remove(0);
                    }
                    *marked = recent == BASE64_MARKER;
                }
            }
        }
    }

    fn flush(&mut self, next: &mut impl FnMut(u8)) {
        match std::mem::replace(&mut self.state, DataUriState::Outside) {
            DataUriState::Outside => {}
            DataUriState::Prefix(matched) => {
                next(b'"');
                DATA_PREFIX[..matched].iter().copied().for_each(&mut *next);
            }
            DataUriState::Content { kept, .. } => {
                next(b'"');
                DATA_PREFIX.iter().copied().for_each(&mut *next);
                kept.into_iter().for_each(&mut *next);
            }
        }
    }

    fn finish(&mut self, next: &mut impl FnMut(u8)) {
        self.flush(next);
    }

    fn retained_bytes(&self) -> usize {
        match &self.state {
            DataUriState::Content { kept, recent, .. } => kept.len() + recent.len(),
            _ => 0,
        }
    }
}

/// 分段接著讀游標之後新增的完整行(#130、#173,與 SSH 的 `catchUp` 腳本相同):累計原始 byte 數不超過 `limit`,
/// 後面還有就留給下一次。第一行就超過 `limit` 時只送那一行，剝除圖片後的內容截短到 `limit` bytes、長度照原始長度，
/// 游標照樣前進(那一行還沒寫完就等，掃描進度記在 `scan`,下一次接著掃描)。游標前的內容與 `anchor` 不同時是換了檔。
pub fn tail(path: &Path, from: u64, limit: u64, anchor: &[u8], scan: &mut LongLineScan) -> Result<Tail, TranscriptFailure> {
    let progress = scan.progress.take();
    let size = probe(path)?;
    if size < from {
        return Ok(Tail::Shrank { size });
    }
    let anchor_start = from.saturating_sub(anchor.len() as u64);
    let mut file = File::open(path).map_err(|_| TranscriptFailure::Unreadable)?;
    // 游標處的超長行上次還沒寫完：只比對游標前的內容，從掃描到的位置接著找換行，不重讀已掃描的部分。
    if let Some(progress) = progress.filter(|progress| progress.continues(from, limit, anchor, size)) {
        if read_range(&mut file, anchor_start, from)? != anchor {
            return Ok(Tail::Replaced { size });
        }
        return long_line(&mut file, size, progress, scan);
    }
    let read_end = size.min(from.saturating_add(limit));
    let bytes = read_range(&mut file, anchor_start, read_end)?;
    let Some(added) = bytes.strip_prefix(anchor) else {
        return Ok(Tail::Replaced { size });
    };
    let complete = added.iter().rposition(|byte| *byte == b'\n').map_or(0, |index| index + 1);
    if complete == 0 && read_end < size {
        let mut text = LineText::new(limit);
        text.push(added);
        let progress = LongLineProgress {
            from,
            anchor: anchor.to_vec(),
            limit,
            scanned: from + added.len() as u64,
            text,
        };
        return long_line(&mut file, size, progress, scan);
    }
    let consumed = anchor.len() + complete;
    let next_anchor = bytes[consumed.saturating_sub(ANCHOR_BYTES as usize)..consumed].to_vec();
    Ok(Tail::Lines {
        size,
        chunk: Chunk {
            start: from,
            end: from + complete as u64,
            records: records(&added[..complete]),
        },
        anchor: next_anchor,
    })
}

/// 游標處的一行超過 `limit`:找到它的換行後只送這一行(剝除圖片後截短到 `limit` bytes);還沒寫完就不送，
/// 掃描進度留在 `scan`。內容逐塊讀、邊讀邊剝除圖片，記憶體只留截短後的內容，不把整行讀進來。
fn long_line(file: &mut File, size: u64, mut progress: LongLineProgress, scan: &mut LongLineScan) -> Result<Tail, TranscriptFailure> {
    let finished = loop {
        if progress.scanned >= size {
            break false;
        }
        let block = read_range(file, progress.scanned, size.min(progress.scanned + LONG_LINE_BLOCK_BYTES))?;
        if block.is_empty() {
            break false;
        }
        let found = block.iter().position(|byte| *byte == b'\n');
        let part = &block[..found.unwrap_or(block.len())];
        progress.text.push(part);
        progress.scanned += part.len() as u64;
        if found.is_some() {
            break true;
        }
    };
    let from = progress.from;
    if !finished {
        // 那一行還沒寫完：游標與錨點都不動，下一次從掃描到的位置接著找。
        let unchanged = Tail::Lines {
            size,
            chunk: Chunk {
                start: from,
                end: from,
                records: Vec::new(),
            },
            anchor: progress.anchor.clone(),
        };
        scan.progress = Some(progress);
        return Ok(unchanged);
    }
    let length = progress.scanned - from;
    let end = progress.scanned + 1;
    let text = progress.text.finish();
    let next_anchor = read_range(file, end.saturating_sub(ANCHOR_BYTES), end)?;
    Ok(Tail::Lines {
        size,
        chunk: Chunk {
            start: from,
            end,
            records: vec![Record {
                length,
                text: String::from_utf8_lossy(&text).into_owned(),
            }],
        },
        anchor: next_anchor,
    })
}

impl LongLineProgress {
    /// 這次檢查還是同一行(同一個游標、錨點與上限，檔案沒有比掃描到的位置短)。
    fn continues(&self, from: u64, limit: u64, anchor: &[u8], size: u64) -> bool {
        self.from == from && self.limit == limit && self.anchor == anchor && self.scanned <= size
    }
}

fn read_range(file: &mut File, start: u64, end: u64) -> Result<Vec<u8>, TranscriptFailure> {
    use std::io::{Read, Seek, SeekFrom};
    file.seek(SeekFrom::Start(start)).map_err(|_| TranscriptFailure::Unreadable)?;
    let mut bytes = Vec::new();
    file.take(end.saturating_sub(start))
        .read_to_end(&mut bytes)
        .map_err(|_| TranscriptFailure::Unreadable)?;
    Ok(bytes)
}

/// 以換行結尾的完整行換成紀錄。
fn records(complete_lines: &[u8]) -> Vec<Record> {
    complete_lines
        .split(|byte| *byte == b'\n')
        .take(complete_lines.iter().filter(|byte| **byte == b'\n').count())
        .map(|line| Record {
            length: line.len() as u64,
            text: String::from_utf8_lossy(&strip_images(line)).into_owned(),
        })
        .collect()
}

/// 長度 ≥128 的 base64 字元引號字串、以及 `"data:…;base64,…"` 字串換成 `""`(R-B04;與 SSH 的 sed 相同)。
pub fn strip_images(line: &[u8]) -> Vec<u8> {
    replace_quoted(&replace_quoted(line, long_base64_end), data_uri_end)
}

/// 從左到右把 `matcher` 認得的引號字串換成 `""`;`matcher` 回傳結尾引號之後的位置。
fn replace_quoted(line: &[u8], matcher: fn(&[u8]) -> Option<usize>) -> Vec<u8> {
    let mut output = Vec::with_capacity(line.len());
    let mut index = 0;
    while index < line.len() {
        if line[index] == b'"'
            && let Some(length) = matcher(&line[index..])
        {
            output.extend_from_slice(b"\"\"");
            index += length;
            continue;
        }
        output.push(line[index]);
        index += 1;
    }
    output
}

/// `"[A-Za-z0-9+/=]{128,}"`。
fn long_base64_end(text: &[u8]) -> Option<usize> {
    let body = text[1..]
        .iter()
        .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
        .count();
    (body >= 128 && text.get(1 + body) == Some(&b'"')).then_some(body + 2)
}

/// `"data:[^"]*;base64,[^"]*"`。
fn data_uri_end(text: &[u8]) -> Option<usize> {
    let content = text[1..].strip_prefix(b"data:")?;
    let length = content.iter().position(|byte| *byte == b'"')?;
    let quoted = &content[..length];
    let has_marker = quoted.windows(b";base64,".len()).any(|window| window == b";base64,");
    has_marker.then_some(1 + b"data:".len() + length + 1)
}

/// 檔案前兩行(原樣，不含換行;Codex、Pi／OMP 的 header 檢查)。
pub fn header_lines(path: &Path) -> Result<Vec<String>, TranscriptFailure> {
    use std::io::{BufRead, BufReader};
    let file = File::open(path).map_err(|_| TranscriptFailure::Unreadable)?;
    let mut lines = Vec::new();
    for line in BufReader::new(file).split(b'\n').take(2) {
        let line = line.map_err(|_| TranscriptFailure::Unreadable)?;
        lines.push(String::from_utf8_lossy(&line).into_owned());
    }
    Ok(lines)
}

/// session id 只能含英數與 `-`(行為規格 §4.0、R-I12)。
fn require_safe_id(id: &str) -> Result<(), TranscriptFailure> {
    let safe = !id.is_empty() && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-');
    if safe { Ok(()) } else { Err(TranscriptFailure::NotAllowed) }
}

/// 家目錄底下的路徑。逐段 join,Windows 上才是一致的 `\`(app 顯示與比對路徑用)。
fn home_relative(environment: &TranscriptEnvironment, components: &[&str]) -> PathBuf {
    joined(&environment.home.clone().unwrap_or_default(), components)
}

fn joined(base: &Path, components: &[&str]) -> PathBuf {
    components.iter().fold(base.to_owned(), |path, component| path.join(component))
}

/// `<設定目錄>/projects/<cwd 轉成的資料夾名>/<id>.jsonl`;不在時找其他專案資料夾的同名檔(worktree,§4.1)。
fn locate_claude(environment: &TranscriptEnvironment, session_id: &str, cwd: &str) -> PathBuf {
    let projects = environment
        .claude_config_dir
        .clone()
        .unwrap_or_else(|| home_relative(environment, &[".claude"]))
        .join("projects");
    let file_name = format!("{session_id}.jsonl");
    let expected = projects.join(claude_project_folder(cwd)).join(&file_name);
    if expected.exists() {
        return expected;
    }
    let mut folders: Vec<PathBuf> = std::fs::read_dir(&projects)
        .map(|entries| entries.filter_map(Result::ok).map(|entry| entry.path()).collect())
        .unwrap_or_default();
    folders.sort();
    folders
        .into_iter()
        .map(|folder| folder.join(&file_name))
        .find(|candidate| candidate.is_file())
        .unwrap_or(expected)
}

/// Claude Code 2.1.280 起的資料夾名規則(R-I11):不是 `[A-Za-z0-9]` 的 UTF-16 code unit 換成 `-`;超過 200 字時取前
/// 200 字，加 `-` 與 cwd 的 Java `hashCode` 取絕對值的 base36。
pub fn claude_project_folder(cwd: &str) -> String {
    let units: Vec<u16> = cwd
        .encode_utf16()
        .map(|unit| match u8::try_from(unit) {
            Ok(byte) if byte.is_ascii_alphanumeric() => unit,
            _ => u16::from(b'-'),
        })
        .collect();
    let replaced = String::from_utf16_lossy(&units);
    if units.len() <= 200 {
        return replaced;
    }
    let hash = cwd.encode_utf16().fold(0_i32, |hash, unit| hash.wrapping_mul(31).wrapping_add(i32::from(unit)));
    format!("{}-{}", String::from_utf16_lossy(&units[..200]), base36(hash.unsigned_abs()))
}

fn base36(mut value: u32) -> String {
    const DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut digits = Vec::new();
    loop {
        digits.push(DIGITS[(value % 36) as usize]);
        value /= 36;
        if value == 0 {
            break;
        }
    }
    digits.reverse();
    String::from_utf8(digits).expect("base36 是 ASCII")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 逐塊剝除圖片的結果與整行 `strip_images` 後截短相同，不論從哪裡切塊。
    #[test]
    fn line_text_matches_stripping_the_whole_line_for_any_split() {
        let image = "Q".repeat(150);
        let short = "Q".repeat(20);
        let lines = [
            format!("{{\"i\":\"{image}\",\"t\":\"ok\"}}"),
            format!("{{\"u\":\"data:image/png;base64,{image}\",\"t\":\"after\"}}"),
            format!("{{\"u\":\"data:text/plain,{short}\",\"v\":\"\"data:x;base64,\"}}"),
            format!("\"{image}x\"{image}\"{short}\"\"dat\"data\"data:;base64,\""),
            format!("\"{image}"),
            format!("\"data:a;base64,{short}"),
            "\"\"\"\"data:\"".to_owned(),
        ];
        for line in &lines {
            for limit in [1, 5, 16, 40, 400] {
                let mut expected = strip_images(line.as_bytes());
                expected.truncate(limit);
                for split in 0..=line.len() {
                    let mut text = LineText::new(limit as u64);
                    text.push(&line.as_bytes()[..split]);
                    text.push(&line.as_bytes()[split..]);
                    assert_eq!(text.finish(), expected, "line {line:?} limit {limit} split {split}");
                }
            }
        }
    }
}
