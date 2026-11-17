//! 主機服務的對外協定(spec #52 接縫 ②):以真正的 WebSocket client 連上主機服務，
//! 背後是回放錄製 NDJSON 的假 herdr socket。

mod support;

use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, recorded, start_service, unique_socket};

fn hello(request_id: &str) -> Value {
    json!({"type": "hello", "request_id": request_id, "protocol_version": 1})
}

/// 錄製的 `session.snapshot`(作者的 Mac,3 個 Claude Code agent + 1 個 shell pane)。
async fn herdr_with_snapshot() -> FakeHerdr {
    FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("session.snapshot", recorded("session.snapshot.ndjson")),
    ])
    .await
}

#[tokio::test]
async fn handshake_exchanges_protocol_host_service_version_and_herdr_capabilities() {
    let herdr = herdr_with_snapshot().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;

    let welcome = client
        .request(json!({"type": "hello", "request_id": "r1", "protocol_version": 1, "app_version": "1.4.0"}))
        .await;

    assert_eq!(
        welcome,
        json!({
            "type": "welcome",
            "request_id": "r1",
            "protocol_version": 1,
            "host_service_version": env!("CARGO_PKG_VERSION"),
            "herdr": {
                "version": "0.9.5",
                "protocol": 22,
                "capabilities": ["detached_server_daemon", "health_check", "live_handoff", "ssh_agent_registration", "surface_interest"]
            },
            "read_only": false
        })
    );
    assert_eq!(herdr.methods(), ["ping"]);
}

#[tokio::test]
async fn agents_list_returns_agents_from_herdr_session_snapshot() {
    let herdr = herdr_with_snapshot().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let result = client.request(json!({"type": "agents.list", "request_id": "r2"})).await;

    assert_eq!(result["type"], "agents.list.result");
    assert_eq!(result["request_id"], "r2");
    assert_eq!(
        result["workspaces"],
        json!([{"workspace_id": "w1", "label": "garden-journal"}, {"workspace_id": "w2", "label": "scratch"}])
    );
    assert_eq!(
        result["agents"][0],
        json!({
            "pane_id": "w1:p6",
            "workspace_id": "w1",
            "tab_id": "w1:t6",
            "agent": "claude",
            "status": "idle",
            "title": "整理植物照片的標籤",
            "cwd": "/Users/demo/Projects/garden-journal",
            "session": {"source": "herdr:claude", "agent": "claude", "kind": "id", "value": "00000000-0000-0000-0000-000000000001"}
        })
    );
    let panes_and_statuses: Vec<(&str, &str)> = result["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|agent| (agent["pane_id"].as_str().unwrap(), agent["status"].as_str().unwrap()))
        .collect();
    assert_eq!(panes_and_statuses, [("w1:p6", "idle"), ("w1:pA", "working"), ("w1:pB", "working")]);
    assert_eq!(herdr.methods(), ["ping", "session.snapshot"]);
}

#[tokio::test]
async fn unsupported_protocol_version_is_rejected_without_contacting_herdr() {
    let herdr = herdr_with_snapshot().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;

    let error = client.request(json!({"type": "hello", "request_id": "r1", "protocol_version": 99})).await;

    assert_eq!(error["type"], "error");
    assert_eq!(error["request_id"], "r1");
    assert_eq!(error["code"], "protocol_version_unsupported");
    assert_eq!(error["supported_protocol_versions"], json!([1]));
    assert!(herdr.methods().is_empty());
}

#[tokio::test]
async fn handshake_reports_herdr_unavailable_when_herdr_is_not_running() {
    let service = start_service(unique_socket()).await;
    let mut client = TestClient::connect(&service).await;

    let error = client.request(hello("r1")).await;

    assert_eq!(error["type"], "error");
    assert_eq!(error["request_id"], "r1");
    assert_eq!(error["code"], "herdr_unavailable");
}

#[tokio::test]
async fn agents_list_before_handshake_requires_handshake() {
    let herdr = herdr_with_snapshot().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;

    let error = client.request(json!({"type": "agents.list", "request_id": "r1"})).await;

    assert_eq!(error["code"], "handshake_required");
    assert_eq!(error["request_id"], "r1");
    assert!(herdr.methods().is_empty());
}

#[tokio::test]
async fn agents_list_reports_capability_missing_when_herdr_lacks_session_snapshot() {
    // 錄不到沒有 session.snapshot 的伺服器：以錄製的「未知 variant」錯誤為底，把 variant 換成 session.snapshot。
    let mut unknown_method = recorded("error.unknown-subscription-type.ndjson");
    unknown_method["error"]["message"] =
        json!("invalid request: unknown variant `session.snapshot`, expected one of `ping`, `workspace.list` at line 1 column 40");
    let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson")), ("session.snapshot", unknown_method)]).await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let error = client.request(json!({"type": "agents.list", "request_id": "r2"})).await;

    assert_eq!(error["code"], "herdr_capability_missing");
    assert_eq!(error["request_id"], "r2");
}

#[tokio::test]
async fn other_herdr_errors_keep_herdr_error_code() {
    let herdr = FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("session.snapshot", recorded("error.workspace-not-found.ndjson")),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let error = client.request(json!({"type": "agents.list", "request_id": "r2"})).await;

    assert_eq!(error["code"], "herdr_error");
    assert_eq!(error["herdr_code"], "workspace_not_found");
}

#[tokio::test]
async fn agents_list_reports_herdr_unavailable_after_herdr_stops_answering() {
    // ping 成功，之後 herdr 沒有回應 session.snapshot 就關閉連線。
    let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson"))]).await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let error = client.request(json!({"type": "agents.list", "request_id": "r2"})).await;

    assert_eq!(error["code"], "herdr_unavailable");
}

#[tokio::test]
async fn unknown_message_types_are_rejected_and_never_reach_herdr() {
    let herdr = herdr_with_snapshot().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let error = client.request(json!({"type": "exec", "request_id": "r2", "command": "rm -rf ~"})).await;

    assert_eq!(error["code"], "invalid_message");
    assert_eq!(error["request_id"], "r2");
    assert_eq!(herdr.methods(), ["ping"]);
}

#[tokio::test]
async fn malformed_json_is_rejected_without_request_id() {
    let herdr = herdr_with_snapshot().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;

    client.send_text("{not json").await;
    let error = client.receive().await;

    assert_eq!(error["type"], "error");
    assert_eq!(error["code"], "invalid_message");
    assert!(error.get("request_id").is_none());
}

#[tokio::test]
async fn connection_stays_usable_after_an_error() {
    let herdr = herdr_with_snapshot().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(json!({"type": "hello", "request_id": "r1", "protocol_version": 99})).await;

    let welcome = client.request(hello("r2")).await;

    assert_eq!(welcome["type"], "welcome");
}
