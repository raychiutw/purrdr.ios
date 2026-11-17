//! 安裝測試共用：模擬 tailscale、launchctl、systemctl、reg 的假主機，以及暫存家目錄。

#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use purrdr_host_service::install::system::{CommandOutput, HostSystem};
use purrdr_host_service::install::{HostEnvironment, InstallOptions, InstallPlatform};
use serde_json::{Value, json};

static NEXT_DIRECTORY: AtomicU32 = AtomicU32::new(0);

pub const FQDN: &str = "studio.tail1234.ts.net";
pub const LAUNCH_AGENT_LABEL: &str = "com.raychiu.purrdr.host-service";
pub const SYSTEMD_UNIT: &str = "purrdr-host-service.service";
pub const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
pub const RUN_VALUE: &str = "PurrdrHostService";

/// 測試結束時刪除的暫存資料夾。
pub struct TempDirectory(pub PathBuf);

impl TempDirectory {
    pub fn new(label: &str) -> TempDirectory {
        let path = std::env::temp_dir().join(format!(
            "purrdr-install-test-{label}-{}-{}",
            std::process::id(),
            NEXT_DIRECTORY.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        TempDirectory(path)
    }
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// 資料夾內所有檔案與資料夾(相對路徑 → 檔案內容;資料夾為 None)。
pub fn snapshot(root: &Path) -> BTreeMap<String, Option<String>> {
    fn walk(root: &Path, directory: &Path, entries: &mut BTreeMap<String, Option<String>>) {
        for entry in std::fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            let relative = path.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
            if path.is_dir() {
                entries.insert(format!("{relative}/"), None);
                walk(root, &path, entries);
            } else {
                entries.insert(relative, Some(String::from_utf8_lossy(&std::fs::read(&path).unwrap()).into_owned()));
            }
        }
    }
    let mut entries = BTreeMap::new();
    walk(root, root, &mut entries);
    entries
}

/// 一台測試主機：暫存家目錄、放執行檔的下載資料夾、假系統。
pub struct TestHost {
    pub home: TempDirectory,
    pub downloads: TempDirectory,
    pub platform: InstallPlatform,
}

impl TestHost {
    pub fn new(platform: InstallPlatform) -> TestHost {
        let downloads = TempDirectory::new("downloads");
        for name in executable_names(platform) {
            std::fs::write(downloads.0.join(name), format!("binary {name}")).unwrap();
        }
        TestHost {
            home: TempDirectory::new("home"),
            downloads,
            platform,
        }
    }

    pub fn environment(&self) -> HostEnvironment {
        HostEnvironment {
            platform: self.platform,
            home: self.home.0.clone(),
            xdg_config_home: None,
            user_name: Some("demo".into()),
            current_executable: self.downloads.0.join(executable_names(self.platform)[0]),
        }
    }

    pub fn options(&self, port: u16) -> InstallOptions {
        InstallOptions {
            port,
            herdr_session: None,
            source_directory: self.downloads.0.clone(),
        }
    }

    pub fn service_directory(&self) -> PathBuf {
        self.home.0.join(".purrdr").join("host-service")
    }
}

pub fn executable_names(platform: InstallPlatform) -> Vec<&'static str> {
    match platform {
        InstallPlatform::Windows => vec!["purrdr-host-service.exe", "purrdr-host-service-background.exe"],
        _ => vec!["purrdr-host-service"],
    }
}

/// 假主機上可觀察的系統狀態(不含家目錄的檔案)。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SystemState {
    /// `tailscale serve`:`<主機>:<埠>` → 路徑 → proxy 目標。
    pub serve: BTreeMap<String, BTreeMap<String, String>>,
    /// launchd 已載入的 label。
    pub launchd_loaded: BTreeSet<String>,
    /// systemd user 已啟用的 unit。
    pub systemd_enabled: BTreeSet<String>,
    /// systemd user 執行中的 unit。
    pub systemd_active: BTreeSet<String>,
    /// HKCU Run 的值。
    pub run_values: BTreeMap<String, String>,
    /// 背景執行中的程式(路徑與參數)。
    pub background_processes: Vec<Vec<String>>,
}

/// 可設定前置條件的假系統。
pub struct FakeSystem {
    pub home: PathBuf,
    pub state: SystemState,
    /// 找得到 tailscale 的路徑;None 表示沒安裝。
    pub tailscale_program: Option<String>,
    pub backend_state: String,
    pub magic_dns: bool,
    pub https_certificates: bool,
    /// `tailscale serve` 設定時回 Access denied(Linux 未設 operator)。
    pub serve_denied: bool,
    /// launchctl／systemctl／reg 是否失敗(例如沒有 systemd user session)。
    pub autostart_fails: bool,
    pub commands: Vec<String>,
}

impl FakeSystem {
    pub fn ready(home: &Path) -> FakeSystem {
        FakeSystem {
            home: home.to_path_buf(),
            state: SystemState::default(),
            tailscale_program: Some("tailscale".into()),
            backend_state: "Running".into(),
            magic_dns: true,
            https_certificates: true,
            serve_denied: false,
            autostart_fails: false,
            commands: Vec::new(),
        }
    }

    fn tailscale(&mut self, arguments: &[String]) -> CommandOutput {
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        match arguments.as_slice() {
            ["version"] => ok("1.90.0\n"),
            ["status", "--json"] => {
                let mut status = json!({
                    "BackendState": self.backend_state,
                    "Self": {"DNSName": format!("{FQDN}.")},
                    "CurrentTailnet": {"Name": "demo@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": self.magic_dns},
                });
                if self.https_certificates {
                    status["CertDomains"] = json!([FQDN]);
                }
                ok(&status.to_string())
            }
            ["serve", "status", "--json"] => {
                if self.state.serve.is_empty() {
                    return ok("{}\n");
                }
                let mut tcp = serde_json::Map::new();
                let mut web = serde_json::Map::new();
                for (host_port, handlers) in &self.state.serve {
                    let port = host_port.rsplit(':').next().unwrap();
                    tcp.insert(port.into(), json!({"HTTPS": true}));
                    let handlers: serde_json::Map<String, Value> =
                        handlers.iter().map(|(path, proxy)| (path.clone(), json!({"Proxy": proxy}))).collect();
                    web.insert(host_port.clone(), json!({"Handlers": handlers}));
                }
                ok(&json!({"TCP": tcp, "Web": web}).to_string())
            }
            ["serve", "--bg", https, target] if https.starts_with("--https=") => {
                if self.serve_denied {
                    return failed("Access denied: serve config denied\nUse 'sudo tailscale serve ...' or set operator\n");
                }
                let port = https.trim_start_matches("--https=");
                self.state
                    .serve
                    .entry(format!("{FQDN}:{port}"))
                    .or_default()
                    .insert("/".into(), (*target).into());
                ok("")
            }
            [https, "off"] if https.starts_with("--https=") => {
                let port = https.trim_start_matches("--https=");
                self.state.serve.remove(&format!("{FQDN}:{port}"));
                ok("")
            }
            other => panic!("假 tailscale 不認得：{other:?}"),
        }
    }

    fn launchctl(&mut self, arguments: &[String]) -> CommandOutput {
        if self.autostart_fails {
            return failed("Bootstrap failed: 5: Input/output error\n");
        }
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        match arguments.as_slice() {
            ["bootstrap", "gui/501", plist] => {
                assert!(Path::new(plist).is_file(), "bootstrap 前 plist 要存在：{plist}");
                let label = Path::new(plist).file_stem().unwrap().to_string_lossy().into_owned();
                self.state.launchd_loaded.insert(label);
                ok("")
            }
            ["bootout", target] => {
                let label = target.trim_start_matches("gui/501/");
                if self.state.launchd_loaded.remove(label) { ok("") } else { failed("Boot-out failed: 3: No such process\n") }
            }
            ["print", target] => {
                let label = target.trim_start_matches("gui/501/");
                if self.state.launchd_loaded.contains(label) { ok("state = running\n") } else { failed("Could not find service\n") }
            }
            other => panic!("假 launchctl 不認得：{other:?}"),
        }
    }

    fn systemctl(&mut self, arguments: &[String]) -> CommandOutput {
        if self.autostart_fails {
            return failed("Failed to connect to bus: No medium found\n");
        }
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let wants = self.home.join(".config/systemd/user/default.target.wants");
        match arguments.as_slice() {
            ["--user", "daemon-reload"] => ok(""),
            ["--user", "enable", "--now", unit] => {
                assert!(self.home.join(".config/systemd/user").join(unit).is_file(), "enable 前 unit 檔要存在");
                std::fs::create_dir_all(&wants).unwrap();
                std::fs::write(wants.join(unit), "symlink").unwrap();
                self.state.systemd_enabled.insert((*unit).into());
                self.state.systemd_active.insert((*unit).into());
                ok("")
            }
            ["--user", "disable", "--now", unit] => {
                let _ = std::fs::remove_file(wants.join(unit));
                self.state.systemd_enabled.remove(*unit);
                self.state.systemd_active.remove(*unit);
                ok("")
            }
            ["--user", "is-enabled", unit] => {
                if self.state.systemd_enabled.contains(*unit) { ok("enabled\n") } else { failed("disabled\n") }
            }
            other => panic!("假 systemctl 不認得：{other:?}"),
        }
    }

    fn reg(&mut self, arguments: &[String]) -> CommandOutput {
        if self.autostart_fails {
            return failed("ERROR: Access is denied.\n");
        }
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        match arguments.as_slice() {
            ["add", RUN_KEY, "/v", name, "/t", "REG_SZ", "/d", data, "/f"] => {
                self.state.run_values.insert((*name).into(), (*data).into());
                ok("The operation completed successfully.\n")
            }
            ["delete", RUN_KEY, "/v", name, "/f"] => {
                if self.state.run_values.remove(*name).is_some() { ok("") } else { failed("ERROR: The system was unable to find the specified registry key or value.\n") }
            }
            ["query", RUN_KEY, "/v", name] => {
                if self.state.run_values.contains_key(*name) { ok("") } else { failed("ERROR: unable to find\n") }
            }
            other => panic!("假 reg 不認得：{other:?}"),
        }
    }

    fn taskkill(&mut self, arguments: &[String]) -> CommandOutput {
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        match arguments.as_slice() {
            ["/F", "/IM", image, "/FI", filter] => {
                assert_eq!(*filter, "USERNAME eq demo");
                let before = self.state.background_processes.len();
                self.state
                    .background_processes
                    .retain(|process| !Path::new(&process[0]).file_name().is_some_and(|name| name == *image));
                if self.state.background_processes.len() < before { ok("SUCCESS\n") } else { failed("ERROR: not found\n") }
            }
            other => panic!("假 taskkill 不認得：{other:?}"),
        }
    }
}

fn ok(stdout: &str) -> CommandOutput {
    CommandOutput {
        success: true,
        stdout: stdout.into(),
        stderr: String::new(),
    }
}

fn failed(stderr: &str) -> CommandOutput {
    CommandOutput {
        success: false,
        stdout: String::new(),
        stderr: stderr.into(),
    }
}

impl HostSystem for FakeSystem {
    fn run(&mut self, program: &str, arguments: &[String]) -> std::io::Result<CommandOutput> {
        self.commands.push(format!("{program} {}", arguments.join(" ")));
        if program == "id" && arguments == ["-u"] {
            return Ok(ok("501\n"));
        }
        if program == "launchctl" {
            return Ok(self.launchctl(arguments));
        }
        if program == "systemctl" {
            return Ok(self.systemctl(arguments));
        }
        if program == "reg" {
            return Ok(self.reg(arguments));
        }
        if program == "taskkill" {
            return Ok(self.taskkill(arguments));
        }
        if self.tailscale_program.as_deref() == Some(program) {
            return Ok(self.tailscale(arguments));
        }
        Err(std::io::Error::new(std::io::ErrorKind::NotFound, format!("{program}: not found")))
    }

    fn run_attached(&mut self, program: &str, arguments: &[String]) -> std::io::Result<bool> {
        Ok(self.run(program, arguments)?.success)
    }

    fn spawn_detached(&mut self, program: &str, arguments: &[String]) -> std::io::Result<()> {
        self.commands.push(format!("spawn {program} {}", arguments.join(" ")));
        assert!(Path::new(program).is_file(), "背景啟動的執行檔要存在：{program}");
        let mut process = vec![program.to_owned()];
        process.extend(arguments.iter().cloned());
        self.state.background_processes.push(process);
        Ok(())
    }

    fn remove_directory_after_exit(&mut self, directory: &Path, empty_directories: &[PathBuf]) -> std::io::Result<()> {
        std::fs::remove_dir_all(directory)?;
        for empty in empty_directories {
            let _ = std::fs::remove_dir(empty);
        }
        Ok(())
    }
}
