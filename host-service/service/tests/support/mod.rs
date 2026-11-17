//! 測試共用：假的 herdr socket 與 WebSocket client。

#![allow(dead_code)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use purrdr_host_service::herdr_socket::{HerdrSocket, Platform};
use purrdr_host_service::{HostServiceConfig, RunningHostService};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
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
        let socket = unique_socket();
        let replies: Arc<HashMap<String, Value>> = Arc::new(replies.into_iter().map(|(method, reply)| (method.to_owned(), reply)).collect());
        let requests = Arc::new(Mutex::new(Vec::new()));
        listen(&socket, replies, requests.clone());
        FakeHerdr { socket, requests }
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

async fn serve_connection<S: AsyncRead + AsyncWrite + Unpin>(stream: S, replies: Arc<HashMap<String, Value>>, requests: Arc<Mutex<Vec<Value>>>) {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    while reader.read_line(&mut line).await.unwrap_or(0) > 0 {
        let request: Value = serde_json::from_str(&line).unwrap();
        line.clear();
        requests.lock().unwrap().push(request.clone());
        let Some(reply) = replies.get(request["method"].as_str().unwrap_or_default()) else {
            return;
        };
        let mut reply = reply.clone();
        reply["id"] = request["id"].clone();
        let mut bytes = serde_json::to_vec(&reply).unwrap();
        bytes.push(b'\n');
        reader.get_mut().write_all(&bytes).await.unwrap();
    }
}

#[cfg(unix)]
fn listen(socket: &HerdrSocket, replies: Arc<HashMap<String, Value>>, requests: Arc<Mutex<Vec<Value>>>) {
    let _ = std::fs::remove_file(socket.native_name());
    let listener = tokio::net::UnixListener::bind(socket.native_name()).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(serve_connection(stream, replies.clone(), requests.clone()));
        }
    });
}

#[cfg(windows)]
fn listen(socket: &HerdrSocket, replies: Arc<HashMap<String, Value>>, requests: Arc<Mutex<Vec<Value>>>) {
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
    pub async fn connect(service: &RunningHostService) -> TestClient {
        let url = format!("ws://{}/v1/ws", service.local_addr());
        let (stream, _) = tokio_tungstenite::connect_async(url).await.expect("連上主機服務");
        TestClient { stream }
    }

    pub async fn send(&mut self, message: Value) {
        self.stream.send(Message::text(message.to_string())).await.unwrap();
    }

    pub async fn send_text(&mut self, text: &str) {
        self.stream.send(Message::text(text.to_owned())).await.unwrap();
    }

    /// 下一個文字訊息(JSON)。
    pub async fn receive(&mut self) -> Value {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(10), self.stream.next())
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

/// 以假 herdr 啟動主機服務(埠 0:由系統挑)。
pub async fn start_service(herdr_socket: HerdrSocket) -> RunningHostService {
    purrdr_host_service::start(HostServiceConfig { port: 0, herdr_socket })
        .await
        .expect("啟動主機服務")
}
