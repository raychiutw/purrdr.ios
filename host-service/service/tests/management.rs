//! 主機上的管理指令(spec #52、#56):`pair` 顯示 QR code 與配對碼、`devices` 列出裝置、`revoke` 撤銷裝置。

mod support;

use std::path::Path;
use std::time::SystemTime;

use purrdr_host_service::herdr_socket::{Platform, SocketEnvironment};
use purrdr_host_service::management;
use serde_json::json;
use support::{FakeHerdr, TestClient, TestHostService, http_request, recorded, start_service};

const ADDRESS: &str = "https://studio.example-tailnet.ts.net";

fn arguments(text: &str, state_directory: &Path) -> Vec<String> {
    let mut arguments: Vec<String> = text.split_whitespace().map(str::to_owned).collect();
    arguments.push("--state-dir".into());
    arguments.push(state_directory.to_string_lossy().into_owned());
    arguments
}

fn run(text: &str, state_directory: &Path) -> Result<String, String> {
    management::run(&arguments(text, state_directory), Platform::current(), &SocketEnvironment::default(), SystemTime::now())
}

/// 輸出裡 `Pairing code:` 那行的配對碼。
fn printed_code(output: &str) -> String {
    let line = output.lines().find(|line| line.contains("Pairing code:")).expect("有印出配對碼");
    line.split_whitespace().nth(2).unwrap().to_owned()
}

async fn service() -> (FakeHerdr, TestHostService) {
    let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson"))]).await;
    let service = start_service(herdr.socket.clone()).await;
    (herdr, service)
}

#[tokio::test]
async fn pair_prints_qr_code_address_and_a_code_the_running_service_accepts() {
    let (_herdr, service) = service().await;

    let output = run(&format!("pair --address {ADDRESS}"), service.state_directory.path()).unwrap();

    let code = printed_code(&output);
    assert_eq!(code.len(), 9, "{output}");
    assert!(output.contains(ADDRESS));
    assert!(output.contains(&format!("purrdr://pair?address=https%3A%2F%2Fstudio.example-tailnet.ts.net&code={code}")));
    assert!(output.contains('█') || output.contains('▀') || output.contains('▄'), "沒有 QR code:\n{output}");
    let (status, body) = http_request(
        &service,
        "POST",
        "/v1/pair",
        None,
        Some(json!({"pairing_code": code, "device_name": "Ray 的 iPhone"})),
    )
    .await;
    assert_eq!((status, body["read_only"].as_bool()), (200, Some(false)));
}

#[tokio::test]
async fn pair_read_only_issues_read_only_device() {
    let (_herdr, service) = service().await;

    let output = run(&format!("pair --read-only --address {ADDRESS}"), service.state_directory.path()).unwrap();

    let (_, body) = http_request(
        &service,
        "POST",
        "/v1/pair",
        None,
        Some(json!({"pairing_code": printed_code(&output), "device_name": "借出的 iPad"})),
    )
    .await;
    assert_eq!(body["read_only"], true);
    assert!(output.contains("read-only"));
}

#[test]
fn pair_uses_address_saved_by_installer() {
    let state_directory = tempfile::tempdir().unwrap();
    std::fs::write(state_directory.path().join("config.json"), json!({"https_address": ADDRESS}).to_string()).unwrap();

    let output = run("pair", state_directory.path()).unwrap();

    assert!(output.contains(ADDRESS));
}

#[test]
fn pair_needs_an_https_address() {
    let state_directory = tempfile::tempdir().unwrap();

    let missing = run("pair", state_directory.path()).unwrap_err();
    let plain_http = run("pair --address http://studio.example-tailnet.ts.net", state_directory.path()).unwrap_err();

    assert!(missing.contains("--address"), "{missing}");
    assert!(plain_http.contains("https://"), "{plain_http}");
}

#[tokio::test]
async fn devices_lists_name_access_last_connection_and_revocation() {
    let (_herdr, service) = service().await;
    let phone = service.pair_device("Ray 的 iPhone", false);
    let tablet = service.pair_device("借出的 iPad", true);
    let lost = service.pair_device("遺失的手機", false);
    let mut client = TestClient::connect_with_token(&service, Some(&phone.device_token)).await;
    client.request(json!({"type": "hello", "request_id": "r1", "protocol_version": 1})).await;
    service.store().revoke(&lost.device.device_id, SystemTime::now()).unwrap();

    let output = run("devices", service.state_directory.path()).unwrap();

    let line_of = |device_id: &str| output.lines().find(|line| line.contains(device_id)).unwrap_or_else(|| panic!("{output}")).to_owned();
    let phone_line = line_of(&phone.device.device_id);
    let tablet_line = line_of(&tablet.device.device_id);
    let lost_line = line_of(&lost.device.device_id);
    assert!(phone_line.contains("Ray 的 iPhone") && phone_line.contains("full") && phone_line.contains('Z'), "{phone_line}");
    assert!(tablet_line.contains("read-only") && tablet_line.contains("never"), "{tablet_line}");
    assert!(lost_line.contains("revoked"), "{lost_line}");
    assert!(!phone_line.contains("revoked"), "{phone_line}");
}

#[tokio::test]
async fn revoke_disconnects_the_device_and_is_audited() {
    let (_herdr, service) = service().await;
    let phone = service.pair_device("遺失的手機", false);

    let output = run(&format!("revoke {}", phone.device.device_id), service.state_directory.path()).unwrap();

    assert!(output.contains("遺失的手機"), "{output}");
    let mut client = TestClient::connect_with_token(&service, Some(&phone.device_token)).await;
    assert_eq!(client.receive().await["code"], "device_token_revoked");
    let audit_log = service.audit_log();
    assert!(audit_log.lines().any(|line| {
        let event: serde_json::Value = serde_json::from_str(line).unwrap();
        event["event"] == "revoked" && event["device_id"] == phone.device.device_id.as_str() && event["by"] == "host"
    }));
}

#[test]
fn revoke_unknown_device_fails() {
    let state_directory = tempfile::tempdir().unwrap();

    let error = run("revoke 0000000000000000", state_directory.path()).unwrap_err();

    assert!(error.contains("0000000000000000"), "{error}");
}

#[test]
fn unknown_subcommand_arguments_are_rejected() {
    let state_directory = tempfile::tempdir().unwrap();

    assert!(run("pair --bind 0.0.0.0", state_directory.path()).is_err());
    assert!(run("revoke", state_directory.path()).is_err());
    assert!(run("devices extra", state_directory.path()).is_err());
}

#[test]
fn management_defaults_to_the_purrdr_folder_in_home() {
    let home = tempfile::tempdir().unwrap();
    let environment = SocketEnvironment {
        home: Some(home.path().to_string_lossy().into_owned()),
        user_profile: Some(home.path().to_string_lossy().into_owned()),
        ..SocketEnvironment::default()
    };

    let output = management::run(&["pair".to_owned(), "--address".to_owned(), ADDRESS.to_owned()], Platform::current(), &environment, SystemTime::now());

    assert!(output.is_ok(), "{output:?}");
    assert!(home.path().join(".purrdr").join("host-service").join("devices.json").exists());
}
