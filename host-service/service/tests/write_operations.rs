//! 寫入類操作(協定 schema 標 x-write):唯讀裝置被拒絕且不會送到 herdr(spec #52、#56)。

mod support;

use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, recorded, start_service};

fn hello(request_id: &str) -> Value {
    json!({"type": "hello", "request_id": request_id, "protocol_version": 1})
}

fn send_keys(request_id: &str) -> Value {
    json!({"type": "pane.send_keys", "request_id": request_id, "pane_id": "w1:p6", "keys": ["down", "enter"]})
}

/// herdr 0.9.5 的 pane.send_keys 成功回應(`{"type":"ok"}`,與 app 的 TypedResult 一致)。
async fn herdr_accepting_keys() -> FakeHerdr {
    FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("session.snapshot", recorded("session.snapshot.ndjson")),
        ("pane.send_keys", json!({"id": "", "result": {"type": "ok"}})),
    ])
    .await
}

#[tokio::test]
async fn send_keys_is_forwarded_to_herdr_pane_send_keys() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let reply = client.request(send_keys("r2")).await;

    assert_eq!(reply, json!({"type": "pane.send_keys.result", "request_id": "r2"}));
    let forwarded = herdr.requests().into_iter().find(|request| request["method"] == "pane.send_keys").unwrap();
    assert_eq!(forwarded["params"], json!({"pane_id": "w1:p6", "keys": ["down", "enter"]}));
}

#[tokio::test]
async fn read_only_device_cannot_send_keys() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let read_only = service.pair_device("借出的 iPad", true);
    let mut client = TestClient::connect_with_token(&service, Some(&read_only.device_token)).await;
    client.request(hello("r1")).await;

    let reply = client.request(send_keys("r2")).await;

    assert_eq!(reply["type"], "error");
    assert_eq!(reply["request_id"], "r2");
    assert_eq!(reply["code"], "read_only_device");
    assert_eq!(herdr.methods(), ["ping"]);
}

#[tokio::test]
async fn read_only_device_can_still_list_agents() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let read_only = service.pair_device("借出的 iPad", true);
    let mut client = TestClient::connect_with_token(&service, Some(&read_only.device_token)).await;
    client.request(hello("r1")).await;

    let reply = client.request(json!({"type": "agents.list", "request_id": "r2"})).await;

    assert_eq!(reply["type"], "agents.list.result");
}

#[tokio::test]
async fn send_keys_before_handshake_requires_handshake() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;

    let reply = client.request(send_keys("r1")).await;

    assert_eq!(reply["code"], "handshake_required");
    assert!(herdr.methods().is_empty());
}

#[tokio::test]
async fn send_keys_to_missing_pane_reports_herdr_error() {
    let herdr = FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("pane.send_keys", recorded("error.pane-not-found.ndjson")),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let reply = client.request(send_keys("r2")).await;

    assert_eq!(reply["code"], "herdr_error");
    assert_eq!(reply["herdr_code"], "pane_not_found");
}
