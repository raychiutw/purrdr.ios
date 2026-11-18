//! 心跳(#58):主機服務定期送 WebSocket ping;app 一段時間沒有任何回應(含 pong)就斷線，app 重連後對帳。

mod support;

use std::time::Duration;

use purrdr_host_service::Heartbeat;
use serde_json::json;
use support::{FakeHerdr, TestClient, recorded, start_service_with_heartbeat};
use tokio_tungstenite::tungstenite::Message;

const SHORT: Heartbeat = Heartbeat {
    interval: Duration::from_millis(50),
    timeout: Duration::from_millis(300),
};

async fn herdr() -> FakeHerdr {
    FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("session.snapshot", recorded("session.snapshot.ndjson")),
    ])
    .await
}

#[tokio::test]
async fn host_service_pings_the_app_and_a_responsive_app_stays_connected() {
    let herdr = herdr().await;
    let service = start_service_with_heartbeat(herdr.socket.clone(), SHORT).await;
    let mut client = TestClient::connect(&service).await;

    let (frames, ended) = client.read_for(Duration::from_millis(900)).await;
    let agents = client.request(json!({"type": "hello", "request_id": "r1", "protocol_version": 1})).await;

    assert!(!ended, "有回 pong 的 app 不會被斷線");
    assert!(frames.iter().filter(|frame| matches!(frame, Message::Ping(_))).count() >= 3, "{frames:?}");
    assert_eq!(agents["type"], "welcome");
}

#[tokio::test]
async fn an_app_that_stops_answering_is_disconnected_after_the_timeout() {
    let herdr = herdr().await;
    let service = start_service_with_heartbeat(herdr.socket.clone(), SHORT).await;
    let mut client = TestClient::connect(&service).await;

    // 不讀就不會回 pong(網路斷了、app 被凍結)。
    tokio::time::sleep(Duration::from_millis(900)).await;
    let (_, ended) = client.read_for(Duration::from_secs(2)).await;

    assert!(ended, "逾時沒有回應的連線被主機服務關閉");
}
