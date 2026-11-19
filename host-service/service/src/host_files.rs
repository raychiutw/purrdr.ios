//! 主機取檔(#227):`file.stat` 與 `file.read` 的存取規則(權威)與一條連線的讀取快照。
//!
//! 只允許 herdr snapshot 回報的 Agent 工作目錄之下，或這條連線定位過的對話紀錄裡出現的路徑。
//! 先以請求的路徑比對，再以解析 symlink 後的實際路徑比對解析後的工作目錄與排除清單(與 SSH 取檔腳本相同)。

use std::fs::File;
use std::io::{ErrorKind, Read};
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::protocol::{EXCLUDED_FILE_LOCATIONS, FileStatus};

/// 主機取檔的大小上限(與 app 的 `HostFileFetchLimits.maximumSize` 相同)。
pub const MAXIMUM_FILE_SIZE: u64 = 25 * 1024 * 1024;

/// 一次讀取最多回傳的 bytes(與 SSH 取檔腳本相同)。
pub const MAXIMUM_CHUNK: u64 = 1024 * 1024;

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

/// 這次請求的允許範圍。
pub(crate) struct FileAccessScope {
    /// herdr snapshot 目前回報的 Agent 工作目錄。
    pub working_directories: Vec<String>,
    /// 這條連線定位過的對話紀錄。
    pub transcripts: Vec<PathBuf>,
}

/// 檢查並讀取後的結果。
pub(crate) enum Located {
    /// 可讀的一般檔案：內容與版本。
    File { contents: Vec<u8>, version: String },
    /// 不讀的原因;`too_large` 帶大小。
    Unavailable { status: FileStatus, size: Option<u64> },
}

impl Located {
    fn unavailable(status: FileStatus) -> Located {
        Located::Unavailable { status, size: None }
    }
}

/// 套用存取規則後讀出整個檔案(上限 `MAXIMUM_FILE_SIZE`)與版本。會讀磁碟，在 blocking 執行緒呼叫。
pub(crate) fn locate(requested: &str, scope: &FileAccessScope) -> Located {
    if !is_plain_absolute(requested) || is_excluded(Path::new(requested)) {
        return Located::unavailable(FileStatus::Denied);
    }
    let root = scope
        .working_directories
        .iter()
        .find(|directory| is_under(Path::new(requested), Path::new(directory)));
    if root.is_none() && !is_mentioned(requested, &scope.transcripts) {
        return Located::unavailable(FileStatus::Denied);
    }
    let actual = match std::fs::canonicalize(requested) {
        Ok(actual) => actual,
        Err(error) if error.kind() == ErrorKind::PermissionDenied => return Located::unavailable(FileStatus::Unreadable),
        Err(_) => return Located::unavailable(FileStatus::Missing),
    };
    if is_excluded(&actual) {
        return Located::unavailable(FileStatus::Denied);
    }
    if let Some(root) = root {
        let inside = std::fs::canonicalize(root).is_ok_and(|actual_root| is_under(&actual, &actual_root));
        if !inside {
            return Located::unavailable(FileStatus::Denied);
        }
    }
    read_regular_file(&actual)
}

fn read_regular_file(path: &Path) -> Located {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(_) => return Located::unavailable(FileStatus::Unreadable),
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
    let mut contents = Vec::new();
    // 讀的途中變大也不超過上限加一(超過就當成太大)。
    let read = File::open(path).and_then(|file| file.take(MAXIMUM_FILE_SIZE + 1).read_to_end(&mut contents));
    match read {
        Ok(_) if contents.len() as u64 > MAXIMUM_FILE_SIZE => Located::Unavailable {
            status: FileStatus::TooLarge,
            size: Some(contents.len() as u64),
        },
        Ok(_) => Located::File {
            version: version_of(&contents),
            contents,
        },
        Err(_) => Located::unavailable(FileStatus::Unreadable),
    }
}

/// 版本：內容的 SHA-256(十六進位)。
fn version_of(contents: &[u8]) -> String {
    Sha256::digest(contents).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// 絕對路徑，沒有控制字元，也沒有 `.`／`..` 段落。
fn is_plain_absolute(path: &str) -> bool {
    Path::new(path).is_absolute() && !path.chars().any(char::is_control) && !path.split(['/', '\\']).any(|segment| segment == "." || segment == "..")
}

/// `path` 在 `root` 之下(不含 `root` 本身);Windows 不分大小寫。
fn is_under(path: &Path, root: &Path) -> bool {
    let path_keys = comparison_keys(path);
    let root_keys = comparison_keys(root);
    !root_keys.is_empty() && path_keys.len() > root_keys.len() && path_keys.starts_with(&root_keys)
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

/// 對話紀錄裡有一個 JSON 字串值恰好是這個路徑。
fn is_mentioned(requested: &str, transcripts: &[PathBuf]) -> bool {
    let needle = serde_json::to_string(requested).expect("字串可序列化").into_bytes();
    transcripts.iter().any(|transcript| contains(transcript, &needle))
}

/// 分段讀檔找 `needle`,段落之間保留 `needle` 長度減一的重疊。
fn contains(path: &Path, needle: &[u8]) -> bool {
    const BLOCK: usize = 1024 * 1024;
    let Ok(mut file) = File::open(path) else { return false };
    let mut window: Vec<u8> = Vec::with_capacity(BLOCK + needle.len());
    let mut block = vec![0; BLOCK];
    loop {
        let count = match file.read(&mut block) {
            Ok(0) | Err(_) => return false,
            Ok(count) => count,
        };
        window.extend_from_slice(&block[..count]);
        if window.windows(needle.len()).any(|candidate| candidate == needle) {
            return true;
        }
        let keep = needle.len().saturating_sub(1).min(window.len());
        window.drain(..window.len() - keep);
    }
}

/// 一條連線上最近一次從頭讀的快照：之後的分塊從這裡讀。
pub(crate) struct FileSnapshot {
    pub path: String,
    pub version: String,
    pub contents: Vec<u8>,
}

impl FileSnapshot {
    /// `offset` 起最多 `length` bytes(不超過 `MAXIMUM_CHUNK`;超過檔尾時為空)。
    pub fn chunk(&self, offset: u64, length: u64) -> &[u8] {
        let total = self.contents.len() as u64;
        let start = offset.min(total);
        let end = start.saturating_add(length.min(MAXIMUM_CHUNK)).min(total);
        &self.contents[start as usize..end as usize]
    }
}
