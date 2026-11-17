//! 主機服務的安裝、自動啟動與解除安裝(#62、ADR-0010)。
//!
//! 檔案都放在 `~/.purrdr/host-service/`(`~/.purrdr/` 與其他功能共用);解除安裝依安裝紀錄完整還原。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

mod autostart;
pub mod system;
mod tailscale;

use system::HostSystem;
use tailscale::Tailscale;

/// 安裝目標的作業系統。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallPlatform {
    MacOs,
    Linux,
    Windows,
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

/// 安裝失敗。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallError {
    TailscaleMissing,
    TailscaleNotRunning(String),
    MagicDnsDisabled,
    HttpsCertificatesDisabled,
    ServeFailed,
    Tailscale(String),
    Autostart(String),
    Io(String),
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
        }
    }

    /// 檢查前置條件、複製執行檔、設定 `tailscale serve` 與登入後自動啟動。
    pub fn install(&mut self, options: &InstallOptions, _confirm: impl FnOnce(&str) -> bool) -> Result<Installed, InstallError> {
        let layout = self.layout();
        let tailscale = Tailscale::locate(&mut self.system, self.environment.platform)?;
        let host_name = tailscale.host_name(&mut self.system)?;
        let mut record = InstallRecord {
            port: options.port,
            herdr_session: options.herdr_session.clone(),
            https_address: format!("https://{host_name}"),
            ..InstallRecord::default()
        };

        for directory in [layout.bin_directory(), layout.log_file().parent().unwrap().to_path_buf()] {
            self.create_directory(&directory, &mut record)?;
        }
        std::fs::copy(options.source_directory.join(layout.executable_name()), layout.executable()).map_err(InstallError::io)?;
        write_json(&layout.config_file(), &ServiceConfig { https_address: &record.https_address })?;

        tailscale.serve(&mut self.system, options.port)?;
        record.serve_configured = true;

        if let Some(registration) = autostart::registration_file(&layout) {
            self.create_directory(registration.parent().unwrap(), &mut record)?;
        }
        write_json(&layout.record_file(), &record)?;
        autostart::register(&mut self.system, &layout, &service_arguments(&record))?;
        Ok(Installed { https_address: record.https_address })
    }

    /// 建立資料夾，並把新建的每一層記在安裝紀錄。
    fn create_directory(&self, directory: &Path, record: &mut InstallRecord) -> Result<(), InstallError> {
        let mut missing: Vec<&Path> = directory.ancestors().take_while(|ancestor| !ancestor.exists()).collect();
        std::fs::create_dir_all(directory).map_err(InstallError::io)?;
        missing.reverse();
        for created in missing {
            if let Ok(relative) = created.strip_prefix(&self.environment.home) {
                record.created_directories.push(relative.to_string_lossy().replace('\\', "/"));
            }
        }
        Ok(())
    }
}

/// 自動啟動時傳給主機服務的參數。
fn service_arguments(record: &InstallRecord) -> Vec<String> {
    let mut arguments = vec!["--port".to_owned(), record.port.to_string()];
    if let Some(session) = &record.herdr_session {
        arguments.extend(["--session".to_owned(), session.clone()]);
    }
    arguments
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<(), InstallError> {
    let text = serde_json::to_string_pretty(value).expect("可序列化");
    std::fs::write(path, text).map_err(InstallError::io)
}
