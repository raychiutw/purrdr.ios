//! 稽核紀錄 `audit.log`(JSON Lines):配對、連線、撤銷、寫入類操作與主機取檔。不記 prompt、按鍵、終端機與檔案內容。

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::time::SystemTime;

use serde::Serialize;

/// 一筆稽核事件。欄位只放識別資訊，不放操作內容。
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum AuditEvent {
    PairingCodeCreated {
        read_only: bool,
    },
    Paired {
        device_id: String,
        device_name: String,
        read_only: bool,
    },
    PairingFailed {
        reason: &'static str,
    },
    Connected {
        device_id: String,
    },
    ConnectionRejected {
        reason: &'static str,
        device_id: Option<String>,
    },
    Revoked {
        device_id: String,
        by: RevokedBy,
    },
    Write {
        device_id: String,
        operation: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        pane_id: Option<String>,
        allowed: bool,
    },
    /// 主機取檔(#227):路徑、結果(`FileStatus` 或 `changed`)與大小，不記內容。
    FileAccess {
        device_id: String,
        operation: &'static str,
        path: String,
        result: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        size: Option<u64>,
    },
}

/// 誰撤銷的。
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RevokedBy {
    /// 主機上的管理指令。
    Host,
    /// 裝置自己(app 刪除主機時)。
    Device,
}

#[derive(Serialize)]
struct AuditLine<'a> {
    time: String,
    #[serde(flatten)]
    event: &'a AuditEvent,
}

/// 主機服務資料夾裡的 `audit.log`。
#[derive(Debug, Clone)]
pub struct AuditLog {
    path: PathBuf,
}

impl AuditLog {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        AuditLog {
            path: directory.into().join("audit.log"),
        }
    }

    /// 附加一筆;寫不進去只印到 stderr,不影響請求本身。
    pub fn record(&self, event: AuditEvent, now: SystemTime) {
        let line = AuditLine {
            time: humantime::format_rfc3339_seconds(now).to_string(),
            event: &event,
        };
        let mut bytes = serde_json::to_vec(&line).expect("稽核事件可序列化");
        bytes.push(b'\n');
        let written = self
            .path
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|_| OpenOptions::new().create(true).append(true).open(&self.path))
            .and_then(|mut file| file.write_all(&bytes));
        if let Err(error) = written {
            eprintln!("cannot write audit log {}: {error}", self.path.display());
        }
    }
}
