//! 主機服務的 HTTP 入口:WSS 升級、連線配對與裝置自行撤銷。

use std::time::SystemTime;

use axum::Router;
use axum::extract::{State, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::http::header::AUTHORIZATION;
use axum::response::Response;
use axum::routing::get;

use crate::audit_log::{AuditEvent, AuditLog};
use crate::connection;
use crate::device_store::{Device, DeviceStore, TokenRejection};
use crate::herdr_client::HerdrClient;
use crate::protocol::ErrorCode;

/// app 連線的 WebSocket 路徑。
pub const WEBSOCKET_PATH: &str = "/v1/ws";

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
    Router::new().route(WEBSOCKET_PATH, get(websocket)).with_state(context)
}

/// 先完成升級再驗證權杖，被拒絕時才能以 close code 告訴 app 原因。
async fn websocket(State(context): State<ServiceContext>, headers: HeaderMap, upgrade: WebSocketUpgrade) -> Response {
    let device_token = bearer_token(&headers);
    upgrade.on_upgrade(move |socket| connection::serve(socket, context, device_token))
}
