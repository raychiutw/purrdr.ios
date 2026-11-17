//! Agent 事件串流(#58):主機服務以 herdr `events.subscribe` 推送變化，不輪詢 snapshot。

mod support;

use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, recorded, start_service};

fn hello(request_id: &str) -> Value {
    json!({"type": "hello", "request_id": request_id, "protocol_version": 1})
}

fn subscribe(request_id: &str, stream_id: &str) -> Value {
    json!({
        "type": "events.subscribe",
        "request_id": request_id,
        "stream_id": stream_id,
        "subscriptions": [{"event": "pane.agent_status_changed", "pane_id": "w1:p6"}, {"event": "workspace.created"}]
    })
}

async fn herdr_accepting_subscriptions() -> FakeHerdr {
    FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("session.snapshot", recorded("session.snapshot.ndjson")),
        ("events.subscribe", recorded("events.subscribe.started.ndjson")),
    ])
    .await
}

fn status_changed(pane_id: &str) -> Value {
    json!({"event": "pane_agent_status_changed", "data": {"pane_id": pane_id, "agent_status": "blocked"}})
}

#[tokio::test]
async fn herdr_events_are_pushed_to_the_app_without_polling_snapshot() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let started = client.request(subscribe("r2", "s1")).await;
    herdr.push_event(status_changed("w1:p6"));
    let event = client.receive().await;

    assert_eq!(started, json!({"type": "events.subscribe.result", "request_id": "r2", "stream_id": "s1"}));
    assert_eq!(
        event,
        json!({"type": "events.event", "stream_id": "s1", "event": "pane_agent_status_changed", "pane_id": "w1:p6"})
    );
    let subscribe_request = herdr.requests().into_iter().find(|request| request["method"] == "events.subscribe").unwrap();
    assert_eq!(
        subscribe_request["params"],
        json!({"subscriptions": [{"type": "pane.agent_status_changed", "pane_id": "w1:p6"}, {"type": "workspace.created"}]})
    );
    assert_eq!(herdr.methods(), ["ping", "events.subscribe"], "主機服務不自己讀 snapshot");
}

#[tokio::test]
async fn pane_id_nested_in_the_pane_object_is_forwarded_and_workspace_events_have_none() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;
    client.request(subscribe("r2", "s1")).await;

    herdr.push_event(json!({"event": "pane_agent_detected", "data": {"pane": {"pane_id": "w2:p1", "agent": "codex"}}}));
    herdr.push_event(json!({"event": "workspace_closed", "data": {"workspace_id": "w2"}}));

    assert_eq!(client.receive().await["pane_id"], "w2:p1");
    assert_eq!(
        client.receive().await,
        json!({"type": "events.event", "stream_id": "s1", "event": "workspace_closed"})
    );
}

#[tokio::test]
async fn herdr_losing_events_ends_the_stream_with_events_lost_so_the_app_reconciles() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;
    client.request(subscribe("r2", "s1")).await;

    herdr.end_subscriptions(Some(
        json!({"id": "purrdr-host:1", "error": {"code": "events_lost", "message": "event history overflowed"}}),
    ));
    let ended = client.receive().await;

    assert_eq!(
        ended,
        json!({
            "type": "events.ended",
            "stream_id": "s1",
            "code": "herdr_error",
            "message": "event history overflowed",
            "herdr_code": "events_lost"
        })
    );
}

#[tokio::test]
async fn herdr_closing_the_subscription_ends_the_stream_without_error() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;
    client.request(subscribe("r2", "s1")).await;

    herdr.end_subscriptions(None);

    assert_eq!(client.receive().await, json!({"type": "events.ended", "stream_id": "s1"}));
}

#[tokio::test]
async fn unsubscribing_closes_only_that_herdr_subscription() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;
    client.request(subscribe("r2", "s1")).await;
    client.request(subscribe("r3", "s2")).await;

    let closed = client
        .request(json!({"type": "events.unsubscribe", "request_id": "r4", "stream_id": "s1"}))
        .await;
    herdr.wait_until(|herdr| herdr.open_subscriptions() == 1).await;
    herdr.push_event(status_changed("w1:p6"));

    assert_eq!(closed, json!({"type": "events.unsubscribe.result", "request_id": "r4"}));
    assert_eq!(client.receive().await["stream_id"], "s2", "另一條串流照常推送");
}

#[tokio::test]
async fn herdr_without_events_subscribe_reports_capability_missing_and_the_rest_keeps_working() {
    let herdr = FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("session.snapshot", recorded("session.snapshot.ndjson")),
        (
            "events.subscribe",
            json!({"id": "x", "error": {"code": "invalid_request", "message": "invalid request: unknown variant `events.subscribe`, expected one of `ping`"}}),
        ),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let refused = client.request(subscribe("r2", "s1")).await;
    let agents = client.request(json!({"type": "agents.list", "request_id": "r3"})).await;

    assert_eq!(refused["request_id"], "r2");
    assert_eq!(refused["code"], "herdr_capability_missing");
    assert_eq!(agents["type"], "agents.list.result");
}

#[tokio::test]
async fn herdr_refusing_the_subscription_keeps_its_error_code() {
    let herdr = FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("events.subscribe", recorded("error.pane-not-found.ndjson")),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;

    let refused = client.request(subscribe("r2", "s1")).await;

    assert_eq!(refused["code"], "herdr_error");
    assert_eq!(refused["herdr_code"], "pane_not_found");
}

#[tokio::test]
async fn reusing_a_stream_id_on_the_same_connection_is_rejected() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;
    client.request(subscribe("r2", "s1")).await;

    let refused = client.request(subscribe("r3", "s1")).await;

    assert_eq!(refused["request_id"], "r3");
    assert_eq!(refused["code"], "invalid_message");
    assert_eq!(herdr.open_subscriptions(), 1, "被拒的請求不開 herdr 訂閱");
}

#[tokio::test]
async fn subscribing_before_hello_requires_handshake() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;

    let refused = client.request(subscribe("r1", "s1")).await;

    assert_eq!(refused["code"], "handshake_required");
    assert!(herdr.methods().is_empty());
}

#[tokio::test]
async fn app_disconnecting_closes_its_herdr_subscriptions() {
    let herdr = herdr_accepting_subscriptions().await;
    let service = start_service(herdr.socket.clone()).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello("r1")).await;
    client.request(subscribe("r2", "s1")).await;
    assert_eq!(herdr.open_subscriptions(), 1);

    drop(client);

    herdr.wait_until(|herdr| herdr.open_subscriptions() == 0).await;
}
