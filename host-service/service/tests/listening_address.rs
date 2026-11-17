//! 主機服務只聽 127.0.0.1,不自己做 TLS(ADR-0010):對外的 HTTPS 由 `tailscale serve` 提供。

mod support;

use std::net::{IpAddr, Ipv4Addr, TcpStream, UdpSocket};

use purrdr_host_service::herdr_socket::{Platform, SocketEnvironment};
use purrdr_host_service::{DEFAULT_PORT, HostServiceConfig};
use support::{start_service, unique_socket};

/// 這台機器對外的 IPv4(UDP connect 不會送出封包，只是讓系統選出介面);沒有就回 None。
fn non_loopback_address() -> Option<IpAddr> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    socket.connect((Ipv4Addr::new(192, 0, 2, 1), 9)).ok()?;
    let address = socket.local_addr().ok()?.ip();
    (!address.is_loopback() && !address.is_unspecified()).then_some(address)
}

#[tokio::test]
async fn service_listens_on_loopback_only() {
    let service = start_service(unique_socket()).await;

    assert_eq!(service.local_addr().ip(), IpAddr::V4(Ipv4Addr::LOCALHOST));
}

#[tokio::test]
async fn service_is_not_reachable_from_other_interfaces() {
    let service = start_service(unique_socket()).await;
    let Some(address) = non_loopback_address() else {
        eprintln!("這台機器沒有 loopback 以外的 IPv4,略過");
        return;
    };

    let connection = TcpStream::connect_timeout(&(address, service.local_addr().port()).into(), std::time::Duration::from_secs(2));

    assert!(connection.is_err(), "從 {address} 連得上主機服務");
}

#[tokio::test]
async fn plain_websocket_without_tls_is_served_only_on_protocol_path() {
    let service = start_service(unique_socket()).await;

    let protocol_path = tokio_tungstenite::connect_async(format!("ws://{}/v1/ws", service.local_addr())).await;
    let other_path = tokio_tungstenite::connect_async(format!("ws://{}/ws", service.local_addr())).await;

    assert!(protocol_path.is_ok());
    assert!(other_path.is_err());
}

fn arguments(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn environment() -> SocketEnvironment {
    SocketEnvironment {
        home: Some("/Users/demo".into()),
        ..SocketEnvironment::default()
    }
}

#[test]
fn port_defaults_and_can_be_configured() {
    let default = HostServiceConfig::from_arguments(&[], Platform::Unix, &environment()).unwrap();
    let configured = HostServiceConfig::from_arguments(&arguments("--port 47999"), Platform::Unix, &environment()).unwrap();

    assert_eq!(default.port, DEFAULT_PORT);
    assert_eq!(configured.port, 47999);
}

#[test]
fn state_directory_defaults_to_purrdr_folder_in_home_and_can_be_configured() {
    let windows_environment = SocketEnvironment {
        app_data: Some(r"C:\Users\demo\AppData\Roaming".into()),
        user_profile: Some(r"C:\Users\demo".into()),
        ..SocketEnvironment::default()
    };

    let unix = HostServiceConfig::from_arguments(&[], Platform::Unix, &environment()).unwrap();
    let windows = HostServiceConfig::from_arguments(&[], Platform::Windows, &windows_environment).unwrap();
    let configured = HostServiceConfig::from_arguments(&arguments("--state-dir /tmp/purrdr-test"), Platform::Unix, &environment()).unwrap();

    assert_eq!(unix.state_directory, std::path::Path::new("/Users/demo/.purrdr/host-service"));
    assert_eq!(windows.state_directory, std::path::Path::new(r"C:\Users\demo").join(".purrdr").join("host-service"));
    assert_eq!(configured.state_directory, std::path::Path::new("/tmp/purrdr-test"));
}

#[test]
fn herdr_session_can_be_selected() {
    let config = HostServiceConfig::from_arguments(&arguments("--session work"), Platform::Unix, &environment()).unwrap();

    assert_eq!(config.herdr_socket.path(), "/Users/demo/.config/herdr/sessions/work/herdr.sock");
}

#[test]
fn unknown_or_incomplete_arguments_are_rejected() {
    for text in ["--bind 0.0.0.0", "--port", "--port not-a-number", "--tls"] {
        assert!(
            HostServiceConfig::from_arguments(&arguments(text), Platform::Unix, &environment()).is_err(),
            "{text}"
        );
    }
}
