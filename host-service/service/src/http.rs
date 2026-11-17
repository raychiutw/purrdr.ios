//! 主機服務的 HTTP 入口:WSS 升級、連線配對與裝置自行撤銷。

use std::time::SystemTime;

use axum::body::Bytes;
use axum::extract::{State, WebSocketUpgrade};
use axum::http::header::AUTHORIZATION;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::audit_log::{AuditEvent, AuditLog, RevokedBy};
use crate::connection;
use crate::device_store::{Device, DeviceStore, PairingFailure, RevokeFailure, TokenRejection};
use crate::herdr_client::HerdrClient;
use crate::protocol::{ErrorCode, ErrorMessage, PairRequest, PairResponse, ServerMessage};

/// app 連線的 WebSocket 路徑。
pub const WEBSOCKET_PATH: &str = "/v1/ws";

/// 以配對碼換裝置權杖(POST,本文 `PairRequest`)。
pub const PAIR_PATH: &str = "/v1/pair";

/// 裝置撤銷自己的權杖(POST,`Authorization: Bearer`)。
pub const REVOKE_PATH: &str = "/v1/revoke";

const MAX_DEVICE_NAME_LENGTH: usize = 64;

/// 每條連線共用的依賴。
#[derive(Clone)]
pub(crate) struct ServiceContext {
    pub herdr: HerdrClient,
    pub devices: DeviceStore,
    pub audit: AuditLog,
}

impl ServiceContext {
    /// 驗證裝置權杖;被拒絕時記入稽核紀錄。
    pub async fn authenticate(&self, device_token: Option<&str>) -> Result<Device, ErrorCode> {
        let Some(device_token) = device_token else {
            self.audit_rejection(ErrorCode::DeviceTokenInvalid, None);
            return Err(ErrorCode::DeviceTokenInvalid);
        };
        let devices = self.devices.clone();
        let device_token = device_token.to_owned();
        match blocking(move || devices.authenticate(&device_token)).await {
            Ok(device) => Ok(device),
            Err(TokenRejection::Invalid) => {
                self.audit_rejection(ErrorCode::DeviceTokenInvalid, None);
                Err(ErrorCode::DeviceTokenInvalid)
            }
            Err(TokenRejection::Revoked(device)) => {
                self.audit_rejection(ErrorCode::DeviceTokenRevoked, Some(device.device_id));
                Err(ErrorCode::DeviceTokenRevoked)
            }
            Err(TokenRejection::Storage(error)) => {
                eprintln!("cannot read device store: {error}");
                Err(ErrorCode::InternalError)
            }
        }
    }

    fn audit_rejection(&self, code: ErrorCode, device_id: Option<String>) {
        let reason = match code {
            ErrorCode::DeviceTokenRevoked => "device_token_revoked",
            _ => "device_token_invalid",
        };
        self.audit.record(AuditEvent::ConnectionRejected { reason, device_id }, SystemTime::now());
    }
}

/// 在 blocking 執行緒做檔案讀寫。
pub(crate) async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(work).await.expect("blocking 工作沒有 panic")
}

/// `Authorization: Bearer <權杖>`。
fn bearer_token(headers: &HeaderMap) -> Option<String> {
    let value = headers.get(AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    scheme.eq_ignore_ascii_case("bearer").then(|| token.trim().to_owned())
}

pub(crate) fn router(context: ServiceContext) -> Router {
    Router::new()
        .route(WEBSOCKET_PATH, get(websocket))
        .route(PAIR_PATH, post(pair))
        .route(REVOKE_PATH, post(revoke_self))
        .with_state(context)
}

/// 以配對碼換裝置權杖。
async fn pair(State(context): State<ServiceContext>, body: Bytes) -> Response {
    let Ok(request) = serde_json::from_slice::<PairRequest>(&body) else {
        return error_response(StatusCode::BAD_REQUEST, ErrorCode::InvalidMessage, "body must be a pairing request");
    };
    let device_name = sanitized_device_name(&request.device_name);
    let devices = context.devices.clone();
    let redeemed = blocking(move || devices.redeem_pairing_code(&request.pairing_code, &device_name, SystemTime::now())).await;
    match redeemed {
        Ok(issued) => {
            context.audit.record(
                AuditEvent::Paired {
                    device_id: issued.device.device_id.clone(),
                    device_name: issued.device.name.clone(),
                    read_only: issued.device.read_only,
                },
                SystemTime::now(),
            );
            Json(PairResponse {
                device_id: issued.device.device_id,
                device_token: issued.device_token,
                read_only: issued.device.read_only,
            })
            .into_response()
        }
        Err(PairingFailure::Invalid) => {
            context
                .audit
                .record(AuditEvent::PairingFailed { reason: "pairing_code_invalid" }, SystemTime::now());
            error_response(StatusCode::UNAUTHORIZED, ErrorCode::PairingCodeInvalid, "unknown or used pairing code")
        }
        Err(PairingFailure::Expired) => {
            context
                .audit
                .record(AuditEvent::PairingFailed { reason: "pairing_code_expired" }, SystemTime::now());
            error_response(StatusCode::UNAUTHORIZED, ErrorCode::PairingCodeExpired, "pairing code expired")
        }
        Err(PairingFailure::Storage(error)) => {
            eprintln!("cannot update device store: {error}");
            error_response(StatusCode::INTERNAL_SERVER_ERROR, ErrorCode::InternalError, "host service cannot update its device store")
        }
    }
}

/// app 刪除主機時撤銷自己的權杖(唯讀裝置也可以)。
async fn revoke_self(State(context): State<ServiceContext>, headers: HeaderMap) -> Response {
    let device = match context.authenticate(bearer_token(&headers).as_deref()).await {
        Ok(device) => device,
        Err(code) => return token_error_response(code),
    };
    let devices = context.devices.clone();
    let device_id = device.device_id.clone();
    match blocking(move || devices.revoke(&device_id, SystemTime::now())).await {
        Ok(_) => {
            context.audit.record(
                AuditEvent::Revoked {
                    device_id: device.device_id,
                    by: RevokedBy::Device,
                },
                SystemTime::now(),
            );
            StatusCode::NO_CONTENT.into_response()
        }
        Err(RevokeFailure::UnknownDevice) => token_error_response(ErrorCode::DeviceTokenInvalid),
        Err(RevokeFailure::Storage(error)) => {
            eprintln!("cannot update device store: {error}");
            token_error_response(ErrorCode::InternalError)
        }
    }
}

fn token_error_response(code: ErrorCode) -> Response {
    match code {
        ErrorCode::DeviceTokenRevoked => error_response(StatusCode::UNAUTHORIZED, code, "device token was revoked"),
        ErrorCode::DeviceTokenInvalid => error_response(StatusCode::UNAUTHORIZED, code, "missing or unknown device token"),
        _ => error_response(StatusCode::INTERNAL_SERVER_ERROR, code, "host service cannot read its device store"),
    }
}

fn error_response(status: StatusCode, code: ErrorCode, message: &str) -> Response {
    let body = ServerMessage::ErrorMessage(ErrorMessage {
        request_id: None,
        code,
        message: message.to_owned(),
        herdr_code: None,
        supported_protocol_versions: None,
    });
    (status, Json(body)).into_response()
}

/// 裝置名稱會顯示在主機的終端機：去掉控制字元(避免跳脫序列)並限制長度。
fn sanitized_device_name(name: &str) -> String {
    let cleaned: String = name.chars().filter(|character| !character.is_control()).take(MAX_DEVICE_NAME_LENGTH).collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() { "unnamed device".to_owned() } else { trimmed.to_owned() }
}

/// 先完成升級再驗證權杖，被拒絕時才能以 close code 告訴 app 原因。
async fn websocket(State(context): State<ServiceContext>, headers: HeaderMap, upgrade: WebSocketUpgrade) -> Response {
    let device_token = bearer_token(&headers);
    upgrade.on_upgrade(move |socket| connection::serve(socket, context, device_token))
}
