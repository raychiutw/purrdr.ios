//! 主機服務的檔案位置:`~/.purrdr/host-service/`(Windows `%USERPROFILE%\.purrdr\host-service\`,ADR-0010)。

use std::path::{Path, PathBuf};

/// 使用者家目錄底下的主機服務資料夾。
pub fn default_state_directory(home: &Path) -> PathBuf {
    home.join(".purrdr").join("host-service")
}
