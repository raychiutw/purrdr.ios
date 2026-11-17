//! 主機服務的安裝、自動啟動與解除安裝(#62、ADR-0010):暫存家目錄加上假系統，三平台流程都在每個 CI 平台跑。

mod install_support;

use install_support::{FQDN, FakeSystem, LAUNCH_AGENT_LABEL, TestHost};
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
