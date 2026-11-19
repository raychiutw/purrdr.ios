//! Purrdr 主機服務(ADR-0010)。

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

pub mod audit_log;
mod connection;
pub mod device_store;
pub mod herdr_cli;
pub mod herdr_client;
pub mod herdr_socket;
pub mod host_files;
pub mod host_path_mentions;
mod http;
pub mod install;
pub mod management;
mod pane_terminal;
#[rustfmt::skip] // 由 codegen 產生。
pub mod protocol;
pub mod state_directory;
pub mod transcript;
mod transcript_session;

mod service_main;

use audit_log::AuditLog;
use device_store::DeviceStore;
use herdr_cli::HerdrCli;
use herdr_client::HerdrClient;
use herdr_socket::HerdrSocket;
pub use http::WEBSOCKET_PATH;
pub use service_main::run_service;

/// 主機服務的設定。位址固定是 127.0.0.1,對外由 `tailscale serve` 提供 HTTPS。
#[derive(Debug, Clone)]
pub struct HostServiceConfig {
    /// 0 表示由系統挑一個空的埠(測試用)。
    pub port: u16,
    pub herdr_socket: HerdrSocket,
    /// Pane 終端機執行的 herdr CLI。
    pub herdr_cli: HerdrCli,
    /// 裝置、配對碼與稽核紀錄所在的資料夾。
    pub state_directory: PathBuf,
    pub heartbeat: Heartbeat,
    /// 對話紀錄所在的家目錄與設定目錄。
    pub transcripts: transcript::TranscriptEnvironment,
    /// 主機的暫存目錄(`TMPDIR`／`TEMP`);主機取檔放行 Agent 提到的暫存檔。
    pub temporary_directory: Option<PathBuf>,
}

/// 預設埠(127.0.0.1 上)。
pub const DEFAULT_PORT: u16 = 47_820;

/// WebSocket 心跳：每 `interval` 送一次 ping;`timeout` 內沒收到 app 的任何 frame(含 pong)就斷線。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Heartbeat {
    pub interval: Duration,
    pub timeout: Duration,
}

impl Default for Heartbeat {
    /// app 每 15 秒 ping 一次，所以 45 秒沒消息就算斷了。
    fn default() -> Self {
        Heartbeat {
            interval: Duration::from_secs(15),
            timeout: Duration::from_secs(45),
        }
    }
}

impl HostServiceConfig {
    /// 由命令列參數建立設定:`--port <埠>`、`--session <herdr session>`、`--state-dir <資料夾>`;其他參數一律拒絕。
    pub fn from_arguments(arguments: &[String], platform: herdr_socket::Platform, environment: &herdr_socket::SocketEnvironment) -> Result<Self, String> {
        let mut port = DEFAULT_PORT;
        let mut session = None;
        let mut state_directory = None;
        let mut remaining = arguments.iter();
        while let Some(argument) = remaining.next() {
            let mut value = || remaining.next().ok_or_else(|| format!("{argument} needs a value"));
            match argument.as_str() {
                "--port" => {
                    let text = value()?;
                    port = text.parse().map_err(|_| format!("invalid port: {text}"))?;
                }
                "--session" => session = Some(value()?.clone()),
                "--state-dir" => state_directory = Some(PathBuf::from(value()?)),
                other => return Err(format!("unknown argument: {other}")),
            }
        }
        let herdr_socket =
            HerdrSocket::resolve(platform, session.as_deref(), environment).map_err(|error| format!("cannot resolve herdr socket: {error:?}"))?;
        let state_directory = state_directory
            .or_else(|| state_directory::resolve_state_directory(platform, environment))
            .ok_or("cannot find the home directory; pass --state-dir")?;
        Ok(HostServiceConfig {
            port,
            herdr_socket,
            herdr_cli: HerdrCli::search(session.as_deref()),
            state_directory,
            heartbeat: Heartbeat::default(),
            transcripts: transcript::TranscriptEnvironment::resolve(platform, environment),
            temporary_directory: Some(std::env::temp_dir()),
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
        herdr_cli: config.herdr_cli,
        devices: DeviceStore::new(&config.state_directory),
        audit: AuditLog::new(&config.state_directory),
        heartbeat: config.heartbeat,
        files: host_files::FileAccessEnvironment {
            home: config.transcripts.home.clone(),
            temporary_directory: config.temporary_directory,
            state_directory: config.state_directory.clone(),
        },
        transcripts: config.transcripts,
    });
    let accept_loop = tokio::spawn(async move {
        if let Err(error) = axum::serve(listener, router).await {
            eprintln!("host service stopped: {error}");
        }
    });
    Ok(RunningHostService { local_addr, accept_loop })
}
