//! 主機服務的檔案位置:`~/.purrdr/host-service/`(Windows `%USERPROFILE%\.purrdr\host-service\`,ADR-0010)。

use std::path::{Path, PathBuf};

use crate::herdr_socket::{Platform, SocketEnvironment};

/// 使用者家目錄底下的主機服務資料夾。
pub fn default_state_directory(home: &Path) -> PathBuf {
    home.join(".purrdr").join("host-service")
}

/// 依平台的家目錄變數(Unix `HOME`、Windows `USERPROFILE`)找主機服務資料夾;沒設定時回 None。
pub fn resolve_state_directory(platform: Platform, environment: &SocketEnvironment) -> Option<PathBuf> {
    let home = match platform {
        Platform::Unix => environment.home.as_deref(),
        Platform::Windows => environment.user_profile.as_deref(),
    };
    home.filter(|home| !home.is_empty()).map(|home| default_state_directory(Path::new(home)))
}
