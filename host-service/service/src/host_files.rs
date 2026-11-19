//! 主機取檔(#227):`file.stat` 與 `file.read` 的存取規則(權威)與一條連線的讀取快照。
//!
//! 放行：herdr snapshot 回報的 Agent 工作目錄之下(工作目錄不能是根目錄、家目錄或它的上層),或這條連線定位過的對話紀錄裡
//! Agent 自己寫出、且在暫存目錄／Purrdr 上傳／這段對話紀錄附檔資料夾的路徑。先比對請求的路徑，再比對解析 symlink 後的實際路徑，
//! 開檔後以 handle 的實際路徑再核對一次(檢查與開檔之間被換掉也讀不到外面)。共用案例：`protocol/host-file-access.json`。

use std::collections::{HashMap, HashSet};
use std::fs::{File, Metadata};
use std::io::{BufRead, BufReader, ErrorKind, Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::host_path_mentions;
use crate::protocol::{EXCLUDED_FILE_LOCATIONS, FileStatus, MAXIMUM_FILE_CHUNK, MAXIMUM_FILE_SIZE, TEMPORARY_FILE_LOCATIONS};

/// 路徑任何位置連續出現排除清單的段落(不分大小寫;`*` 結尾比對段落開頭)。
pub fn is_excluded(path: &Path) -> bool {
    let segments: Vec<String> = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(segment) => Some(segment.to_string_lossy().to_lowercase()),
            _ => None,
        })
        .collect();
    EXCLUDED_FILE_LOCATIONS.iter().any(|location| {
        let pattern: Vec<String> = location.to_lowercase().split('/').map(str::to_owned).collect();
        segments.windows(pattern.len()).any(|window| {
            window.iter().zip(&pattern).all(|(actual, expected)| match expected.strip_suffix('*') {
                Some(prefix) => actual.starts_with(prefix),
                None => actual == expected,
            })
        })
    })
}

/// 主機服務的環境：家目錄、暫存目錄與主機服務資料夾(`--state-dir`,一律拒讀)。
#[derive(Debug, Clone, Default)]
pub struct FileAccessEnvironment {
    pub home: Option<PathBuf>,
    pub temporary_directory: Option<PathBuf>,
    pub state_directory: PathBuf,
}

/// 只看路徑的存取規則(與 app、SSH 取檔腳本共用案例 `protocol/host-file-access.json`)。
#[derive(Debug, Clone, Default)]
pub struct FileAccessRules {
    /// herdr snapshot 目前回報的 Agent 工作目錄。
    pub working_directories: Vec<PathBuf>,
    pub home: Option<PathBuf>,
    /// 主機的 `TMPDIR`／`TEMP`(schema 的 `x-temporary-file-locations` 另外都算)。
    pub temporary_directories: Vec<PathBuf>,
    /// 這條連線定位過的對話紀錄(附檔資料夾是 `<資料夾>/<檔名去掉副檔名>/tool-results`)。
    pub transcripts: Vec<PathBuf>,
    /// 一律拒讀的資料夾(主機服務資料夾)。
    pub excluded_directories: Vec<PathBuf>,
}

/// 放行的理由。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Grant {
    /// 在這個 Agent 工作目錄之下。
    WorkingDirectory(PathBuf),
    /// Agent 在對話紀錄寫出的路徑，且在暫存、上傳或附檔資料夾。
    MentionedLocation,
}

impl FileAccessRules {
    /// 只看路徑判斷;`is_mentioned` 只在需要時才查(要讀對話紀錄)。
    pub fn grant(&self, requested: &str, is_mentioned: impl FnOnce() -> bool) -> Option<Grant> {
        if !is_plain_absolute(requested) {
            return None;
        }
        self.grant_path(Path::new(requested), is_mentioned)
    }

    fn grant_path(&self, path: &Path, is_mentioned: impl FnOnce() -> bool) -> Option<Grant> {
        if self.is_excluded(path) {
            return None;
        }
        if let Some(root) = self
            .working_directories
            .iter()
            .find(|directory| !self.is_too_broad(directory) && is_under(path, directory))
        {
            return Some(Grant::WorkingDirectory(root.clone()));
        }
        (self.is_mentionable_location(path) && is_mentioned()).then_some(Grant::MentionedLocation)
    }

    fn is_excluded(&self, path: &Path) -> bool {
        is_excluded(path) || self.excluded_directories.iter().any(|directory| is_under_or_same(path, directory))
    }

    /// 根目錄、家目錄或家目錄的上層：當工作目錄等於放行整個家目錄。
    fn is_too_broad(&self, directory: &Path) -> bool {
        let is_root = !directory.components().any(|component| matches!(component, Component::Normal(_)));
        is_root || self.home.as_deref().is_some_and(|home| is_under_or_same(home, directory))
    }

    /// 工作目錄以外，Agent 提到時可放行的位置。
    fn mentionable_locations(&self) -> Vec<PathBuf> {
        let mut locations: Vec<PathBuf> = TEMPORARY_FILE_LOCATIONS
            .iter()
            .map(PathBuf::from)
            .filter(|location| location.is_absolute())
            .collect();
        locations.extend(self.temporary_directories.iter().cloned());
        if let Some(home) = &self.home {
            locations.push(home.join("AppData").join("Local").join("Temp"));
            locations.push(home.join(".purrdr").join("uploads"));
        }
        for transcript in &self.transcripts {
            if let (Some(folder), Some(stem)) = (transcript.parent(), transcript.file_stem()) {
                locations.push(folder.join(stem).join("tool-results"));
            }
        }
        locations
    }

    fn is_mentionable_location(&self, path: &Path) -> bool {
        self.mentionable_locations().iter().any(|location| is_under(path, location))
    }

    /// 每個位置都加上解析 symlink 後的寫法(macOS 的 `/tmp` 是 `/private/tmp`)。
    fn resolved(&self) -> FileAccessRules {
        let with_resolved = |paths: &[PathBuf]| -> Vec<PathBuf> { paths.iter().flat_map(|path| std::iter::once(path.clone()).chain(resolve(path))).collect() };
        FileAccessRules {
            working_directories: self.working_directories.iter().filter_map(|directory| resolve(directory)).collect(),
            home: self.home.as_deref().and_then(resolve).or_else(|| self.home.clone()),
            temporary_directories: with_resolved(&self.temporary_directories),
            transcripts: with_resolved(&self.transcripts),
            excluded_directories: with_resolved(&self.excluded_directories),
        }
    }

    /// 實際路徑在暫存、上傳或附檔資料夾(含它們解析後的位置)。
    fn is_resolved_mentionable_location(&self, actual: &Path) -> bool {
        self.mentionable_locations()
            .iter()
            .any(|location| is_under(actual, location) || resolve(location).is_some_and(|resolved| is_under(actual, &resolved)))
    }
}

/// 一行對話紀錄中 Agent 自己寫出的路徑：assistant 訊息文字中認得的路徑(#229)、工具呼叫參數的檔案路徑、
/// 圖片生成的 `saved_path` 與 MCP 圖片的 `[Image: source: …]`。使用者 prompt 與工具結果的內容不算。
pub fn agent_written_paths(line: &Value) -> Vec<String> {
    let mut found = Vec::new();
    for message in [line, &line["message"], &line["payload"]] {
        if message["role"] == "assistant" {
            collect_assistant_content(&message["content"], &mut found);
        }
    }
    let payload = &line["payload"];
    if matches!(payload["type"].as_str(), Some("image_generation_call" | "image_generation_end"))
        && let Some(saved) = payload["saved_path"].as_str().or_else(|| payload["savedPath"].as_str())
    {
        found.push(saved.to_owned());
    }
    if line["type"] == "user"
        && let Some(blocks) = line["toolUseResult"].as_array()
    {
        found.extend(
            blocks
                .iter()
                .filter(|block| block["type"] == "text")
                .filter_map(|block| image_source(block["text"].as_str()?)),
        );
    }
    // Antigravity 的 step:Agent 的回覆在 PLANNER_RESPONSE。
    if line["type"] == "PLANNER_RESPONSE" && line["step_index"].is_number() {
        if let Some(text) = line["content"].as_str() {
            found.extend(host_path_mentions::paths(text));
        }
        for call in line["tool_calls"].as_array().into_iter().flatten() {
            let arguments = match call.get("args").or_else(|| call.get("arguments")) {
                Some(Value::String(text)) => serde_json::from_str(text).unwrap_or(Value::Null),
                Some(value) => value.clone(),
                None => Value::Null,
            };
            if let Some(path) = arguments["AbsolutePath"].as_str() {
                found.push(path.to_owned());
            }
        }
    }
    found
}

fn collect_assistant_content(content: &Value, found: &mut Vec<String>) {
    match content {
        Value::String(text) => found.extend(host_path_mentions::paths(text)),
        Value::Array(blocks) => {
            for block in blocks {
                match block["type"].as_str() {
                    Some("text" | "output_text") => found.extend(block["text"].as_str().map(host_path_mentions::paths).unwrap_or_default()),
                    Some("tool_use") => found.extend(tool_call_path(&block["input"])),
                    Some("toolCall") => found.extend(tool_call_path(&block["arguments"])),
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

/// 工具呼叫參數裡的檔案路徑(與 app 的 `ClaudeTranscriptParser.filePath(in:)` 相同的鍵)。
fn tool_call_path(arguments: &Value) -> Option<String> {
    ["file_path", "notebook_path", "path"]
        .iter()
        .find_map(|key| arguments[key].as_str().filter(|path| !path.is_empty()))
        .map(str::to_owned)
}

/// `[Image: source: <絕對路徑>]` 的路徑。
fn image_source(text: &str) -> Option<String> {
    let inner = text.trim().strip_prefix("[Image: source: ")?.strip_suffix(']')?;
    // 這裡只取路徑;是否可讀由 `FileAccessRules` 判斷。
    (!inner.is_empty()).then(|| inner.to_owned())
}

/// 一條連線上，每份對話紀錄已讀到哪裡與 Agent 寫出的路徑(增量更新，不每次重掃)。
#[derive(Default)]
pub(crate) struct MentionIndex {
    transcripts: HashMap<PathBuf, TranscriptMentions>,
}

#[derive(Default)]
struct TranscriptMentions {
    /// 已處理到的位置(完整的行為止)。
    processed: u64,
    paths: HashSet<String>,
}

impl MentionIndex {
    fn mentions(&mut self, transcripts: &[PathBuf], requested: &str) -> bool {
        transcripts.iter().any(|transcript| {
            let mentions = self.transcripts.entry(transcript.clone()).or_default();
            mentions.catch_up(transcript);
            mentions.paths.contains(requested)
        })
    }
}

impl TranscriptMentions {
    fn catch_up(&mut self, transcript: &Path) {
        let Ok(mut file) = File::open(transcript) else { return };
        let size = file.metadata().map(|metadata| metadata.len()).unwrap_or(0);
        if size < self.processed {
            // 被換成較短的檔案：重新讀。
            *self = TranscriptMentions::default();
        }
        if size == self.processed || file.seek(SeekFrom::Start(self.processed)).is_err() {
            return;
        }
        let mut reader = BufReader::new(file);
        let mut line = Vec::new();
        loop {
            line.clear();
            match reader.read_until(b'\n', &mut line) {
                Ok(0) | Err(_) => return,
                // 還沒寫完的最後一行下次再讀。
                Ok(_) if line.last() != Some(&b'\n') => return,
                Ok(count) => {
                    self.processed += count as u64;
                    if let Ok(value) = serde_json::from_slice::<Value>(&line) {
                        self.paths.extend(agent_written_paths(&value));
                    }
                }
            }
        }
    }
}

/// 版本快取：大小與修改時間都沒變時沿用版本，不重算 SHA-256。
#[derive(Default)]
pub(crate) struct VersionCache {
    versions: HashMap<PathBuf, KnownVersion>,
}

struct KnownVersion {
    size: u64,
    modified: SystemTime,
    version: String,
}

/// 修改時間離現在太近時不沿用(同一秒內再寫入，修改時間可能不變)。
const SETTLED_AFTER: Duration = Duration::from_secs(2);

impl VersionCache {
    fn known(&self, path: &Path, metadata: &Metadata) -> Option<String> {
        let known = self.versions.get(path)?;
        let modified = metadata.modified().ok()?;
        let settled = SystemTime::now().duration_since(modified).is_ok_and(|age| age >= SETTLED_AFTER);
        (settled && known.size == metadata.len() && known.modified == modified).then(|| known.version.clone())
    }

    fn remember(&mut self, path: &Path, metadata: &Metadata, version: &str) {
        if let Ok(modified) = metadata.modified() {
            self.versions.insert(
                path.to_owned(),
                KnownVersion {
                    size: metadata.len(),
                    modified,
                    version: version.to_owned(),
                },
            );
        }
    }
}

/// 一條連線的取檔狀態：對話紀錄裡的路徑與版本快取。
#[derive(Default)]
pub(crate) struct FileAccessCache {
    pub mentions: MentionIndex,
    pub versions: VersionCache,
}

/// 檢查並開檔後的結果。
pub(crate) enum Located {
    /// 可讀的一般檔案：版本與大小;`contents` 只在要讀內容時才有。
    File { version: String, size: u64, contents: Option<Vec<u8>> },
    /// 不讀的原因;`too_large` 帶大小。
    Unavailable { status: FileStatus, size: Option<u64> },
}

impl Located {
    fn unavailable(status: FileStatus) -> Located {
        Located::Unavailable { status, size: None }
    }

    /// 協定上的狀態。
    pub fn status(&self) -> FileStatus {
        match self {
            Located::File { .. } => FileStatus::File,
            Located::Unavailable { status, .. } => *status,
        }
    }

    /// 大小(一般檔案與 `too_large`)。
    pub fn size(&self) -> Option<u64> {
        match self {
            Located::File { size, .. } => Some(*size),
            Located::Unavailable { size, .. } => *size,
        }
    }

    /// 一般檔案的版本。
    pub fn version(&self) -> Option<&str> {
        match self {
            Located::File { version, .. } => Some(version),
            Located::Unavailable { .. } => None,
        }
    }
}

/// 要不要讀內容：`file.stat` 只要版本(大小與修改時間沒變就不讀);`file.read` 從頭讀時要內容建快照。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Purpose {
    Status,
    Contents,
}

/// 套用存取規則、開檔並以 handle 核對實際路徑。會讀磁碟，在 blocking 執行緒呼叫。
pub(crate) fn locate(requested: &str, rules: &FileAccessRules, cache: &mut FileAccessCache, purpose: Purpose) -> Located {
    let Some(grant) = rules.grant(requested, || cache.mentions.mentions(&rules.transcripts, requested)) else {
        return Located::unavailable(FileStatus::Denied);
    };
    let actual = match std::fs::canonicalize(requested) {
        Ok(actual) => actual,
        Err(error) if error.kind() == ErrorKind::PermissionDenied => return Located::unavailable(FileStatus::Unreadable),
        Err(_) => return Located::unavailable(FileStatus::Missing),
    };
    let Some(actual) = without_verbatim_prefix(&actual) else {
        return Located::unavailable(FileStatus::Denied);
    };
    let resolved = rules.resolved();
    if !resolved_is_allowed(&actual, &grant, &resolved) {
        return Located::unavailable(FileStatus::Denied);
    }
    match std::fs::symlink_metadata(&actual) {
        Ok(metadata) if !metadata.is_file() => return Located::unavailable(FileStatus::NotRegularFile),
        Ok(_) => {}
        Err(_) => return Located::unavailable(FileStatus::Missing),
    }
    let file = match open_without_following(&actual) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::PermissionDenied => return Located::unavailable(FileStatus::Unreadable),
        Err(_) => return Located::unavailable(FileStatus::Denied),
    };
    // 開到的不是剛才檢查的那個檔案(中途被換成 symlink 或別的資料夾)。
    if !handle_is_at(&file, &actual) {
        return Located::unavailable(FileStatus::Denied);
    }
    read_regular_file(file, &actual, cache, purpose)
}

fn resolved_is_allowed(actual: &Path, grant: &Grant, resolved: &FileAccessRules) -> bool {
    if resolved.is_excluded(actual) {
        return false;
    }
    match grant {
        Grant::WorkingDirectory(root) => resolve(root).is_some_and(|actual_root| !resolved.is_too_broad(&actual_root) && is_under(actual, &actual_root)),
        Grant::MentionedLocation => resolved.is_resolved_mentionable_location(actual),
    }
}

fn read_regular_file(file: File, path: &Path, cache: &mut FileAccessCache, purpose: Purpose) -> Located {
    let Ok(metadata) = file.metadata() else {
        return Located::unavailable(FileStatus::Unreadable);
    };
    if !metadata.is_file() {
        return Located::unavailable(FileStatus::NotRegularFile);
    }
    if metadata.len() > MAXIMUM_FILE_SIZE {
        return Located::Unavailable {
            status: FileStatus::TooLarge,
            size: Some(metadata.len()),
        };
    }
    if purpose == Purpose::Status
        && let Some(version) = cache.versions.known(path, &metadata)
    {
        return Located::File {
            version,
            size: metadata.len(),
            contents: None,
        };
    }
    let mut contents = Vec::new();
    // 讀的途中變大也不超過上限加一(超過就當成太大)。
    if file.take(MAXIMUM_FILE_SIZE + 1).read_to_end(&mut contents).is_err() {
        return Located::unavailable(FileStatus::Unreadable);
    }
    let size = contents.len() as u64;
    if size > MAXIMUM_FILE_SIZE {
        return Located::Unavailable {
            status: FileStatus::TooLarge,
            size: Some(size),
        };
    }
    let version = version_of(&contents);
    if size == metadata.len() {
        cache.versions.remember(path, &metadata, &version);
    }
    Located::File {
        version,
        size,
        contents: (purpose == Purpose::Contents).then_some(contents),
    }
}

/// 最後一段不跟隨 symlink;不是一般檔案(FIFO、裝置)也不會卡在開檔。
fn open_without_following(path: &Path) -> std::io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    options.open(path)
}

/// handle 實際指向的路徑(macOS `F_GETPATH`、Linux `/proc/self/fd`、Windows `GetFinalPathNameByHandle`)就是 `expected`。
fn handle_is_at(file: &File, expected: &Path) -> bool {
    use filepath::FilePath;
    file.path()
        .ok()
        .and_then(|actual| without_verbatim_prefix(&actual))
        .is_some_and(|actual| comparison_keys(&actual) == comparison_keys(expected))
}

/// Windows 的 `\\?\C:\…` 換成 `C:\…`;`\\?\UNC\…` 與其他裝置路徑回 `None`。其他平台原樣。
fn without_verbatim_prefix(path: &Path) -> Option<PathBuf> {
    if !cfg!(windows) {
        return Some(path.to_owned());
    }
    let text = path.to_string_lossy();
    let plain = text.strip_prefix(r"\\?\").unwrap_or(&text);
    is_plain_absolute(plain).then(|| PathBuf::from(plain))
}

/// 解析 symlink 後的路徑(不存在時 `None`)。
fn resolve(path: &Path) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok().and_then(|resolved| without_verbatim_prefix(&resolved))
}

/// 版本：內容的 SHA-256(十六進位)。
fn version_of(contents: &[u8]) -> String {
    Sha256::digest(contents).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// 絕對路徑，沒有控制字元，也沒有 `.`／`..` 段落;Windows 只收磁碟機路徑(UNC 會送出 NTLM,ADS 讀到別的資料流)。
fn is_plain_absolute(path: &str) -> bool {
    let has_plain_segments = !path.chars().any(char::is_control) && !path.split(['/', '\\']).any(|segment| segment == "." || segment == "..");
    let is_absolute = if cfg!(windows) {
        let bytes = path.as_bytes();
        bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && matches!(bytes[2], b'\\' | b'/') && !path[2..].contains(':')
    } else {
        path.starts_with('/')
    };
    is_absolute && has_plain_segments
}

/// `path` 在 `root` 之下(不含 `root` 本身);Windows 不分大小寫。
fn is_under(path: &Path, root: &Path) -> bool {
    let path_keys = comparison_keys(path);
    let root_keys = comparison_keys(root);
    !root_keys.is_empty() && path_keys.len() > root_keys.len() && path_keys.starts_with(&root_keys)
}

fn is_under_or_same(path: &Path, root: &Path) -> bool {
    let path_keys = comparison_keys(path);
    let root_keys = comparison_keys(root);
    !root_keys.is_empty() && path_keys.starts_with(&root_keys)
}

fn comparison_keys(path: &Path) -> Vec<String> {
    path.components()
        .filter(|component| !matches!(component, Component::CurDir))
        .map(|component| {
            let text = component.as_os_str().to_string_lossy();
            if cfg!(windows) { text.to_lowercase() } else { text.into_owned() }
        })
        .collect()
}

/// 主機取檔的頻率上限：連續 `burst` 次之後，每次至少間隔 `interval`(要讀磁碟與對話紀錄的請求才算)。
pub struct RequestPacing {
    burst: u32,
    interval: Duration,
    /// 下一次「理論上」輪到的時間。
    next_slot: Option<Instant>,
}

impl RequestPacing {
    pub fn new(burst: u32, interval: Duration) -> Self {
        RequestPacing {
            burst,
            interval,
            next_slot: None,
        }
    }

    /// 這次請求要先等多久(同時記下這次)。
    pub fn delay_for(&mut self, now: Instant) -> Duration {
        let slot = self.next_slot.map_or(now, |next| next.max(now));
        let next = slot + self.interval;
        self.next_slot = Some(next);
        next.saturating_duration_since(now).saturating_sub(self.interval * self.burst)
    }
}

impl Default for RequestPacing {
    /// 一次最多 20 個，之後每秒 10 個。
    fn default() -> Self {
        RequestPacing::new(20, Duration::from_millis(100))
    }
}

/// 一條連線上最近一次從頭讀的快照：之後的分塊從這裡讀。
pub(crate) struct FileSnapshot {
    pub path: String,
    pub version: String,
    pub contents: Vec<u8>,
}

impl FileSnapshot {
    /// `offset` 起最多 `length` bytes(不超過 `MAXIMUM_FILE_CHUNK`;超過檔尾時為空)。
    pub fn chunk(&self, offset: u64, length: u64) -> &[u8] {
        let total = self.contents.len() as u64;
        let start = offset.min(total);
        let end = start.saturating_add(length.min(MAXIMUM_FILE_CHUNK)).min(total);
        &self.contents[start as usize..end as usize]
    }
}
