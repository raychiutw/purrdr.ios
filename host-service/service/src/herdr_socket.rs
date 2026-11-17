//! herdr 本機 socket 的路徑解析(herdr 官方文件 socket-api「Socket paths」)。

/// 主機的 socket 形式:Unix domain socket 或 Windows named pipe。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Unix,
    Windows,
}

impl Platform {
    /// 這支程式執行所在的平台。
    pub fn current() -> Self {
        if cfg!(windows) { Platform::Windows } else { Platform::Unix }
    }
}

/// 解析 socket 路徑用到的環境變數;空字串視同未設定。
#[derive(Debug, Clone, Default)]
pub struct SocketEnvironment {
    /// `HOME`(Unix 的設定目錄在 `~/.config/herdr`)。
    pub home: Option<String>,
    /// `APPDATA`(Windows 的設定目錄在 `%APPDATA%\herdr`)。
    pub app_data: Option<String>,
    /// `HERDR_SOCKET_PATH`。
    pub socket_path: Option<String>,
    /// `HERDR_SESSION`。
    pub session: Option<String>,
    /// `USERPROFILE`(Windows 的主機服務資料夾在 `%USERPROFILE%\.purrdr\host-service`)。
    pub user_profile: Option<String>,
}

impl SocketEnvironment {
    /// 讀取目前行程的環境變數。
    pub fn from_process() -> Self {
        let variable = |name: &str| std::env::var(name).ok();
        SocketEnvironment {
            home: variable("HOME"),
            app_data: variable("APPDATA"),
            socket_path: variable("HERDR_SOCKET_PATH"),
            session: variable("HERDR_SESSION"),
            user_profile: variable("USERPROFILE"),
        }
    }
}

/// 解析失敗的原因。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SocketPathError {
    /// Unix 沒有 `HOME`。
    MissingHome,
    /// Windows 沒有 `APPDATA`。
    MissingAppData,
}

/// herdr 的 API socket。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HerdrSocket {
    path: String,
    platform: Platform,
}

impl HerdrSocket {
    /// 依 herdr 官方順序解析：明確 session → `HERDR_SOCKET_PATH` → `HERDR_SESSION` → 預設 session。
    pub fn resolve(platform: Platform, explicit_session: Option<&str>, environment: &SocketEnvironment) -> Result<Self, SocketPathError> {
        let non_empty = |value: Option<&str>| value.filter(|text| !text.is_empty()).map(str::to_owned);
        if let Some(session) = non_empty(explicit_session) {
            return Self::session_socket(platform, Some(&session), environment);
        }
        if let Some(path) = non_empty(environment.socket_path.as_deref()) {
            return Ok(HerdrSocket { path, platform });
        }
        let session = non_empty(environment.session.as_deref());
        Self::session_socket(platform, session.as_deref(), environment)
    }

    /// 指向一個明確的 socket 路徑(測試的假 herdr socket)。
    pub fn at_path(platform: Platform, path: impl Into<String>) -> Self {
        HerdrSocket { path: path.into(), platform }
    }

    /// herdr 文件裡的 socket 路徑。
    pub fn path(&self) -> &str {
        &self.path
    }

    /// 連線用的平台原生名稱:Windows 是 `\\.\pipe\` 加上 socket 路徑。
    pub fn native_name(&self) -> String {
        match self.platform {
            Platform::Unix => self.path.clone(),
            Platform::Windows => format!(r"\\.\pipe\{}", self.path),
        }
    }

    fn session_socket(platform: Platform, session: Option<&str>, environment: &SocketEnvironment) -> Result<Self, SocketPathError> {
        let non_empty = |value: &Option<String>| value.clone().filter(|text| !text.is_empty());
        let (config_directory, separator) = match platform {
            Platform::Unix => (non_empty(&environment.home).ok_or(SocketPathError::MissingHome)? + "/.config/herdr", "/"),
            Platform::Windows => (non_empty(&environment.app_data).ok_or(SocketPathError::MissingAppData)? + r"\herdr", r"\"),
        };
        let path = match session {
            Some(name) => [config_directory.as_str(), "sessions", name, "herdr.sock"].join(separator),
            None => [config_directory.as_str(), "herdr.sock"].join(separator),
        };
        Ok(HerdrSocket { path, platform })
    }
}
