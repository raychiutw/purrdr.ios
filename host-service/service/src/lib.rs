//! Purrdr 主機服務(ADR-0010)。

use std::net::SocketAddr;
use std::path::PathBuf;

pub mod audit_log;
mod connection;
pub mod device_store;
pub mod herdr_client;
pub mod herdr_socket;
mod http;
#[rustfmt::skip] // 由 codegen 產生。
pub mod protocol;
pub mod state_directory;

use audit_log::AuditLog;
use device_store::DeviceStore;
use herdr_client::HerdrClient;
use herdr_socket::HerdrSocket;
pub use http::WEBSOCKET_PATH;

/// 主機服務的設定。位址固定是 127.0.0.1,對外由 `tailscale serve` 提供 HTTPS。
#[derive(Debug, Clone)]
pub struct HostServiceConfig {
    /// 0 表示由系統挑一個空的埠(測試用)。
    pub port: u16,
    pub herdr_socket: HerdrSocket,
    /// 裝置、配對碼與稽核紀錄所在的資料夾。
    pub state_directory: PathBuf,
}

/// 預設埠(127.0.0.1 上)。
pub const DEFAULT_PORT: u16 = 47_820;

impl HostServiceConfig {
    /// 由命令列參數建立設定:`--port <埠>`、`--session <herdr session>`;其他參數一律拒絕。
    pub fn from_arguments(arguments: &[String], platform: herdr_socket::Platform, environment: &herdr_socket::SocketEnvironment) -> Result<Self, String> {
        let mut port = DEFAULT_PORT;
        let mut session = None;
        let mut remaining = arguments.iter();
        while let Some(argument) = remaining.next() {
            let mut value = || remaining.next().ok_or_else(|| format!("{argument} needs a value"));
            match argument.as_str() {
                "--port" => {
                    let text = value()?;
                    port = text.parse().map_err(|_| format!("invalid port: {text}"))?;
                }
                "--session" => session = Some(value()?.clone()),
                other => return Err(format!("unknown argument: {other}")),
            }
        }
        let herdr_socket =
            HerdrSocket::resolve(platform, session.as_deref(), environment).map_err(|error| format!("cannot resolve herdr socket: {error:?}"))?;
        Ok(HostServiceConfig {
            port,
            herdr_socket,
            state_directory: PathBuf::new(),
        })
    }
}

/// 執行中的主機服務;drop 時停止接受新連線。
pub struct RunningHostService {
    local_addr: SocketAddr,
    accept_loop: tokio::task::JoinHandle<()>,
}

impl RunningHostService {
    /// 實際綁定的位址。
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// 一直執行到接受連線的迴圈結束(正式執行用)。
    pub async fn wait(mut self) {
        let _ = (&mut self.accept_loop).await;
    }
}

impl Drop for RunningHostService {
    fn drop(&mut self) {
        self.accept_loop.abort();
    }
}

/// 綁定 127.0.0.1 並開始接受連線。
pub async fn start(config: HostServiceConfig) -> std::io::Result<RunningHostService> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", config.port)).await?;
    let local_addr = listener.local_addr()?;
    let router = http::router(http::ServiceContext {
        herdr: HerdrClient::new(config.herdr_socket),
        devices: DeviceStore::new(&config.state_directory),
        audit: AuditLog::new(&config.state_directory),
    });
    let accept_loop = tokio::spawn(async move {
        if let Err(error) = axum::serve(listener, router).await {
            eprintln!("host service stopped: {error}");
        }
    });
    Ok(RunningHostService { local_addr, accept_loop })
}
