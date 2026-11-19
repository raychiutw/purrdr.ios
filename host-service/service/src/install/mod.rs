//! 主機服務的安裝、自動啟動與解除安裝(#62、ADR-0010)。
//!
//! 檔案都放在 `~/.purrdr/host-service/`(`~/.purrdr/` 與其他功能共用);解除安裝依安裝紀錄完整還原。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

mod autostart;
mod command;
pub mod system;
mod tailscale;

pub use command::run_command;
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

/// `tailscale serve` 在主機服務 HTTPS 埠上的設定。
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
    /// `tailscale serve` 的 HTTPS 埠。
    pub https_port: u16,
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
            ServeStatus::Configured(target) => writeln!(formatter, "tailscale serve: HTTPS {} -> {target}", self.https_port)?,
            ServeStatus::NotConfigured => writeln!(formatter, "tailscale serve: HTTPS {} not configured", self.https_port)?,
            ServeStatus::Other(handlers) => writeln!(formatter, "tailscale serve: HTTPS {} serves something else ({handlers})", self.https_port)?,
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

impl HostEnvironment {
    /// 由環境變數建立。
    pub fn resolve(platform: InstallPlatform, variable: impl Fn(&str) -> Option<String>, current_executable: PathBuf) -> Result<Self, InstallError> {
        let non_empty = |name: &str| variable(name).filter(|value| !value.is_empty());
        let home_variable = if platform == InstallPlatform::Windows { "USERPROFILE" } else { "HOME" };
        let home = non_empty(home_variable).ok_or_else(|| InstallError::Io(format!("{home_variable} is not set")))?;
        Ok(HostEnvironment {
            platform,
            home: PathBuf::from(home),
            xdg_config_home: non_empty("XDG_CONFIG_HOME").map(PathBuf::from),
            user_name: non_empty(if platform == InstallPlatform::Windows { "USERNAME" } else { "USER" }),
            current_executable,
        })
    }

    /// 這個行程的主機資訊。
    pub fn from_process() -> Result<Self, InstallError> {
        let current_executable = std::env::current_exe().map_err(InstallError::io)?;
        Self::resolve(InstallPlatform::current(), |name| std::env::var(name).ok(), current_executable)
    }
}

/// 安裝相關的子命令。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallCommand {
    Install {
        port: u16,
        herdr_session: Option<String>,
        /// `tailscale serve` 的 HTTPS 埠;沒指定時沿用上次安裝，或 443。
        https_port: Option<u16>,
        assume_yes: bool,
    },
    Uninstall,
    Status,
}

impl InstallCommand {
    /// 第一個參數是 `install`／`uninstall`／`status` 時解析;其他交給主機服務本身。
    pub fn parse(arguments: &[String]) -> Option<Result<Self, String>> {
        let (name, options) = arguments.split_first()?;
        let command = match name.as_str() {
            "install" => Self::parse_install(options),
            "uninstall" | "status" => match options.first() {
                Some(extra) => Err(format!("unknown argument: {extra}")),
                None if name == "status" => Ok(InstallCommand::Status),
                None => Ok(InstallCommand::Uninstall),
            },
            _ => return None,
        };
        Some(command)
    }

    fn parse_install(options: &[String]) -> Result<Self, String> {
        let (mut port, mut herdr_session, mut https_port, mut assume_yes) = (crate::DEFAULT_PORT, None, None, false);
        let mut remaining = options.iter();
        while let Some(option) = remaining.next() {
            let mut value = || remaining.next().ok_or_else(|| format!("{option} needs a value"));
            match option.as_str() {
                "--port" => {
                    let text = value()?;
                    port = text.parse().map_err(|_| format!("invalid port: {text}"))?;
                }
                "--https-port" => {
                    let text = value()?;
                    https_port = Some(
                        text.parse()
                            .ok()
                            .filter(|port| *port != 0)
                            .ok_or_else(|| format!("invalid HTTPS port: {text}"))?,
                    );
                }
                "--session" => herdr_session = Some(value()?.clone()),
                "--yes" => assume_yes = true,
                other => return Err(format!("unknown argument: {other}")),
            }
        }
        Ok(InstallCommand::Install {
            port,
            herdr_session,
            https_port,
            assume_yes,
        })
    }
}

/// `install` 的選項。
#[derive(Debug, Clone)]
pub struct InstallOptions {
    pub port: u16,
    pub herdr_session: Option<String>,
    /// `--https-port`;`None` 時沿用上次安裝的埠，或 443。
    pub https_port: Option<u16>,
    /// 放下載的執行檔的資料夾。
    pub source_directory: PathBuf,
}

/// 安裝途中要使用者同意的事。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallQuestion {
    /// 沒指定 `--https-port`,預設的埠已被別的服務占用：改用 `alternative`?
    UseAnotherHttpsPort { taken_port: u16, handlers: String, alternative: u16 },
    /// 主機名稱會進 Certificate Transparency 公開紀錄。
    CertificateTransparency { host_name: String },
}

impl std::fmt::Display for InstallQuestion {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InstallQuestion::UseAnotherHttpsPort {
                taken_port,
                handlers,
                alternative,
            } => write!(
                formatter,
                "tailscale serve already uses HTTPS {taken_port} for another service ({handlers}). \
                 The installer leaves it unchanged and can serve Purrdr on HTTPS {alternative} instead."
            ),
            InstallQuestion::CertificateTransparency { host_name } => write!(formatter, "{}", certificate_transparency_notice(host_name)),
        }
    }
}

/// 安裝完成。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installed {
    pub https_address: String,
    /// 沒能完成、但不影響安裝結果的項目(例如關掉換埠前的舊 HTTPS 埠)。
    pub warnings: Vec<String>,
    /// 產生配對碼的指令(安裝好的執行檔 `pair`)。
    pub pair_command: String,
}

impl std::fmt::Display for Installed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(formatter, "Installed. The host service starts at login.")?;
        writeln!(formatter, "HTTPS address: {}", self.https_address)?;
        writeln!(formatter, "To pair a device:")?;
        writeln!(formatter, "  1. On this computer run: {}", self.pair_command)?;
        write!(
            formatter,
            "  2. In Purrdr, tap Add host -> HTTPS and scan the QR code (or enter {} and the pairing code).",
            self.https_address
        )
    }
}

/// 重跑安裝的指令：`prefix` 加上這次的選項;`--https-port` 放最後(換埠的建議以它替換)。
/// session 名稱依執行的 shell 加引號(Windows 是 PowerShell,其他是 sh)。
pub fn rerun_install_command(prefix: &str, command: &InstallCommand, platform: InstallPlatform) -> String {
    let InstallCommand::Install {
        port,
        herdr_session,
        https_port,
        assume_yes,
    } = command
    else {
        return prefix.to_owned();
    };
    let mut parts = vec![prefix.to_owned()];
    if *port != crate::DEFAULT_PORT {
        parts.push(format!("--port {port}"));
    }
    if let Some(session) = herdr_session {
        parts.push(format!("--session {}", shell_argument(session, platform)));
    }
    if *assume_yes {
        parts.push("--yes".to_owned());
    }
    if let Some(https_port) = https_port {
        parts.push(format!("{HTTPS_PORT_OPTION} {https_port}"));
    }
    parts.join(" ")
}

const HTTPS_PORT_OPTION: &str = "--https-port";

/// 只有英數與 `._-` 時原樣，否則加單引號(sh 的 `'` 寫成 `'\''`,PowerShell 寫成 `''`)。
fn shell_argument(value: &str, platform: InstallPlatform) -> String {
    if !value.is_empty() && value.chars().all(|character| character.is_ascii_alphanumeric() || "._-".contains(character)) {
        return value.to_owned();
    }
    let escaped_quote = if platform == InstallPlatform::Windows { "''" } else { r"'\''" };
    format!("'{}'", value.replace('\'', escaped_quote))
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
    /// `tailscale serve --https=<埠>` 失敗。
    ServeFailed {
        https_port: u16,
    },
    /// 使用者看過 Certificate Transparency 的說明後取消。
    Declined,
    /// 這個 HTTPS 埠已經轉到別的服務;`available` 是可以改用的埠。
    ServePortTaken {
        https_port: u16,
        handlers: String,
        available: Option<u16>,
    },
    /// 這個 HTTPS 埠的 `tailscale serve` 設定已不是安裝時設的。
    ServeChanged {
        https_port: u16,
        handlers: String,
    },
    Tailscale(String),
    Autostart(String),
    NotInstalled,
    Io(String),
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}", self.explain("purrdr-host-service install"))
    }
}

impl InstallError {
    /// 給使用者的說明：發生什麼、為什麼，最後一段 `Next:` 是下一步(`rerun` 是重跑安裝的完整指令)。
    pub fn explain(&self, rerun: &str) -> String {
        const DNS_SETTINGS: &str = "https://login.tailscale.com/admin/dns";
        let then_rerun = format!("then run the install again:\n  {rerun}");
        match self {
            InstallError::TailscaleMissing => format!(
                "Tailscale is not installed (the `tailscale` command was not found). \
                 The host service is reached through `tailscale serve`, so it needs Tailscale.\n\
                 Next: install Tailscale from https://tailscale.com/download, sign in, {then_rerun}"
            ),
            InstallError::TailscaleNotRunning(state) => format!(
                "Tailscale is not connected (state: {state}). The HTTPS address only works while this machine is on your tailnet.\n\
                 Next: run `tailscale up` and sign in, {then_rerun}"
            ),
            InstallError::MagicDnsDisabled => format!(
                "MagicDNS is off for this tailnet. The HTTPS address is this machine's MagicDNS name, so it needs MagicDNS.\n\
                 Next: turn on MagicDNS at {DNS_SETTINGS}, {then_rerun}"
            ),
            InstallError::HttpsCertificatesDisabled => format!(
                "HTTPS Certificates are off for this tailnet. `tailscale serve` needs them to get an HTTPS certificate for this machine.\n\
                 Next: click \"Enable HTTPS\" under HTTPS Certificates at {DNS_SETTINGS}, {then_rerun}"
            ),
            InstallError::ServeFailed { https_port } => format!(
                "`tailscale serve --bg --https={https_port}` failed (see its output above).\n\
                 On Linux, allow your account to change serve settings first: sudo tailscale set --operator=$USER\n\
                 Next: fix the problem above, {then_rerun}"
            ),
            InstallError::Declined => "Install cancelled; nothing was changed.".to_owned(),
            InstallError::ServePortTaken {
                https_port,
                handlers,
                available,
            } => {
                // 重跑指令若已指定這個(被占用的)埠，換埠時以新埠取代。
                let without_taken_port = rerun.strip_suffix(&format!(" {HTTPS_PORT_OPTION} {https_port}")).unwrap_or(rerun);
                let next = match available {
                    Some(available) => format!("Next: install on HTTPS {available} instead:\n  {without_taken_port} {HTTPS_PORT_OPTION} {available}"),
                    None => format!(
                        "Next: pick a free HTTPS port (`tailscale serve status` lists the ones in use) and run:\n  {without_taken_port} {HTTPS_PORT_OPTION} <port>"
                    ),
                };
                format!(
                    "tailscale serve already uses HTTPS {https_port} for another service:\n  {handlers}\n\
                     The installer does not change existing tailscale serve settings.\n\
                     {next}\n\
                     Or, if you no longer need that service, remove it with `tailscale serve --https={https_port} off` and run:\n  {rerun}"
                )
            }
            InstallError::ServeChanged { https_port, handlers } => {
                format!("tailscale serve HTTPS {https_port} now serves {handlers}, left unchanged")
            }
            InstallError::Tailscale(message) => format!(
                "Tailscale returned an error: {message}\n\
                 Next: check Tailscale with `tailscale status`, {then_rerun}"
            ),
            InstallError::Autostart(message) => format!(
                "Could not set the host service to start at login: {message}\n\
                 Next: fix the problem above, {then_rerun}"
            ),
            InstallError::Io(message) => format!("{message}\nNext: fix the problem above, {then_rerun}"),
            InstallError::NotInstalled => "The Purrdr host service is not installed.".to_owned(),
        }
    }

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
        crate::state_directory::default_state_directory(&self.home)
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
    /// `tailscale serve` 的 HTTPS 埠(0.2.0 的紀錄沒有這欄，當時固定 443)。
    #[serde(default = "default_https_port")]
    https_port: u16,
    https_address: String,
    /// 是否由安裝流程設定了 `tailscale serve`。
    serve_configured: bool,
    /// 安裝時新建的資料夾(相對家目錄),解除安裝時若是空的就刪除。
    created_directories: Vec<String>,
}

fn default_https_port() -> u16 {
    tailscale::DEFAULT_HTTPS_PORT
}

/// 主機服務讀取的設定(`pair` 以 `https_address` 當預設位址)。
#[derive(Serialize)]
struct ServiceConfig<'a> {
    https_address: &'a str,
}

/// 一個 HTTPS 埠的使用狀況。
enum PortUse {
    Free,
    /// 已轉到主機服務;`in_place` 表示目標就是這次要用的本機埠。
    Ours {
        in_place: bool,
    },
    Taken(String),
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
    /// `confirm` 回答安裝途中的問題(`InstallQuestion`),回 false 就取消(此時還沒有改任何東西)。
    pub fn install(&mut self, options: &InstallOptions, mut confirm: impl FnMut(&InstallQuestion) -> bool) -> Result<Installed, InstallError> {
        let layout = self.layout();
        let previous = self.read_record(&layout)?;
        let tailscale = Tailscale::locate(&mut self.system, self.environment.platform)?;
        let host_name = tailscale.host_name(&mut self.system)?;
        let preferred = options
            .https_port
            .or(previous.as_ref().map(|record| record.https_port))
            .unwrap_or(tailscale::DEFAULT_HTTPS_PORT);
        let (https_port, serve_in_place) = match self.check_https_port(&tailscale, preferred, options.port, previous.as_ref())? {
            PortUse::Free => (preferred, false),
            PortUse::Ours { in_place } => (preferred, in_place),
            PortUse::Taken(handlers) => {
                let available = self.first_free_https_port(&tailscale, preferred, options.port, previous.as_ref())?;
                let taken = InstallError::ServePortTaken {
                    https_port: preferred,
                    handlers: handlers.clone(),
                    available,
                };
                // 使用者指定的埠不擅自換掉。
                let Some(alternative) = available.filter(|_| options.https_port.is_none()) else {
                    return Err(taken);
                };
                let question = InstallQuestion::UseAnotherHttpsPort {
                    taken_port: preferred,
                    handlers,
                    alternative,
                };
                if !confirm(&question) {
                    return Err(taken);
                }
                (alternative, false)
            }
        };
        if !confirm(&InstallQuestion::CertificateTransparency { host_name: host_name.clone() }) {
            return Err(InstallError::Declined);
        }

        let mut record = InstallRecord {
            port: options.port,
            herdr_session: options.herdr_session.clone(),
            https_port,
            https_address: tailscale::https_address(&host_name, https_port),
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
        let mut warnings = Vec::new();
        // 換了 HTTPS 埠：關掉上次安裝設的舊埠。
        if let Some(previous) = previous.filter(|previous| previous.serve_configured && previous.https_port != record.https_port)
            && let Err(error) = tailscale.remove_serve(&mut self.system, previous.https_port, previous.port)
        {
            warnings.push(format!("the previous HTTPS {} was not removed: {error}", previous.https_port));
        }
        Ok(Installed {
            https_address: record.https_address,
            warnings,
            pair_command: format!("{} pair", shell_quoted(&layout.executable(), self.environment.platform)),
        })
    }

    /// HTTPS 埠目前是空的、已是主機服務的，還是被別的服務占用。
    fn check_https_port(&mut self, tailscale: &Tailscale, https_port: u16, port: u16, previous: Option<&InstallRecord>) -> Result<PortUse, InstallError> {
        let handlers = tailscale.https_handlers(&mut self.system, https_port)?;
        let proxy_to = |port: u16| BTreeMap::from([("/".to_owned(), tailscale::serve_target(port))]);
        if handlers.is_empty() {
            return Ok(PortUse::Free);
        }
        if handlers == proxy_to(port) {
            return Ok(PortUse::Ours { in_place: true });
        }
        let ours_from_previous_install =
            previous.is_some_and(|record| record.serve_configured && record.https_port == https_port && handlers == proxy_to(record.port));
        if ours_from_previous_install {
            return Ok(PortUse::Ours { in_place: false });
        }
        Ok(PortUse::Taken(tailscale::describe(&handlers)))
    }

    /// 候選 HTTPS 埠中第一個可用的(跳過已被占用的 `taken`)。
    fn first_free_https_port(&mut self, tailscale: &Tailscale, taken: u16, port: u16, previous: Option<&InstallRecord>) -> Result<Option<u16>, InstallError> {
        for candidate in tailscale::CANDIDATE_HTTPS_PORTS.into_iter().filter(|candidate| *candidate != taken) {
            if !matches!(self.check_https_port(tailscale, candidate, port, previous)?, PortUse::Taken(_)) {
                return Ok(Some(candidate));
            }
        }
        Ok(None)
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
    fn apply(
        &mut self,
        layout: &ServiceLayout,
        tailscale: &Tailscale,
        options: &InstallOptions,
        serve_in_place: bool,
        record: &mut InstallRecord,
    ) -> Result<(), InstallError> {
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
        write_json(
            &layout.config_file(),
            &ServiceConfig {
                https_address: &record.https_address,
            },
        )?;

        if !serve_in_place {
            record.serve_configured = true;
            tailscale.serve(&mut self.system, record.https_port, options.port)?;
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
            let _ = tailscale.remove_serve(&mut self.system, record.https_port, record.port);
        }
        let _ = self.remove_files(layout, record);
    }

    /// 主機服務、自動啟動、`tailscale serve` 與 herdr 的狀態。
    pub async fn status(&mut self, socket_environment: &SocketEnvironment) -> HostStatus {
        let layout = self.layout();
        let record = self.read_record(&layout).ok().flatten();
        let port = record.as_ref().map_or(crate::DEFAULT_PORT, |record| record.port);
        let https_port = record.as_ref().map_or(tailscale::DEFAULT_HTTPS_PORT, |record| record.https_port);
        let target = tailscale::serve_target(port);
        let serve =
            match Tailscale::locate(&mut self.system, self.environment.platform).and_then(|tailscale| tailscale.https_handlers(&mut self.system, https_port)) {
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
            https_port,
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
            let removed = Tailscale::locate(&mut self.system, self.environment.platform)
                .and_then(|tailscale| tailscale.remove_serve(&mut self.system, record.https_port, record.port));
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
            return self.system.remove_directory_after_exit(&layout.directory(), &created).map_err(InstallError::io);
        }
        // taskkill 剛結束的背景程式，Windows 可能還沒放開執行檔，稍等重試。
        let mut attempts_left = 10;
        loop {
            match std::fs::remove_dir_all(layout.directory()) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
                Err(_) if attempts_left > 0 => {
                    attempts_left -= 1;
                    std::thread::sleep(std::time::Duration::from_millis(300));
                }
                Err(error) => return Err(InstallError::io(error)),
                Ok(()) => break,
            }
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
    let socket_platform = if platform == InstallPlatform::Windows {
        Platform::Windows
    } else {
        Platform::Unix
    };
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

/// 終端機可以直接貼上執行的路徑(有空白時加引號;PowerShell 要 `&` 才會執行引號內的路徑)。
pub(crate) fn shell_quoted(path: &Path, platform: InstallPlatform) -> String {
    let text = path.display().to_string();
    match (text.contains(' '), platform) {
        (false, _) => text,
        (true, InstallPlatform::Windows) => format!("& \"{text}\""),
        (true, _) => format!("\"{text}\""),
    }
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
