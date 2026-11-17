//! 主機服務的安裝、自動啟動與解除安裝(#62、ADR-0010):暫存家目錄加上假系統，三平台流程都在每個 CI 平台跑。

mod install_support;

use install_support::{FQDN, FakeSystem, LAUNCH_AGENT_LABEL, SYSTEMD_UNIT, TestHost, snapshot};
use purrdr_host_service::install::{InstallPlatform, Installer};

const PORT: u16 = 47_820;
// Windows 在後面的 cycle 加入。
const PLATFORMS: [InstallPlatform; 2] = [InstallPlatform::MacOs, InstallPlatform::Linux];

#[test]
fn macos_install_starts_launch_agent_and_serves_https_through_tailscale() {
    let host = TestHost::new(InstallPlatform::MacOs);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));

    let installed = installer.install(&host.options(PORT), |_| true).unwrap();

    assert_eq!(installed.https_address, format!("https://{FQDN}"));
    let system = installer.system();
    assert!(system.state.launchd_loaded.contains(LAUNCH_AGENT_LABEL));
    assert_eq!(system.state.serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:47820");
    let plist = std::fs::read_to_string(host.home.0.join(format!("Library/LaunchAgents/{LAUNCH_AGENT_LABEL}.plist"))).unwrap();
    let installed_binary = host.service_directory().join("bin/purrdr-host-service");
    assert!(plist.contains(&format!("<string>{}</string>", installed_binary.display())), "{plist}");
    assert!(plist.contains("<key>RunAtLoad</key>"));
    assert_eq!(std::fs::read_to_string(&installed_binary).unwrap(), "binary purrdr-host-service");
    let config: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(host.service_directory().join("config.json")).unwrap()).unwrap();
    assert_eq!(config["https_address"], format!("https://{FQDN}"));
}

#[test]
fn linux_install_enables_systemd_user_unit_started_at_login() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));

    installer.install(&host.options(PORT), |_| true).unwrap();

    let system = installer.system();
    assert!(system.state.systemd_enabled.contains(SYSTEMD_UNIT));
    assert!(system.state.systemd_active.contains(SYSTEMD_UNIT));
    assert_eq!(system.state.serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:47820");
    let unit = std::fs::read_to_string(host.home.0.join(".config/systemd/user").join(SYSTEMD_UNIT)).unwrap();
    let installed_binary = host.service_directory().join("bin/purrdr-host-service");
    assert!(unit.contains(&format!("ExecStart=\"{}\" --port 47820", installed_binary.display())), "{unit}");
    assert!(unit.contains("WantedBy=default.target"), "{unit}");
}

#[test]
fn linux_unit_goes_to_xdg_config_home_when_set() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut environment = host.environment();
    environment.xdg_config_home = Some(host.home.0.join("xdg"));
    let mut system = FakeSystem::ready(&host.home.0);
    system.systemd_user_directory = host.home.0.join("xdg/systemd/user");
    let mut installer = Installer::new(environment, system);

    installer.install(&host.options(PORT), |_| true).unwrap();

    assert!(host.home.0.join("xdg/systemd/user").join(SYSTEMD_UNIT).is_file());
    assert!(!host.home.0.join(".config").exists());
}

/// 安裝前就有的東西：其他 Purrdr 功能的檔案、別的自動啟動項目、其他埠的 `tailscale serve`。
fn existing_files_and_settings(host: &TestHost, system: &mut FakeSystem) {
    let push = host.home.0.join(".purrdr/push-device/pairing");
    std::fs::create_dir_all(push.parent().unwrap()).unwrap();
    std::fs::write(push, "secret").unwrap();
    std::fs::create_dir_all(host.home.0.join("Library/LaunchAgents")).unwrap();
    std::fs::write(host.home.0.join("Library/LaunchAgents/other.plist"), "other").unwrap();
    std::fs::create_dir_all(host.home.0.join(".config/systemd/user/default.target.wants")).unwrap();
    std::fs::write(host.home.0.join(".config/systemd/user/default.target.wants/other.service"), "other").unwrap();
    system.state.systemd_enabled.insert("other.service".into());
    system.state.run_values.insert("OtherApp".into(), "other.exe".into());
    system
        .state
        .serve
        .insert(format!("{FQDN}:8443"), [("/".to_owned(), "http://127.0.0.1:3000".to_owned())].into());
}

#[test]
fn uninstall_restores_home_and_system_settings_exactly() {
    for platform in PLATFORMS {
        for prepare in [false, true] {
            let host = TestHost::new(platform);
            let mut system = FakeSystem::ready(&host.home.0);
            if prepare {
                existing_files_and_settings(&host, &mut system);
            }
            let home_before = snapshot(&host.home.0);
            let system_before = system.state.clone();
            let mut installer = Installer::new(host.environment(), system);
            installer.install(&host.options(PORT), |_| true).unwrap();

            let uninstalled = installer.uninstall().unwrap();

            assert_eq!(snapshot(&host.home.0), home_before, "家目錄({platform:?}, prepare = {prepare})");
            assert_eq!(installer.system().state, system_before, "系統設定({platform:?}, prepare = {prepare})");
            assert!(uninstalled.warnings.is_empty(), "{:?}", uninstalled.warnings);
        }
    }
}
