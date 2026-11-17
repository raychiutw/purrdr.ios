//! 裝置權杖(spec #52、#56):WSS 必須帶有效權杖;無效或已撤銷時以明確錯誤碼與 close code 4401 關閉。

mod support;

use std::time::SystemTime;

use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, TestHostService, recorded, start_service};

fn hello(request_id: &str) -> Value {
    json!({"type": "hello", "request_id": request_id, "protocol_version": 1})
}

async fn herdr() -> FakeHerdr {
    FakeHerdr::start(vec![("ping", recorded("ping.ndjson"))]).await
}

/// 連上後送 hello,回傳第一個回應與連線(主機服務可能在收到 hello 前就關閉)。
async fn hello_then_reply(service: &TestHostService, device_token: Option<&str>) -> (Value, TestClient) {
    let mut client = TestClient::connect_with_token(service, device_token).await;
    client.try_send(hello("r1")).await;
    let reply = client.receive().await;
    (reply, client)
}

#[tokio::test]
async fn websocket_without_device_token_is_closed_as_token_invalid() {
    let herdr = herdr().await;
    let service = start_service(herdr.socket.clone()).await;

    let (reply, mut client) = hello_then_reply(&service, None).await;

    assert_eq!(reply["type"], "error");
    assert_eq!(reply["code"], "device_token_invalid");
    assert_eq!(client.closed().await, Some((4401, "device_token_invalid".to_owned())));
    assert!(herdr.methods().is_empty());
}

#[tokio::test]
async fn websocket_with_unknown_device_token_is_closed_as_token_invalid() {
    let herdr = herdr().await;
    let service = start_service(herdr.socket.clone()).await;
    let forged = format!("purrdr_dt_{}", "0".repeat(64));

    let (reply, mut client) = hello_then_reply(&service, Some(&forged)).await;

    assert_eq!(reply["code"], "device_token_invalid");
    assert_eq!(client.closed().await, Some((4401, "device_token_invalid".to_owned())));
    assert!(herdr.methods().is_empty());
}

#[tokio::test]
async fn websocket_with_revoked_device_token_is_closed_as_token_revoked() {
    let herdr = herdr().await;
    let service = start_service(herdr.socket.clone()).await;
    let issued = service.pair_device("遺失的手機", false);
    service.store().revoke(&issued.device.device_id, SystemTime::now()).unwrap();

    let (reply, mut client) = hello_then_reply(&service, Some(&issued.device_token)).await;

    assert_eq!(reply["code"], "device_token_revoked");
    assert_eq!(client.closed().await, Some((4401, "device_token_revoked".to_owned())));
    assert!(herdr.methods().is_empty());
}

#[tokio::test]
async fn websocket_with_paired_device_token_completes_handshake() {
    let herdr = herdr().await;
    let service = start_service(herdr.socket.clone()).await;
    let issued = service.pair_device("Ray 的 iPhone", false);
    let mut client = TestClient::connect_with_token(&service, Some(&issued.device_token)).await;

    let welcome = client.request(hello("r1")).await;

    assert_eq!(welcome["type"], "welcome");
}

#[tokio::test]
async fn device_revoked_while_connected_is_disconnected_on_its_next_message() {
    let herdr = herdr().await;
    let service = start_service(herdr.socket.clone()).await;
    let issued = service.pair_device("Ray 的 iPhone", false);
    let mut client = TestClient::connect_with_token(&service, Some(&issued.device_token)).await;
    client.request(hello("r1")).await;

    service.store().revoke(&issued.device.device_id, SystemTime::now()).unwrap();
    let reply = client.request(json!({"type": "agents.list", "request_id": "r2"})).await;

    assert_eq!(reply["code"], "device_token_revoked");
    assert_eq!(client.closed().await, Some((4401, "device_token_revoked".to_owned())));
    assert_eq!(herdr.methods(), ["ping"]);
}

#[tokio::test]
async fn connecting_records_last_connected_time() {
    let herdr = herdr().await;
    let service = start_service(herdr.socket.clone()).await;
    let issued = service.pair_device("Ray 的 iPhone", false);
    let before = service.store().devices().unwrap();

    let mut client = TestClient::connect_with_token(&service, Some(&issued.device_token)).await;
    client.request(hello("r1")).await;

    let device_named =
        |devices: &[purrdr_host_service::device_store::Device]| devices.iter().find(|device| device.device_id == issued.device.device_id).cloned().unwrap();
    assert_eq!(device_named(&before).last_connected_at, None);
    assert!(device_named(&service.store().devices().unwrap()).last_connected_at.is_some());
}

#[tokio::test]
async fn host_never_stores_device_token_in_plain_text() {
    let herdr = herdr().await;
    let service = start_service(herdr.socket.clone()).await;
    let issued = service.pair_device("Ray 的 iPhone", false);
    let mut client = TestClient::connect_with_token(&service, Some(&issued.device_token)).await;
    client.request(hello("r1")).await;

    let stored = service.stored_files();

    assert!(stored.contains(&issued.device.device_id), "裝置應該有存檔");
    assert!(!stored.contains(&issued.device_token));
    assert!(!stored.contains(&service.device_token));
}
