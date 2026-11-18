//! 連線配對(spec #52、#56):app 以主機產生的一次性配對碼(POST /v1/pair)換得裝置權杖;
//! app 刪除主機時以 POST /v1/revoke 撤銷自己的權杖。

mod support;

use std::time::{Duration, SystemTime};

use purrdr_host_service::device_store::MAX_FAILED_PAIRING_ATTEMPTS;
use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, TestHostService, http_request, recorded, start_service};

async fn service() -> (FakeHerdr, TestHostService) {
    let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson"))]).await;
    let service = start_service(herdr.socket.clone()).await;
    (herdr, service)
}

async fn pair(service: &TestHostService, pairing_code: &str) -> (u16, Value) {
    http_request(
        service,
        "POST",
        "/v1/pair",
        None,
        Some(json!({"pairing_code": pairing_code, "device_name": "Ray 的 iPhone"})),
    )
    .await
}

async fn handshake(service: &TestHostService, device_token: &str) -> Value {
    let mut client = TestClient::connect_with_token(service, Some(device_token)).await;
    client.request(json!({"type": "hello", "request_id": "r1", "protocol_version": 1})).await
}

#[tokio::test]
async fn pairing_code_is_exchanged_for_a_device_token_that_opens_websocket() {
    let (_herdr, service) = service().await;
    let code = service.pairing_code(false);

    let (status, body) = pair(&service, &code).await;

    assert_eq!(status, 200, "{body}");
    assert_eq!(body["read_only"], false);
    let device_token = body["device_token"].as_str().unwrap();
    assert!(device_token.starts_with("purrdr_dt_"));
    assert_eq!(handshake(&service, device_token).await["type"], "welcome");
    let devices = service.store().devices().unwrap();
    let paired = devices.iter().find(|device| device.device_id == body["device_id"]).unwrap();
    assert_eq!(paired.name, "Ray 的 iPhone");
}

#[tokio::test]
async fn manually_typed_pairing_code_ignores_case_and_hyphen() {
    let (_herdr, service) = service().await;
    let typed = service.pairing_code(false).replace('-', "").to_lowercase();

    let (status, _) = pair(&service, &typed).await;

    assert_eq!(status, 200);
}

#[tokio::test]
async fn pairing_code_cannot_be_used_twice() {
    let (_herdr, service) = service().await;
    let code = service.pairing_code(false);
    pair(&service, &code).await;

    let (status, body) = pair(&service, &code).await;

    assert_eq!(status, 401);
    assert_eq!(body["type"], "error");
    assert_eq!(body["code"], "pairing_code_invalid");
}

#[tokio::test]
async fn expired_pairing_code_is_rejected() {
    let (_herdr, service) = service().await;
    let issued_long_ago = SystemTime::now() - Duration::from_secs(10 * 60);
    let code = service.store().create_pairing_code(false, issued_long_ago).unwrap().code;

    let (status, body) = pair(&service, &code).await;

    assert_eq!(status, 401);
    assert_eq!(body["code"], "pairing_code_expired");
}

#[tokio::test]
async fn unknown_pairing_code_is_rejected() {
    let (_herdr, service) = service().await;
    service.pairing_code(false);

    let (status, body) = pair(&service, "ZZZZ-ZZZZ").await;

    assert_eq!(status, 401);
    assert_eq!(body["code"], "pairing_code_invalid");
}

#[tokio::test]
async fn repeated_wrong_guesses_void_pending_pairing_codes() {
    let (_herdr, service) = service().await;
    let code = service.pairing_code(false);
    for _ in 0..MAX_FAILED_PAIRING_ATTEMPTS {
        pair(&service, "ZZZZ-ZZZZ").await;
    }

    let (status, body) = pair(&service, &code).await;

    assert_eq!(status, 401);
    assert_eq!(body["code"], "pairing_code_invalid");
}

#[tokio::test]
async fn device_name_cannot_inject_terminal_escape_sequences() {
    let (_herdr, service) = service().await;
    let code = service.pairing_code(false);

    let (status, body) = http_request(
        &service,
        "POST",
        "/v1/pair",
        None,
        Some(json!({"pairing_code": code, "device_name": "\u{1b}[2J惡意\n裝置"})),
    )
    .await;

    assert_eq!(status, 200);
    let devices = service.store().devices().unwrap();
    let paired = devices.iter().find(|device| device.device_id == body["device_id"]).unwrap();
    assert_eq!(paired.name, "[2J惡意裝置");
}

#[tokio::test]
async fn read_only_pairing_code_issues_read_only_device() {
    let (_herdr, service) = service().await;
    let code = service.pairing_code(true);

    let (status, body) = pair(&service, &code).await;

    assert_eq!(status, 200);
    assert_eq!(body["read_only"], true);
}

#[tokio::test]
async fn malformed_pairing_request_is_rejected() {
    let (_herdr, service) = service().await;

    let (status, body) = http_request(&service, "POST", "/v1/pair", None, Some(json!({"code": "ABCD-EFGH"}))).await;

    assert_eq!(status, 400);
    assert_eq!(body["code"], "invalid_message");
}

#[tokio::test]
async fn device_can_revoke_its_own_token() {
    let (_herdr, service) = service().await;
    let issued = service.pair_device("Ray 的 iPhone", false);

    let (status, _) = http_request(&service, "POST", "/v1/revoke", Some(&issued.device_token), None).await;

    assert_eq!(status, 204);
    assert_eq!(handshake(&service, &issued.device_token).await["code"], "device_token_revoked");
    let devices = service.store().devices().unwrap();
    assert!(
        devices
            .iter()
            .any(|device| device.device_id == issued.device.device_id && device.revoked_at.is_some())
    );
}

#[tokio::test]
async fn read_only_device_can_also_revoke_its_own_token() {
    let (_herdr, service) = service().await;
    let issued = service.pair_device("借出的 iPad", true);

    let (status, _) = http_request(&service, "POST", "/v1/revoke", Some(&issued.device_token), None).await;

    assert_eq!(status, 204);
}

#[tokio::test]
async fn revoking_with_unknown_or_revoked_token_is_rejected() {
    let (_herdr, service) = service().await;
    let issued = service.pair_device("Ray 的 iPhone", false);
    http_request(&service, "POST", "/v1/revoke", Some(&issued.device_token), None).await;

    let (unknown_status, unknown) = http_request(&service, "POST", "/v1/revoke", Some("purrdr_dt_forged"), None).await;
    let (revoked_status, revoked) = http_request(&service, "POST", "/v1/revoke", Some(&issued.device_token), None).await;
    let (missing_status, missing) = http_request(&service, "POST", "/v1/revoke", None, None).await;

    assert_eq!((unknown_status, unknown["code"].as_str()), (401, Some("device_token_invalid")));
    assert_eq!((revoked_status, revoked["code"].as_str()), (401, Some("device_token_revoked")));
    assert_eq!((missing_status, missing["code"].as_str()), (401, Some("device_token_invalid")));
}
