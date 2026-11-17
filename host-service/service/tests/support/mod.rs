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
use purrdr_host_service::herdr_socket::{HerdrSocket, Platform};
use purrdr_host_service::transcript::TranscriptEnvironment;
use purrdr_host_service::{HostServiceConfig, RunningHostService};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

static NEXT_SOCKET: AtomicU32 = AtomicU32::new(0);

/// 從真實主機錄下的 herdr 回應(`tests/PurrdrTestSupport/Fixtures/herdr-0.9.5/`)。
pub fn recorded(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/PurrdrTestSupport/Fixtures/herdr-0.9.5")
        .join(name);
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
pub struct FakeHerdr {
    pub socket: HerdrSocket,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeHerdr {
    /// 依 method 回應;沒列到的 method 不回應而直接關閉連線。
    pub async fn start(replies: Vec<(&str, Value)>) -> FakeHerdr {
        FakeHerdr::start_delayed(replies.into_iter().map(|(method, reply)| (method, reply, Duration::ZERO)).collect()).await
    }

    /// 同 `start`,但每個 method 等指定的時間才回應(模擬 herdr 等待 agent)。
    pub async fn start_delayed(replies: Vec<(&str, Value, Duration)>) -> FakeHerdr {
        let socket = unique_socket();
        let replies: Arc<HashMap<String, (Value, Duration)>> =
            Arc::new(replies.into_iter().map(|(method, reply, delay)| (method.to_owned(), (reply, delay))).collect());
        let requests = Arc::new(Mutex::new(Vec::new()));
        listen(&socket, replies, requests.clone());
        FakeHerdr { socket, requests }
    }

    /// 收到的請求(整行 JSON),依收到順序。
    pub fn requests(&self) -> Vec<Value> {
        self.requests.lock().unwrap().clone()
    }

    /// 收到的請求的 method,依收到順序。
    pub fn methods(&self) -> Vec<String> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(|request| request["method"].as_str().unwrap_or_default().to_owned())
            .collect()
    }
}

async fn serve_connection<S: AsyncRead + AsyncWrite + Unpin>(stream: S, replies: Arc<HashMap<String, (Value, Duration)>>, requests: Arc<Mutex<Vec<Value>>>) {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    while reader.read_line(&mut line).await.unwrap_or(0) > 0 {
        let request: Value = serde_json::from_str(&line).unwrap();
        line.clear();
        requests.lock().unwrap().push(request.clone());
        let Some((reply, delay)) = replies.get(request["method"].as_str().unwrap_or_default()) else {
            return;
        };
        tokio::time::sleep(*delay).await;
        let mut reply = reply.clone();
        reply["id"] = request["id"].clone();
        let mut bytes = serde_json::to_vec(&reply).unwrap();
        bytes.push(b'\n');
        reader.get_mut().write_all(&bytes).await.unwrap();
    }
}

#[cfg(unix)]
fn listen(socket: &HerdrSocket, replies: Arc<HashMap<String, (Value, Duration)>>, requests: Arc<Mutex<Vec<Value>>>) {
    let _ = std::fs::remove_file(socket.native_name());
    let listener = tokio::net::UnixListener::bind(socket.native_name()).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(serve_connection(stream, replies.clone(), requests.clone()));
        }
    });
}

#[cfg(windows)]
fn listen(socket: &HerdrSocket, replies: Arc<HashMap<String, (Value, Duration)>>, requests: Arc<Mutex<Vec<Value>>>) {
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
            tokio::spawn(serve_connection(connected, replies.clone(), requests.clone()));
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
}

/// 測試用的主機服務：自己的暫存資料夾，並預先配對好一支可寫入的裝置。
pub struct TestHostService {
    pub service: RunningHostService,
    pub state_directory: TempDir,
    pub device_token: String,
}

impl TestHostService {
    pub fn local_addr(&self) -> SocketAddr {
        self.service.local_addr()
    }

    pub fn store(&self) -> DeviceStore {
        DeviceStore::new(self.state_directory.path())
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
        std::fs::read_to_string(self.state_directory.path().join("audit.log")).unwrap_or_default()
    }

    /// 主機服務資料夾裡所有檔案的內容(檢查有沒有存明文)。
    pub fn stored_files(&self) -> String {
        std::fs::read_dir(self.state_directory.path())
            .unwrap()
            .map(|entry| std::fs::read_to_string(entry.unwrap().path()).unwrap_or_default())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// 以假 herdr 啟動主機服務(埠 0:由系統挑)。對話紀錄的家目錄不存在(讀不到任何對話紀錄)。
pub async fn start_service(herdr_socket: HerdrSocket) -> TestHostService {
    start_service_with_transcripts(herdr_socket, TranscriptEnvironment::default()).await
}

/// 以假 herdr 與指定的對話紀錄位置啟動主機服務。
pub async fn start_service_with_transcripts(herdr_socket: HerdrSocket, transcripts: TranscriptEnvironment) -> TestHostService {
    let state_directory = tempfile::tempdir().unwrap();
    let service = purrdr_host_service::start(HostServiceConfig {
        port: 0,
        herdr_socket,
        state_directory: state_directory.path().to_owned(),
        transcripts,
    })
    .await
    .expect("啟動主機服務");
    let code = DeviceStore::new(state_directory.path())
        .create_pairing_code(false, SystemTime::now())
        .unwrap()
        .code;
    let device_token = DeviceStore::new(state_directory.path())
        .redeem_pairing_code(&code, "測試裝置", SystemTime::now())
        .unwrap()
        .device_token;
    TestHostService {
        service,
        state_directory,
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
