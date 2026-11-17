//! 稽核紀錄(spec #52、#56):記下配對、連線、撤銷與寫入類操作，不含按鍵、prompt、權杖與配對碼。

mod support;

use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, http_request, recorded, start_service};

const SECRET_KEYS: &str = "秘密按鍵內容";

fn events(audit_log: &str) -> Vec<Value> {
    audit_log.lines().map(|line| serde_json::from_str(line).expect("每行都是 JSON")).collect()
}

#[tokio::test]
async fn audit_log_records_pairing_connection_writes_and_revocation_without_content() {
    let herdr = FakeHerdr::start(vec![
        ("ping", recorded("ping.ndjson")),
        ("pane.send_keys", json!({"id": "", "result": {"type": "ok"}})),
    ])
    .await;
    let service = start_service(herdr.socket.clone()).await;
    let code = service.pairing_code(false);
    let (_, paired) = http_request(
        &service,
        "POST",
        "/v1/pair",
        None,
        Some(json!({"pairing_code": code, "device_name": "Ray 的 iPhone"})),
    )
    .await;
    let device_id = paired["device_id"].as_str().unwrap().to_owned();
    let device_token = paired["device_token"].as_str().unwrap().to_owned();
    let read_only = service.pair_device("借出的 iPad", true);

    let mut client = TestClient::connect_with_token(&service, Some(&device_token)).await;
    client.request(json!({"type": "hello", "request_id": "r1", "protocol_version": 1})).await;
    client
        .request(json!({"type": "pane.send_keys", "request_id": "r2", "pane_id": "w1:p6", "keys": [SECRET_KEYS]}))
        .await;
    let mut read_only_client = TestClient::connect_with_token(&service, Some(&read_only.device_token)).await;
    read_only_client
        .request(json!({"type": "pane.send_keys", "request_id": "r3", "pane_id": "w1:p6", "keys": [SECRET_KEYS]}))
        .await;
    http_request(&service, "POST", "/v1/revoke", Some(&device_token), None).await;
    let mut revoked_client = TestClient::connect_with_token(&service, Some(&device_token)).await;
    revoked_client.receive().await;

    let audit_log = service.audit_log();
    let events = events(&audit_log);
    let of_device = |id: &str| -> Vec<Value> {
        events
            .iter()
            .filter(|event| event["device_id"] == id)
            .map(|event| {
                let mut summary = event.clone();
                summary.as_object_mut().unwrap().remove("time");
                summary
            })
            .collect()
    };
    assert_eq!(
        of_device(&device_id),
        [
            json!({"event": "paired", "device_id": device_id, "device_name": "Ray 的 iPhone", "read_only": false}),
            json!({"event": "connected", "device_id": device_id}),
            json!({"event": "write", "device_id": device_id, "operation": "pane.send_keys", "pane_id": "w1:p6", "allowed": true}),
            json!({"event": "revoked", "device_id": device_id, "by": "device"}),
            json!({"event": "connection_rejected", "device_id": device_id, "reason": "device_token_revoked"}),
        ]
    );
    assert!(
        of_device(&read_only.device.device_id)
            .contains(&json!({"event": "write", "device_id": read_only.device.device_id, "operation": "pane.send_keys", "pane_id": "w1:p6", "allowed": false}))
    );
    assert!(events.iter().all(|event| event["time"].as_str().is_some_and(|time| time.ends_with('Z'))));
    for secret in [SECRET_KEYS, &device_token, &read_only.device_token, &code, &code.replace('-', "")] {
        assert!(!audit_log.contains(secret), "稽核紀錄含有 {secret}");
    }
}
