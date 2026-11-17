//! 主機服務的安裝、自動啟動與解除安裝(#62、ADR-0010):暫存家目錄加上假系統，三平台流程都在每個 CI 平台跑。

mod install_support;

use install_support::{FQDN, FakeSystem, LAUNCH_AGENT_LABEL, TestHost, snapshot};
use purrdr_host_service::install::{InstallPlatform, Installer};

const PORT: u16 = 47_820;

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

/// 安裝前就有的東西：其他 Purrdr 功能的檔案、別人的 LaunchAgent、其他埠的 `tailscale serve`。
fn existing_files_and_settings(host: &TestHost, system: &mut FakeSystem) {
    let push = host.home.0.join(".purrdr/push-device/pairing");
    std::fs::create_dir_all(push.parent().unwrap()).unwrap();
    std::fs::write(push, "secret").unwrap();
    std::fs::create_dir_all(host.home.0.join("Library/LaunchAgents")).unwrap();
    std::fs::write(host.home.0.join("Library/LaunchAgents/other.plist"), "other").unwrap();
    system
        .state
        .serve
        .insert(format!("{FQDN}:8443"), [("/".to_owned(), "http://127.0.0.1:3000".to_owned())].into());
}

#[test]
fn uninstall_restores_home_and_system_settings_exactly() {
    for prepare in [false, true] {
        let host = TestHost::new(InstallPlatform::MacOs);
        let mut system = FakeSystem::ready(&host.home.0);
        if prepare {
            existing_files_and_settings(&host, &mut system);
        }
        let home_before = snapshot(&host.home.0);
        let system_before = system.state.clone();
        let mut installer = Installer::new(host.environment(), system);
        installer.install(&host.options(PORT), |_| true).unwrap();

        installer.uninstall().unwrap();

        assert_eq!(snapshot(&host.home.0), home_before, "家目錄(prepare = {prepare})");
        assert_eq!(installer.system().state, system_before, "系統設定(prepare = {prepare})");
    }
}
