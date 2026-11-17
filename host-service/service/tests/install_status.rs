//! 狀態檢查指令：回報主機服務、tailscale serve、herdr 的狀態(#62)。

mod install_support;
mod support;

use install_support::{FQDN, FakeSystem, TestHost};
use purrdr_host_service::herdr_socket::SocketEnvironment;
use purrdr_host_service::install::{HerdrStatus, InstallPlatform, Installer, ServeStatus};
use support::{FakeHerdr, recorded};

const PLATFORMS: [InstallPlatform; 3] = [InstallPlatform::MacOs, InstallPlatform::Linux, InstallPlatform::Windows];

/// 一個目前沒有人在聽的 127.0.0.1 埠。
fn unused_port() -> u16 {
    std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap().local_addr().unwrap().port()
}

fn socket_environment_at(path: &str) -> SocketEnvironment {
    SocketEnvironment {
        socket_path: Some(path.into()),
        ..SocketEnvironment::default()
    }
}

#[tokio::test]
async fn status_before_install_reports_nothing_installed() {
    let host = TestHost::new(InstallPlatform::current());
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));

    let status = installer.status(&socket_environment_at("purrdr-status-test-missing-socket")).await;

    assert!(!status.installed);
    assert!(!status.autostart_registered);
    assert!(!status.listening);
    assert_eq!(status.serve, ServeStatus::NotConfigured);
}

#[tokio::test]
async fn status_after_install_reports_autostart_and_serve_on_every_platform() {
    for platform in PLATFORMS {
        let host = TestHost::new(platform);
        let port = unused_port();
        let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
        installer.install(&host.options(port), |_| true).unwrap();

        let status = installer.status(&socket_environment_at("purrdr-status-test-missing-socket")).await;

        assert!(status.installed, "{platform:?}");
        assert!(status.autostart_registered, "{platform:?}");
        assert!(!status.listening, "{platform:?}");
        assert_eq!(status.https_address.as_deref(), Some(format!("https://{FQDN}").as_str()));
        assert_eq!(status.serve, ServeStatus::Configured(format!("http://127.0.0.1:{port}")), "{platform:?}");
        assert!(matches!(status.herdr, HerdrStatus::NotRunning(_)), "{platform:?}: {:?}", status.herdr);
    }
}

#[tokio::test]
async fn status_reports_running_service_and_herdr() {
    let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson"))]).await;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let host = TestHost::new(InstallPlatform::current());
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
    installer.install(&host.options(listener.local_addr().unwrap().port()), |_| true).unwrap();

    let status = installer.status(&socket_environment_at(herdr.socket.path())).await;

    assert!(status.listening);
    assert_eq!(status.herdr, HerdrStatus::Running { version: "0.9.5".into() });
    let report = status.to_string();
    assert!(report.contains("herdr: running (0.9.5)"), "{report}");
    assert!(report.contains(&format!("https://{FQDN}")), "{report}");
}

#[tokio::test]
async fn status_flags_serve_pointing_somewhere_else() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
    installer.install(&host.options(unused_port()), |_| true).unwrap();
    let mut system = FakeSystem::ready(&host.home.0);
    system
        .state
        .serve
        .insert(format!("{FQDN}:443"), [("/".to_owned(), "http://127.0.0.1:3000".to_owned())].into());
    let mut installer = Installer::new(host.environment(), system);

    let status = installer.status(&socket_environment_at("purrdr-status-test-missing-socket")).await;

    assert_eq!(status.serve, ServeStatus::Other("/ -> http://127.0.0.1:3000".into()));
}
