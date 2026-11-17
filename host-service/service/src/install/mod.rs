//! 主機服務的安裝、自動啟動與解除安裝(#62、ADR-0010)。
//!
//! 檔案都放在 `~/.purrdr/host-service/`(`~/.purrdr/` 與其他功能共用);解除安裝依安裝紀錄完整還原。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

mod autostart;
pub mod system;
mod tailscale;

use system::HostSystem;
use tailscale::Tailscale;

use crate::herdr_client::HerdrClient;
use crate::herdr_socket::{HerdrSocket, Platform, SocketEnvironment};

/// 安裝目標的作業系統。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallPlatform {
    MacOs,
    Linux,
    Windows,
}

impl InstallPlatform {
    /// 這支程式執行所在的平台。
    pub fn current() -> Self {
        if cfg!(windows) {
            InstallPlatform::Windows
        } else if cfg!(target_os = "macos") {
            InstallPlatform::MacOs
        } else {
            InstallPlatform::Linux
        }
    }
}

/// `tailscale serve` 的 HTTPS 443 設定。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServeStatus {
    /// 轉到主機服務(proxy 目標)。
    Configured(String),
    NotConfigured,
    /// 轉到別的地方。
    Other(String),
    /// 查不到(例如 Tailscale 沒裝)。
    Unavailable(String),
}

/// herdr 伺服器的狀態。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HerdrStatus {
    Running { version: String },
    NotRunning(String),
}

/// `status` 指令的結果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostStatus {
    pub installed: bool,
    pub autostart_registered: bool,
    /// 127.0.0.1 上的埠有主機服務在聽。
    pub listening: bool,
    pub port: u16,
    pub https_address: Option<String>,
    pub serve: ServeStatus,
    pub herdr: HerdrStatus,
}

impl std::fmt::Display for HostStatus {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let yes_no = |value: bool| if value { "yes" } else { "no" };
        writeln!(formatter, "host service: {}", if self.installed { "installed" } else { "not installed" })?;
        writeln!(formatter, "  starts at login: {}", yes_no(self.autostart_registered))?;
        writeln!(formatter, "  listening on 127.0.0.1:{}: {}", self.port, yes_no(self.listening))?;
        if let Some(address) = &self.https_address {
            writeln!(formatter, "  HTTPS address: {address}")?;
        }
        match &self.serve {
            ServeStatus::Configured(target) => writeln!(formatter, "tailscale serve: HTTPS 443 -> {target}")?,
            ServeStatus::NotConfigured => writeln!(formatter, "tailscale serve: HTTPS 443 not configured")?,
            ServeStatus::Other(handlers) => writeln!(formatter, "tailscale serve: HTTPS 443 serves something else ({handlers})")?,
            ServeStatus::Unavailable(message) => writeln!(formatter, "tailscale serve: unknown ({message})")?,
        }
        match &self.herdr {
            HerdrStatus::Running { version } => write!(formatter, "herdr: running ({version})"),
            HerdrStatus::NotRunning(message) => write!(formatter, "herdr: not running ({message})"),
        }
    }
}

/// 安裝流程需要的主機資訊。
#[derive(Debug, Clone)]
pub struct HostEnvironment {
    pub platform: InstallPlatform,
    pub home: PathBuf,
    /// `XDG_CONFIG_HOME`(Linux 的 systemd user unit 位置)。
    pub xdg_config_home: Option<PathBuf>,
    /// 登入帳號(Windows 結束背景程式時只結束自己的)。
    pub user_name: Option<String>,
    /// 正在執行的執行檔。
    pub current_executable: PathBuf,
}

/// `install` 的選項。
#[derive(Debug, Clone)]
pub struct InstallOptions {
    pub port: u16,
    pub herdr_session: Option<String>,
    /// 放下載的執行檔的資料夾。
    pub source_directory: PathBuf,
}

/// 安裝完成。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installed {
    pub https_address: String,
}

/// 解除安裝完成。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Uninstalled {
    /// 沒能還原的項目。
    pub warnings: Vec<String>,
}

/// 安裝或解除安裝失敗。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallError {
    TailscaleMissing,
    TailscaleNotRunning(String),
    MagicDnsDisabled,
    HttpsCertificatesDisabled,
    ServeFailed,
    /// 使用者看過 Certificate Transparency 的說明後取消。
    Declined,
    /// HTTPS 443 已經轉到別的服務。
    ServePortTaken(String),
    /// HTTPS 443 的 `tailscale serve` 設定已不是安裝時設的。
    ServeChanged(String),
    Tailscale(String),
    Autostart(String),
    NotInstalled,
    Io(String),
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        const DNS_SETTINGS: &str = "https://login.tailscale.com/admin/dns";
        match self {
            InstallError::TailscaleMissing => write!(formatter, "Tailscale is not installed. Install it from https://tailscale.com/download, sign in, then run install again."),
            InstallError::TailscaleNotRunning(state) => write!(formatter, "Tailscale is not connected (state: {state}). Run `tailscale up` and sign in, then run install again."),
            InstallError::MagicDnsDisabled => write!(formatter, "MagicDNS is off for this tailnet. Turn on MagicDNS at {DNS_SETTINGS}, then run install again."),
            InstallError::HttpsCertificatesDisabled => write!(
                formatter,
                "HTTPS Certificates are off for this tailnet. Click \"Enable HTTPS\" under HTTPS Certificates at {DNS_SETTINGS}, then run install again."
            ),
            InstallError::ServeFailed => write!(
                formatter,
                "`tailscale serve` failed (see its output above). On Linux, allow your account first with `sudo tailscale set --operator=$USER`."
            ),
            InstallError::Declined => write!(formatter, "Install cancelled; nothing was changed."),
            InstallError::ServePortTaken(handlers) => write!(
                formatter,
                "tailscale serve already uses HTTPS 443 ({handlers}). Remove it with `tailscale serve --https=443 off` if you no longer need it, then run install again."
            ),
            InstallError::ServeChanged(handlers) => write!(formatter, "tailscale serve HTTPS 443 now serves {handlers}, left unchanged"),
            InstallError::Tailscale(message) | InstallError::Autostart(message) | InstallError::Io(message) => write!(formatter, "{message}"),
            InstallError::NotInstalled => write!(formatter, "The Purrdr host service is not installed."),
        }
    }
}

impl InstallError {
    fn io(error: std::io::Error) -> Self {
        InstallError::Io(error.to_string())
    }
}

/// 主機服務在家目錄裡的檔案位置。
pub(crate) struct ServiceLayout {
    platform: InstallPlatform,
    home: PathBuf,
    xdg_config_home: Option<PathBuf>,
}

impl ServiceLayout {
    fn directory(&self) -> PathBuf {
        self.home.join(".purrdr").join("host-service")
    }

    fn bin_directory(&self) -> PathBuf {
        self.directory().join("bin")
    }

    fn executable_name(&self) -> &'static str {
        match self.platform {
            InstallPlatform::Windows => "purrdr-host-service.exe",
            _ => "purrdr-host-service",
        }
    }

    fn executable(&self) -> PathBuf {
        self.bin_directory().join(self.executable_name())
    }

    /// Windows 自動啟動用的、不開 console 視窗的執行檔。
    fn background_executable_name(&self) -> &'static str {
        "purrdr-host-service-background.exe"
    }

    fn background_executable(&self) -> PathBuf {
        self.bin_directory().join(self.background_executable_name())
    }

    /// 要從下載資料夾複製到 `bin/` 的執行檔。
    fn executable_names(&self) -> Vec<&'static str> {
        match self.platform {
            InstallPlatform::Windows => vec![self.executable_name(), self.background_executable_name()],
            _ => vec![self.executable_name()],
        }
    }

    fn log_file(&self) -> PathBuf {
        self.directory().join("logs").join("host-service.log")
    }

    fn config_file(&self) -> PathBuf {
        self.directory().join("config.json")
    }

    fn record_file(&self) -> PathBuf {
        self.directory().join("install.json")
    }
}

/// 安裝紀錄：解除安裝依它還原。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct InstallRecord {
    port: u16,
    herdr_session: Option<String>,
    https_address: String,
    /// 是否由安裝流程設定了 `tailscale serve`。
    serve_configured: bool,
    /// 安裝時新建的資料夾(相對家目錄),解除安裝時若是空的就刪除。
    created_directories: Vec<String>,
}

/// 主機服務讀取的設定(`pair` 以 `https_address` 當預設位址)。
#[derive(Serialize)]
struct ServiceConfig<'a> {
    https_address: &'a str,
}

/// 安裝與解除安裝主機服務。
pub struct Installer<S: HostSystem> {
    environment: HostEnvironment,
    system: S,
}

impl<S: HostSystem> Installer<S> {
    pub fn new(environment: HostEnvironment, system: S) -> Self {
        Installer { environment, system }
    }

    /// 安裝用的系統(測試檢查假系統狀態)。
    pub fn system(&self) -> &S {
        &self.system
    }

    fn layout(&self) -> ServiceLayout {
        ServiceLayout {
            platform: self.environment.platform,
            home: self.environment.home.clone(),
            xdg_config_home: self.environment.xdg_config_home.clone(),
        }
    }

    /// 檢查前置條件、複製執行檔、設定 `tailscale serve` 與登入後自動啟動。
    /// `confirm` 收到 Certificate Transparency 的說明，回 false 就取消(此時還沒有改任何東西)。
    pub fn install(&mut self, options: &InstallOptions, confirm: impl FnOnce(&str) -> bool) -> Result<Installed, InstallError> {
        let layout = self.layout();
        let previous = self.read_record(&layout)?;
        let tailscale = Tailscale::locate(&mut self.system, self.environment.platform)?;
        let host_name = tailscale.host_name(&mut self.system)?;
        let handlers = tailscale.https_handlers(&mut self.system)?;
        let proxy_to = |port: u16| BTreeMap::from([("/".to_owned(), tailscale::serve_target(port))]);
        let serve_in_place = handlers == proxy_to(options.port);
        let ours_from_previous_install = previous.as_ref().is_some_and(|record| record.serve_configured && handlers == proxy_to(record.port));
        if !handlers.is_empty() && !serve_in_place && !ours_from_previous_install {
            return Err(InstallError::ServePortTaken(tailscale::describe(&handlers)));
        }
        if !confirm(&certificate_transparency_notice(&host_name)) {
            return Err(InstallError::Declined);
        }

        let mut record = InstallRecord {
            port: options.port,
            herdr_session: options.herdr_session.clone(),
            https_address: format!("https://{host_name}"),
            serve_configured: previous.as_ref().is_some_and(|record| record.serve_configured),
            created_directories: previous.as_ref().map(|record| record.created_directories.clone()).unwrap_or_default(),
        };
        if previous.is_some() {
            // 先停掉執行中的舊版，執行檔才換得掉(Windows)。
            autostart::unregister(&mut self.system, &layout, self.environment.user_name.as_deref())?;
        }
        let applied = self.apply(&layout, &tailscale, options, serve_in_place, &mut record);
        if let Err(error) = applied {
            // 重新安裝失敗時保留已配對的裝置，不還原。
            if previous.is_none() {
                self.roll_back(&layout, &tailscale, &record);
            }
            return Err(error);
        }
        Ok(Installed { https_address: record.https_address })
    }

    fn read_record(&self, layout: &ServiceLayout) -> Result<Option<InstallRecord>, InstallError> {
        let text = match std::fs::read_to_string(layout.record_file()) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            result => result.map_err(InstallError::io)?,
        };
        serde_json::from_str(&text)
            .map(Some)
            .map_err(|error| InstallError::Io(format!("{}: {error}", layout.record_file().display())))
    }

    /// 安裝的每一步;`record` 隨時反映已做的變更，失敗時依它還原。
    fn apply(&mut self, layout: &ServiceLayout, tailscale: &Tailscale, options: &InstallOptions, serve_in_place: bool, record: &mut InstallRecord) -> Result<(), InstallError> {
        for directory in [layout.bin_directory(), layout.log_file().parent().unwrap().to_path_buf()] {
            self.create_directory(&directory, record)?;
        }
        for name in layout.executable_names() {
            let (source, destination) = (options.source_directory.join(name), layout.bin_directory().join(name));
            // 從安裝好的那份再執行 install 時，複製到自己會把檔案清空。
            if !same_file(&source, &destination) {
                std::fs::copy(&source, &destination).map_err(InstallError::io)?;
            }
        }
        write_json(&layout.config_file(), &ServiceConfig { https_address: &record.https_address })?;

        if !serve_in_place {
            record.serve_configured = true;
            tailscale.serve(&mut self.system, options.port)?;
        }

        if let Some(registration) = autostart::registration_file(layout) {
            self.create_directory(registration.parent().unwrap(), record)?;
        }
        for directory in autostart::system_created_directories(layout) {
            if !directory.exists() {
                self.record_created(&directory, record);
            }
        }
        write_json(&layout.record_file(), record)?;
        autostart::register(&mut self.system, layout, &service_arguments(record))
    }

    /// 安裝失敗時盡力還原;還原本身的錯誤不蓋過原本的錯誤。
    fn roll_back(&mut self, layout: &ServiceLayout, tailscale: &Tailscale, record: &InstallRecord) {
        let _ = autostart::unregister(&mut self.system, layout, self.environment.user_name.as_deref());
        if record.serve_configured {
            let _ = tailscale.remove_serve(&mut self.system, record.port);
        }
        let _ = self.remove_files(layout, record);
    }

    /// 主機服務、自動啟動、`tailscale serve` 與 herdr 的狀態。
    pub async fn status(&mut self, socket_environment: &SocketEnvironment) -> HostStatus {
        let layout = self.layout();
        let record = self.read_record(&layout).ok().flatten();
        let port = record.as_ref().map_or(crate::DEFAULT_PORT, |record| record.port);
        let target = tailscale::serve_target(port);
        let serve = match Tailscale::locate(&mut self.system, self.environment.platform).and_then(|tailscale| tailscale.https_handlers(&mut self.system)) {
            Ok(handlers) if handlers.is_empty() => ServeStatus::NotConfigured,
            Ok(handlers) if handlers == BTreeMap::from([("/".to_owned(), target.clone())]) => ServeStatus::Configured(target),
            Ok(handlers) => ServeStatus::Other(tailscale::describe(&handlers)),
            Err(error) => ServeStatus::Unavailable(error.to_string()),
        };
        let session = record.as_ref().and_then(|record| record.herdr_session.clone());
        HostStatus {
            installed: record.is_some(),
            autostart_registered: autostart::is_registered(&mut self.system, &layout),
            listening: is_listening(port).await,
            port,
            https_address: record.map(|record| record.https_address),
            serve,
            herdr: herdr_status(self.environment.platform, session.as_deref(), socket_environment).await,
        }
    }

    /// 移除自動啟動、`tailscale serve` 設定與主機服務的檔案;還原不了的項目列在 `warnings`。
    pub fn uninstall(&mut self) -> Result<Uninstalled, InstallError> {
        let layout = self.layout();
        let record = self.read_record(&layout)?.ok_or(InstallError::NotInstalled)?;
        let mut warnings = Vec::new();

        autostart::unregister(&mut self.system, &layout, self.environment.user_name.as_deref())?;
        if record.serve_configured {
            let removed = Tailscale::locate(&mut self.system, self.environment.platform).and_then(|tailscale| tailscale.remove_serve(&mut self.system, record.port));
            if let Err(error) = removed {
                warnings.push(format!("tailscale serve was not removed: {error}"));
            }
        }
        self.remove_files(&layout, &record)?;
        Ok(Uninstalled { warnings })
    }

    /// 刪除主機服務的資料夾，再刪除安裝時新建、現在是空的資料夾(由深到淺)。
    fn remove_files(&mut self, layout: &ServiceLayout, record: &InstallRecord) -> Result<(), InstallError> {
        let created: Vec<PathBuf> = record
            .created_directories
            .iter()
            .rev()
            .map(|relative| self.environment.home.join(relative))
            .filter(|directory| !directory.starts_with(layout.directory()))
            .collect();
        let running_from_installed_copy = self.environment.current_executable.starts_with(layout.directory());
        if self.environment.platform == InstallPlatform::Windows && running_from_installed_copy {
            return self
                .system
                .remove_directory_after_exit(&layout.directory(), &created)
                .map_err(InstallError::io);
        }
        match std::fs::remove_dir_all(layout.directory()) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(InstallError::io(error)),
            _ => {}
        }
        for directory in created {
            let _ = std::fs::remove_dir(directory);
        }
        Ok(())
    }

    /// 建立資料夾，並把新建的每一層記在安裝紀錄。
    fn create_directory(&self, directory: &Path, record: &mut InstallRecord) -> Result<(), InstallError> {
        let mut missing: Vec<&Path> = directory.ancestors().take_while(|ancestor| !ancestor.exists()).collect();
        std::fs::create_dir_all(directory).map_err(InstallError::io)?;
        missing.reverse();
        for created in missing {
            self.record_created(created, record);
        }
        Ok(())
    }

    fn record_created(&self, directory: &Path, record: &mut InstallRecord) {
        if let Ok(relative) = directory.strip_prefix(&self.environment.home) {
            record.created_directories.push(relative.to_string_lossy().replace('\\', "/"));
        }
    }
}

async fn is_listening(port: u16) -> bool {
    let connect = tokio::net::TcpStream::connect(("127.0.0.1", port));
    matches!(tokio::time::timeout(std::time::Duration::from_secs(2), connect).await, Ok(Ok(_)))
}

async fn herdr_status(platform: InstallPlatform, session: Option<&str>, socket_environment: &SocketEnvironment) -> HerdrStatus {
    let socket_platform = if platform == InstallPlatform::Windows { Platform::Windows } else { Platform::Unix };
    let socket = match HerdrSocket::resolve(socket_platform, session, socket_environment) {
        Ok(socket) => socket,
        Err(error) => return HerdrStatus::NotRunning(format!("cannot resolve herdr socket: {error:?}")),
    };
    match HerdrClient::new(socket).request("ping", serde_json::json!({})).await {
        Ok(pong) => HerdrStatus::Running {
            version: pong["version"].as_str().unwrap_or("unknown").to_owned(),
        },
        Err(failure) => HerdrStatus::NotRunning(format!("{failure:?}")),
    }
}

/// 設定 `tailscale serve` 前給使用者看的說明。
fn certificate_transparency_notice(host_name: &str) -> String {
    format!(
        "Tailscale will get an HTTPS certificate for {host_name}. Certificates are recorded in public Certificate Transparency logs, \
         so this name becomes publicly visible. If it reveals something sensitive, rename this machine at \
         https://login.tailscale.com/admin/machines first."
    )
}

/// 自動啟動時傳給主機服務的參數。
fn service_arguments(record: &InstallRecord) -> Vec<String> {
    let mut arguments = vec!["--port".to_owned(), record.port.to_string()];
    if let Some(session) = &record.herdr_session {
        arguments.extend(["--session".to_owned(), session.clone()]);
    }
    arguments
}

fn same_file(first: &Path, second: &Path) -> bool {
    match (first.canonicalize(), second.canonicalize()) {
        (Ok(first), Ok(second)) => first == second,
        _ => false,
    }
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<(), InstallError> {
    let text = serde_json::to_string_pretty(value).expect("可序列化");
    std::fs::write(path, text).map_err(InstallError::io)
}
