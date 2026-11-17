//! 寫入類操作(協定 schema 標 x-write):對應到 herdr 的方法，唯讀裝置被拒絕且不會送到 herdr(spec #52、#56、#60)。

mod support;

use std::time::Duration;

use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, recorded, start_service};

fn hello(request_id: &str) -> Value {
    json!({"type": "hello", "request_id": request_id, "protocol_version": 1})
}

fn send_keys(request_id: &str) -> Value {
    json!({"type": "pane.send_keys", "request_id": request_id, "pane_id": "w1:p6", "keys": ["down", "enter"]})
}

fn prompt(request_id: &str) -> Value {
    json!({
        "type": "agent.prompt",
        "request_id": request_id,
        "pane_id": "w1:p6",
        "text": "幫我看一下測試",
        "wait": {"until": ["working", "blocked"], "timeout_ms": 8000}
    })
}

fn send_text(request_id: &str) -> Value {
    json!({"type": "pane.send_text", "request_id": request_id, "pane_id": "w1:p6", "text": "yes"})
}

/// herdr `agent.prompt` 的成功回應(形狀依 `herdr api schema --json`)。
fn agent_prompted() -> Value {
    json!({"id": "", "result": {"type": "agent_prompted", "agent": {"pane_id": "w1:p6", "agent_status": "working"}}})
}

/// herdr 0.9.5 的 pane.send_keys 成功回應(`{"type":"ok"}`,與 app 的 TypedResult 一致)。
async fn herdr_accepting_keys() -> FakeHerdr {
    FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("session.snapshot", recorded("session.snapshot.ndjson")),
        ("pane.send_keys", json!({"id": "", "result": {"type": "ok"}})),
        ("pane.send_text", json!({"id": "", "result": {"type": "ok"}})),
        ("agent.prompt", agent_prompted()),
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

#[tokio::test]
async fn prompt_is_forwarded_to_herdr_agent_prompt_with_its_wait() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let reply = client.request(prompt("r2")).await;

    assert_eq!(reply, json!({"type": "agent.prompt.result", "request_id": "r2"}));
    let forwarded = herdr.requests().into_iter().find(|request| request["method"] == "agent.prompt").unwrap();
    assert_eq!(
        forwarded["params"],
        json!({"target": "w1:p6", "text": "幫我看一下測試", "wait": {"until": ["working", "blocked"], "timeout_ms": 8000}})
    );
}

#[tokio::test]
async fn prompt_without_wait_is_forwarded_without_wait() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    client
        .request(json!({"type": "agent.prompt", "request_id": "r2", "pane_id": "w1:p6", "text": "/compact"}))
        .await;

    let forwarded = herdr.requests().into_iter().find(|request| request["method"] == "agent.prompt").unwrap();
    assert_eq!(forwarded["params"], json!({"target": "w1:p6", "text": "/compact"}));
}

#[tokio::test]
async fn prompt_result_carries_herdr_delivery() {
    let herdr = FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        (
            "agent.prompt",
            json!({"id": "", "result": {"type": "agent_prompted", "delivery": "written_to_pty"}}),
        ),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let reply = client.request(prompt("r2")).await;

    assert_eq!(reply, json!({"type": "agent.prompt.result", "request_id": "r2", "delivery": "written_to_pty"}));
}

#[tokio::test]
async fn prompt_waits_for_herdr_longer_than_a_plain_request() {
    let herdr = FakeHerdr::start_delayed(vec![
        ("ping", recorded("ping.ndjson"), Duration::ZERO),
        ("agent.prompt", agent_prompted(), Duration::from_secs(11)),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    client.send(prompt("r2")).await;
    let reply = client.receive_within(Duration::from_secs(25)).await;

    assert_eq!(reply["type"], "agent.prompt.result");
}

#[tokio::test]
async fn prompt_to_blocked_agent_keeps_herdr_error_code() {
    let herdr = FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        (
            "agent.prompt",
            json!({"id": "", "error": {"code": "agent_blocked", "message": "agent is waiting for input"}}),
        ),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let reply = client.request(prompt("r2")).await;

    assert_eq!(reply["code"], "herdr_error");
    assert_eq!(reply["herdr_code"], "agent_blocked");
}

#[tokio::test]
async fn send_text_is_forwarded_to_herdr_pane_send_text() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let reply = client.request(send_text("r2")).await;

    assert_eq!(reply, json!({"type": "pane.send_text.result", "request_id": "r2"}));
    let forwarded = herdr.requests().into_iter().find(|request| request["method"] == "pane.send_text").unwrap();
    assert_eq!(forwarded["params"], json!({"pane_id": "w1:p6", "text": "yes"}));
}

#[tokio::test]
async fn read_only_device_cannot_prompt_or_send_text() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let read_only = service.pair_device("借出的 iPad", true);
    let mut client = TestClient::connect_with_token(&service, Some(&read_only.device_token)).await;
    client.request(hello("r1")).await;

    let prompt_reply = client.request(prompt("r2")).await;
    let text_reply = client.request(send_text("r3")).await;

    assert_eq!(prompt_reply["code"], "read_only_device");
    assert_eq!(prompt_reply["request_id"], "r2");
    assert_eq!(text_reply["code"], "read_only_device");
    assert_eq!(text_reply["request_id"], "r3");
    assert_eq!(herdr.methods(), ["ping"]);
}

#[tokio::test]
async fn welcome_tells_the_device_whether_it_is_read_only() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let read_only = service.pair_device("借出的 iPad", true);
    let mut writable_client = TestClient::connect(&service).await;
    let mut read_only_client = TestClient::connect_with_token(&service, Some(&read_only.device_token)).await;

    let writable_welcome = writable_client.request(hello("r1")).await;
    let read_only_welcome = read_only_client.request(hello("r1")).await;

    assert_eq!(writable_welcome["read_only"], false);
    assert_eq!(read_only_welcome["read_only"], true);
}

#[tokio::test]
async fn prompt_and_text_before_handshake_require_handshake() {
    let herdr = herdr_accepting_keys().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;

    let prompt_reply = client.request(prompt("r1")).await;
    let text_reply = client.request(send_text("r2")).await;

    assert_eq!(prompt_reply["code"], "handshake_required");
    assert_eq!(text_reply["code"], "handshake_required");
    assert!(herdr.methods().is_empty());
}
