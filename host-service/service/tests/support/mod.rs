//! 測試共用：假的 herdr socket 與 WebSocket client。

#![allow(dead_code)]

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use futures_util::{SinkExt, StreamExt};
use purrdr_host_service::device_store::{DeviceStore, IssuedDevice};
use purrdr_host_service::herdr_cli::HerdrCli;
use purrdr_host_service::herdr_socket::{HerdrSocket, Platform};
use purrdr_host_service::transcript::TranscriptEnvironment;
use purrdr_host_service::{Heartbeat, HostServiceConfig, RunningHostService};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

static NEXT_SOCKET: AtomicU32 = AtomicU32::new(0);

/// `host-service/service` 資料夾;交叉編譯到別台執行時以 `PURRDR_HOST_SERVICE_PACKAGE_DIR` 指定。
pub fn package_directory() -> PathBuf {
    std::env::var_os("PURRDR_HOST_SERVICE_PACKAGE_DIR").map_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")), PathBuf::from)
}

/// 測試檔案的暫存區(不在系統暫存目錄);交叉編譯到別台執行時以 `PURRDR_TEST_TMPDIR` 指定。
pub fn test_files_directory() -> PathBuf {
    std::env::var_os("PURRDR_TEST_TMPDIR").map_or_else(|| PathBuf::from(env!("CARGO_TARGET_TMPDIR")), PathBuf::from)
}

/// 從真實主機錄下的 herdr 回應(`tests/PurrdrTestSupport/Fixtures/herdr-0.9.5/`)。
pub fn recorded(name: &str) -> Value {
    let path = package_directory().join("../../tests/PurrdrTestSupport/Fixtures/herdr-0.9.5").join(name);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(text.lines().next().unwrap()).unwrap()
}

/// 每個測試自己的 socket 路徑(Unix 在暫存資料夾，Windows 是 pipe 名稱)。
pub fn unique_socket() -> HerdrSocket {
    let name = format!("purrdr-host-service-test-{}-{}", std::process::id(), NEXT_SOCKET.fetch_add(1, Ordering::SeqCst));
    if cfg!(windows) {
        HerdrSocket::at_path(Platform::Windows, name)
    } else {
        HerdrSocket::at_path(Platform::Unix, std::env::temp_dir().join(format!("{name}.sock")).to_string_lossy().into_owned())
    }
}

/// 假的 herdr socket:每行請求依 method 回放一行錄製回應(換上請求的 id),並記下收到的請求。
///
/// `events.subscribe` 被接受(回應有 `result`)後連線保持開著，之後用 `push_event` 推事件、`end_subscriptions` 結束。
pub struct FakeHerdr {
    pub socket: HerdrSocket,
    shared: Arc<FakeHerdrState>,
}

struct FakeHerdrState {
    /// method → (回應, 回應前等多久)。
    replies: HashMap<String, (Value, Duration)>,
    requests: Mutex<Vec<Value>>,
    subscriptions: Mutex<Vec<tokio::sync::mpsc::UnboundedSender<Push>>>,
}

/// 推給訂閱連線的東西。
enum Push {
    Line(Value),
    Close,
}

impl FakeHerdr {
    /// 依 method 回應;沒列到的 method 不回應而直接關閉連線。
    pub async fn start(replies: Vec<(&str, Value)>) -> FakeHerdr {
        FakeHerdr::start_delayed(replies.into_iter().map(|(method, reply)| (method, reply, Duration::ZERO)).collect()).await
    }

    /// 同 `start`,但每個 method 等指定的時間才回應(模擬 herdr 等待 agent)。
    pub async fn start_delayed(replies: Vec<(&str, Value, Duration)>) -> FakeHerdr {
        let socket = unique_socket();
        let shared = Arc::new(FakeHerdrState {
            replies: replies.into_iter().map(|(method, reply, delay)| (method.to_owned(), (reply, delay))).collect(),
            requests: Mutex::new(Vec::new()),
            subscriptions: Mutex::new(Vec::new()),
        });
        listen(&socket, shared.clone());
        FakeHerdr { socket, shared }
    }

    /// 收到的請求(整行 JSON),依收到順序。
    pub fn requests(&self) -> Vec<Value> {
        self.shared.requests.lock().unwrap().clone()
    }

    /// 收到的請求的 method,依收到順序。
    pub fn methods(&self) -> Vec<String> {
        self.requests()
            .iter()
            .map(|request| request["method"].as_str().unwrap_or_default().to_owned())
            .collect()
    }

    /// 對每條開著的訂閱推一行(事件或錯誤 envelope)。
    pub fn push_event(&self, line: Value) {
        for subscription in self.shared.subscriptions.lock().unwrap().iter() {
            let _ = subscription.send(Push::Line(line.clone()));
        }
    }

    /// herdr 結束每條訂閱：先送 `last_line`(例如 `events_lost`),再關閉連線。
    pub fn end_subscriptions(&self, last_line: Option<Value>) {
        for subscription in self.shared.subscriptions.lock().unwrap().iter() {
            if let Some(line) = &last_line {
                let _ = subscription.send(Push::Line(line.clone()));
            }
            let _ = subscription.send(Push::Close);
        }
    }

    /// 還開著的訂閱連線數(主機服務關掉的不算)。
    pub fn open_subscriptions(&self) -> usize {
        self.shared
            .subscriptions
            .lock()
            .unwrap()
            .iter()
            .filter(|subscription| !subscription.is_closed())
            .count()
    }

    /// 等到條件成立(最多 10 秒)。
    pub async fn wait_until(&self, condition: impl Fn(&FakeHerdr) -> bool) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !condition(self) {
            assert!(tokio::time::Instant::now() < deadline, "等假 herdr 的狀態逾時");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

async fn serve_connection<S: AsyncRead + AsyncWrite + Unpin>(stream: S, shared: Arc<FakeHerdrState>) {
    let (reading, mut writing) = tokio::io::split(stream);
    let mut reader = BufReader::new(reading);
    let (pushes, mut pushed) = tokio::sync::mpsc::unbounded_channel();
    let mut pushes = Some(pushes);
    let mut line = String::new();
    loop {
        tokio::select! {
            read = reader.read_line(&mut line) => {
                if read.unwrap_or(0) == 0 {
                    return;
                }
                let request: Value = serde_json::from_str(&line).unwrap();
                line.clear();
                shared.requests.lock().unwrap().push(request.clone());
                let method = request["method"].as_str().unwrap_or_default();
                let Some((reply, delay)) = shared.replies.get(method) else {
                    return;
                };
                tokio::time::sleep(*delay).await;
                let mut reply = reply.clone();
                reply["id"] = request["id"].clone();
                write_line(&mut writing, &reply).await;
                if method == "events.subscribe"
                    && reply.get("result").is_some()
                    && let Some(pushes) = pushes.take()
                {
                    shared.subscriptions.lock().unwrap().push(pushes);
                }
            }
            Some(push) = pushed.recv() => match push {
                Push::Line(line) => write_line(&mut writing, &line).await,
                Push::Close => return,
            },
        }
    }
}

async fn write_line<W: AsyncWrite + Unpin>(writing: &mut W, line: &Value) {
    let mut bytes = serde_json::to_vec(line).unwrap();
    bytes.push(b'\n');
    let _ = writing.write_all(&bytes).await;
}

#[cfg(unix)]
fn listen(socket: &HerdrSocket, shared: Arc<FakeHerdrState>) {
    let _ = std::fs::remove_file(socket.native_name());
    let listener = tokio::net::UnixListener::bind(socket.native_name()).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(serve_connection(stream, shared.clone()));
        }
    });
}

#[cfg(windows)]
fn listen(socket: &HerdrSocket, shared: Arc<FakeHerdrState>) {
    use tokio::net::windows::named_pipe::ServerOptions;
    let name = socket.native_name();
    let mut server = ServerOptions::new().first_pipe_instance(true).create(&name).unwrap();
    tokio::spawn(async move {
        loop {
            if server.connect().await.is_err() {
                return;
            }
            let connected = server;
            server = ServerOptions::new().create(&name).unwrap();
            tokio::spawn(serve_connection(connected, shared.clone()));
        }
    });
}

/// 以真正的 WebSocket client 連上主機服務。
pub struct TestClient {
    stream: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl TestClient {
    /// 帶這個主機服務預先配對好的(可寫入)裝置權杖。
    pub async fn connect(service: &TestHostService) -> TestClient {
        TestClient::connect_with_token(service, Some(&service.device_token)).await
    }

    /// `device_token` 為 None 時不帶 Authorization。
    pub async fn connect_with_token(service: &TestHostService, device_token: Option<&str>) -> TestClient {
        let mut request = format!("ws://{}/v1/ws", service.local_addr()).into_client_request().unwrap();
        if let Some(device_token) = device_token {
            request.headers_mut().insert(AUTHORIZATION, format!("Bearer {device_token}").parse().unwrap());
        }
        let (stream, _) = tokio_tungstenite::connect_async(request).await.expect("連上主機服務");
        TestClient { stream }
    }

    /// 等到主機服務關閉連線，回傳 close code 與原因。
    pub async fn closed(&mut self) -> Option<(u16, String)> {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(10), self.stream.next()).await.expect("等關閉逾時");
            match message {
                Some(Ok(Message::Close(frame))) => return frame.map(|frame| (u16::from(frame.code), frame.reason.to_string())),
                Some(Ok(_)) => continue,
                Some(Err(_)) | None => return None,
            }
        }
    }

    pub async fn send(&mut self, message: Value) {
        self.stream.send(Message::text(message.to_string())).await.unwrap();
    }

    /// 送出;主機服務已關閉連線時忽略錯誤。
    pub async fn try_send(&mut self, message: Value) {
        let _ = self.stream.send(Message::text(message.to_string())).await;
    }

    pub async fn send_text(&mut self, text: &str) {
        self.stream.send(Message::text(text.to_owned())).await.unwrap();
    }

    /// 下一個文字訊息(JSON)。
    pub async fn receive(&mut self) -> Value {
        self.receive_within(Duration::from_secs(10)).await
    }

    /// 下一個文字訊息(JSON),最多等 `limit`。
    pub async fn receive_within(&mut self, limit: Duration) -> Value {
        loop {
            let message = tokio::time::timeout(limit, self.stream.next())
                .await
                .expect("等回應逾時")
                .expect("連線關閉")
                .unwrap();
            if let Message::Text(text) = message {
                return serde_json::from_str(&text).unwrap();
            }
        }
    }

    pub async fn request(&mut self, message: Value) -> Value {
        self.send(message).await;
        self.receive().await
    }

    /// 持續讀 `duration`(讀的同時自動回 pong),回傳收到的 frame 與連線是否已結束。
    pub async fn read_for(&mut self, duration: Duration) -> (Vec<Message>, bool) {
        let deadline = tokio::time::Instant::now() + duration;
        let mut frames = Vec::new();
        loop {
            match tokio::time::timeout_at(deadline, self.stream.next()).await {
                Err(_) => return (frames, false),
                Ok(Some(Ok(Message::Close(_)) | Err(_)) | None) => return (frames, true),
                Ok(Some(Ok(frame))) => frames.push(frame),
            }
        }
    }
}

/// 測試用的主機服務：自己的暫存資料夾，並預先配對好一支可寫入的裝置。
pub struct TestHostService {
    pub service: RunningHostService,
    /// 主機服務資料夾(`--state-dir`)。
    pub state_path: PathBuf,
    _state_root: TempDir,
    pub device_token: String,
}

impl TestHostService {
    pub fn local_addr(&self) -> SocketAddr {
        self.service.local_addr()
    }

    pub fn store(&self) -> DeviceStore {
        DeviceStore::new(&self.state_path)
    }

    /// 產生配對碼(與主機上的配對指令相同)。
    pub fn pairing_code(&self, read_only: bool) -> String {
        self.store().create_pairing_code(read_only, SystemTime::now()).unwrap().code
    }

    /// 配對一支新裝置，回傳權杖。
    pub fn pair_device(&self, name: &str, read_only: bool) -> IssuedDevice {
        let code = self.pairing_code(read_only);
        self.store().redeem_pairing_code(&code, name, SystemTime::now()).unwrap()
    }

    /// 稽核紀錄的全部內容。
    pub fn audit_log(&self) -> String {
        std::fs::read_to_string(self.state_path.join("audit.log")).unwrap_or_default()
    }

    /// 主機服務資料夾裡所有檔案的內容(檢查有沒有存明文)。
    pub fn stored_files(&self) -> String {
        std::fs::read_dir(&self.state_path)
            .unwrap()
            .map(|entry| std::fs::read_to_string(entry.unwrap().path()).unwrap_or_default())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// 以假 herdr 啟動主機服務(埠 0:由系統挑)。對話紀錄的家目錄不存在(讀不到任何對話紀錄)。
pub async fn start_service(herdr_socket: HerdrSocket) -> TestHostService {
    start_service_with(herdr_socket, HerdrCli::search(None), Heartbeat::default(), TranscriptEnvironment::default()).await
}

/// 指定心跳間隔與逾時(測試心跳用很短的時間)。
pub async fn start_service_with_heartbeat(herdr_socket: HerdrSocket, heartbeat: Heartbeat) -> TestHostService {
    start_service_with(herdr_socket, HerdrCli::search(None), heartbeat, TranscriptEnvironment::default()).await
}

/// 以假 herdr 與指定的對話紀錄位置啟動主機服務。
pub async fn start_service_with_transcripts(herdr_socket: HerdrSocket, transcripts: TranscriptEnvironment) -> TestHostService {
    start_service_with(herdr_socket, HerdrCli::search(None), Heartbeat::default(), transcripts).await
}

/// 同 `start_service`,Pane 終端機執行 `herdr_cli`(假的 herdr CLI)。
pub async fn start_service_with_herdr_cli(herdr_socket: HerdrSocket, herdr_cli: HerdrCli) -> TestHostService {
    start_service_with(herdr_socket, herdr_cli, Heartbeat::default(), TranscriptEnvironment::default()).await
}

/// 主機取檔的測試：對話紀錄位置、主機的暫存目錄(`TMPDIR`／`TEMP`)與主機服務資料夾都可指定。
pub struct FileServiceOptions {
    pub transcripts: TranscriptEnvironment,
    pub temporary_directory: Option<PathBuf>,
    /// 沒指定時用暫存資料夾。
    pub state_directory: Option<PathBuf>,
}

pub async fn start_file_service(herdr_socket: HerdrSocket, options: FileServiceOptions) -> TestHostService {
    start_service_with_options(
        herdr_socket,
        HerdrCli::search(None),
        Heartbeat::default(),
        options.transcripts,
        options.temporary_directory,
        options.state_directory,
    )
    .await
}

async fn start_service_with(herdr_socket: HerdrSocket, herdr_cli: HerdrCli, heartbeat: Heartbeat, transcripts: TranscriptEnvironment) -> TestHostService {
    start_service_with_options(herdr_socket, herdr_cli, heartbeat, transcripts, None, None).await
}

async fn start_service_with_options(
    herdr_socket: HerdrSocket,
    herdr_cli: HerdrCli,
    heartbeat: Heartbeat,
    transcripts: TranscriptEnvironment,
    temporary_directory: Option<PathBuf>,
    state_directory: Option<PathBuf>,
) -> TestHostService {
    let state_root = tempfile::tempdir().unwrap();
    let state_path = state_directory.unwrap_or_else(|| state_root.path().to_owned());
    let service = purrdr_host_service::start(HostServiceConfig {
        port: 0,
        herdr_socket,
        herdr_cli,
        state_directory: state_path.clone(),
        heartbeat,
        transcripts,
        temporary_directory,
    })
    .await
    .expect("啟動主機服務");
    let code = DeviceStore::new(&state_path).create_pairing_code(false, SystemTime::now()).unwrap().code;
    let device_token = DeviceStore::new(&state_path)
        .redeem_pairing_code(&code, "測試裝置", SystemTime::now())
        .unwrap()
        .device_token;
    TestHostService {
        service,
        state_path,
        _state_root: state_root,
        device_token,
    }
}

/// 對主機服務送一個 HTTP/1.1 請求，回傳狀態碼與本文(JSON;沒有本文是 Null)。
pub async fn http_request(service: &TestHostService, method: &str, path: &str, device_token: Option<&str>, body: Option<Value>) -> (u16, Value) {
    let mut stream = TcpStream::connect(service.local_addr()).await.unwrap();
    let body = body.map(|body| body.to_string()).unwrap_or_default();
    let authorization = device_token.map(|token| format!("Authorization: Bearer {token}\r\n")).unwrap_or_default();
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\n{authorization}Content-Length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), stream.read_to_end(&mut response))
        .await
        .expect("等 HTTP 回應逾時")
        .unwrap();
    let response = String::from_utf8(response).unwrap();
    let (head, body) = response.split_once("\r\n\r\n").expect("HTTP 回應有標頭");
    let status = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    let body = if body.trim().is_empty() {
        Value::Null
    } else {
        serde_json::from_str(body).unwrap_or(Value::String(body.to_owned()))
    };
    (status, body)
}
