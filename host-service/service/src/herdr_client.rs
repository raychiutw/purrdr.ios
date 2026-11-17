//! herdr 本機 socket 的 NDJSON client(herdr 官方文件 socket-api「Socket transport」)。
//!
//! 每個請求開一條新連線，寫一行請求、讀第一行回應後關閉;事件訂閱的連線保持開著。

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

use crate::herdr_socket::HerdrSocket;

/// 連線、送出到收到回應的上限。
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// herdr 請求失敗的原因。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HerdrFailure {
    /// 連不到 socket、沒回應就斷線或逾時(herdr 沒在跑)。
    Unavailable(String),
    /// herdr 的錯誤 envelope。
    Herdr { code: String, message: String },
    /// 回應不是預期的格式。
    UnexpectedResponse(String),
}

impl HerdrFailure {
    /// herdr 不認得這個 method:serde 解碼請求時回 `invalid_request` 的 unknown variant(錄製於 0.9.5)。
    pub fn is_unknown_method(&self, method: &str) -> bool {
        match self {
            HerdrFailure::Herdr { code, message } => code == "invalid_request" && message.contains(&format!("unknown variant `{method}`")),
            _ => false,
        }
    }
}

/// herdr API socket 的 client。
#[derive(Debug, Clone)]
pub struct HerdrClient {
    socket: HerdrSocket,
}

static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

impl HerdrClient {
    pub fn new(socket: HerdrSocket) -> Self {
        HerdrClient { socket }
    }

    /// 送一個請求，回傳 `result`。
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, HerdrFailure> {
        self.request_waiting(method, params, Duration::ZERO).await
    }

    /// 同 `request`,但 herdr 自己會等 `herdr_wait`(例如 `agent.prompt` 的 wait),上限跟著延長。
    pub async fn request_waiting(&self, method: &str, params: Value, herdr_wait: Duration) -> Result<Value, HerdrFailure> {
        let (_, result) = self.open(method, params, herdr_wait).await?;
        Ok(result)
    }

    /// `events.subscribe`:herdr 接受後連線保持開著，事件從回傳的訂閱逐一讀出。
    pub async fn subscribe(&self, params: Value) -> Result<HerdrSubscription, HerdrFailure> {
        let (reader, _) = self.open("events.subscribe", params, Duration::ZERO).await?;
        Ok(HerdrSubscription { reader })
    }

    /// 開一條連線、送出請求並讀第一行回應。
    async fn open(&self, method: &str, params: Value, herdr_wait: Duration) -> Result<(BufReader<Box<dyn Duplex>>, Value), HerdrFailure> {
        let id = format!("purrdr-host:{}", NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed));
        let mut line = serde_json::to_vec(&json!({"id": id, "method": method, "params": params})).expect("請求可序列化");
        line.push(b'\n');
        let (reader, response) = tokio::time::timeout(REQUEST_TIMEOUT + herdr_wait, self.exchange(&line))
            .await
            .map_err(|_| HerdrFailure::Unavailable(format!("herdr did not answer {method} in time")))??;
        let response: Value = serde_json::from_str(&response).map_err(|error| HerdrFailure::UnexpectedResponse(error.to_string()))?;
        if let Some(error) = response.get("error") {
            return Err(herdr_failure(error));
        }
        let result = response
            .get("result")
            .cloned()
            .ok_or_else(|| HerdrFailure::UnexpectedResponse("response has neither result nor error".into()))?;
        Ok((reader, result))
    }

    async fn exchange(&self, line: &[u8]) -> Result<(BufReader<Box<dyn Duplex>>, String), HerdrFailure> {
        let stream = connect(&self.socket.native_name())
            .await
            .map_err(|error| HerdrFailure::Unavailable(format!("cannot connect to herdr socket: {error}")))?;
        read_first_line(Box::new(stream), line)
            .await
            .map_err(|error| HerdrFailure::Unavailable(format!("herdr socket closed: {error}")))
    }
}

/// 一條 herdr 事件訂閱。drop 時關閉連線，herdr 跟著結束訂閱。
pub struct HerdrSubscription {
    reader: BufReader<Box<dyn Duplex>>,
}

impl HerdrSubscription {
    /// 下一個事件行(`{"event": …, "data": …}`);herdr 結束訂閱時是 `None`,錯誤 envelope(例如 `events_lost`)是 `Err`。
    pub async fn next_event(&mut self) -> Result<Option<Value>, HerdrFailure> {
        loop {
            let mut line = String::new();
            match self.reader.read_line(&mut line).await {
                Ok(0) => return Ok(None),
                Ok(_) => {}
                Err(error) => return Err(HerdrFailure::Unavailable(format!("herdr socket closed: {error}"))),
            }
            // 看不懂的行略過(之後版本的訊息)。
            let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
            if let Some(error) = value.get("error") {
                return Err(herdr_failure(error));
            }
            if value.get("event").is_some() {
                return Ok(Some(value));
            }
        }
    }
}

trait Duplex: AsyncRead + AsyncWrite + Send + Sync + Unpin {}

impl<T: AsyncRead + AsyncWrite + Send + Sync + Unpin> Duplex for T {}

fn herdr_failure(error: &Value) -> HerdrFailure {
    HerdrFailure::Herdr {
        code: error["code"].as_str().unwrap_or_default().to_owned(),
        message: error["message"].as_str().unwrap_or_default().to_owned(),
    }
}

async fn read_first_line(stream: Box<dyn Duplex>, line: &[u8]) -> std::io::Result<(BufReader<Box<dyn Duplex>>, String)> {
    let mut reader = BufReader::new(stream);
    reader.get_mut().write_all(line).await?;
    let mut response = String::new();
    if reader.read_line(&mut response).await? == 0 {
        return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "no response"));
    }
    Ok((reader, response))
}

#[cfg(unix)]
async fn connect(name: &str) -> std::io::Result<tokio::net::UnixStream> {
    tokio::net::UnixStream::connect(name).await
}

#[cfg(windows)]
async fn connect(name: &str) -> std::io::Result<tokio::net::windows::named_pipe::NamedPipeClient> {
    use tokio::net::windows::named_pipe::ClientOptions;
    const ERROR_PIPE_BUSY: i32 = 231;
    loop {
        match ClientOptions::new().open(name) {
            Err(error) if error.raw_os_error() == Some(ERROR_PIPE_BUSY) => tokio::time::sleep(Duration::from_millis(20)).await,
            result => return result,
        }
    }
}
