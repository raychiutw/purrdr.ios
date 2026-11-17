//! Pane 終端機(ADR-0005、#61):以子行程執行 `herdr terminal session control`(唯讀裝置用 `observe`),
//! 把 stdout 的 NDJSON 轉成協定訊息、把 app 的輸入寫進 stdin。這是主機服務唯一會執行的 herdr CLI(ADR-0010)。
//!
//! 實測行為見 `docs/research/terminal-session-control-macos.md`、`-windows.md`。

use std::process::Stdio;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdin, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

use crate::herdr_cli::HerdrCli;
use crate::protocol::{PaneTerminalClosed, PaneTerminalEnding, PaneTerminalFrame, PaneTerminalOpen, ServerMessage};

/// 格數上限(與 app 相同);herdr 會接受 5000 欄並回很大的 full frame。
pub const MAX_COLUMNS: i64 = 500;
pub const MAX_ROWS: i64 = 200;
/// 單則輸入的 base64 長度上限(64 KiB 的 bytes);herdr 收到 > 1 MiB 的單則會直接斷線。
pub const MAX_INPUT_BASE64_LENGTH: usize = (64 * 1024_usize).div_ceil(3) * 4;

/// control 關閉 stdin 後等 herdr 自己結束的時間，到了就結束子行程。
const RELEASE_GRACE: Duration = Duration::from_secs(2);
/// 失敗訊息保留的 stderr 長度。
const MAX_STDERR_BYTES: usize = 4096;

/// Windows:不開 console 視窗(背景執行檔沒有 console)。
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// pane id 或 terminal id:不能以 `-` 開頭(會被當成選項)。
pub fn is_valid_target(target: &str) -> bool {
    !target.is_empty()
        && target.len() <= 128
        && !target.starts_with('-')
        && target
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, ':' | '_' | '-' | '.'))
}

pub fn is_valid_size(columns: i64, rows: i64) -> bool {
    (1..=MAX_COLUMNS).contains(&columns) && (1..=MAX_ROWS).contains(&rows)
}

/// 一條執行中的 Pane 終端機。drop 時關閉 stdin 並結束子行程(control 先等 herdr 自己 release)。
pub(crate) struct PaneTerminal {
    stdin: Option<ChildStdin>,
    /// drop 時通知讀取工作收尾。
    _stop: oneshot::Sender<()>,
}

impl PaneTerminal {
    /// 開始執行 herdr(`observe` 時只能看);之後的畫面更新與結束以開啟請求的 request_id 為串流識別碼送進 `outgoing`。
    pub fn spawn(herdr: &HerdrCli, request: &PaneTerminalOpen, observe: bool, outgoing: mpsc::Sender<ServerMessage>) -> std::io::Result<PaneTerminal> {
        let mut command = Command::new(herdr.program());
        command
            .args(herdr.leading_arguments())
            .args(["terminal", "session", if observe { "observe" } else { "control" }, &request.target])
            .args(["--cols", &request.columns.to_string(), "--rows", &request.rows.to_string()]);
        if request.takeover == Some(true) && !observe {
            command.arg("--takeover");
        }
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        #[cfg(windows)]
        command.creation_flags(CREATE_NO_WINDOW);
        let mut child = command.spawn()?;
        let stdin = child.stdin.take();
        let (stop, stopped) = oneshot::channel();
        let grace = if observe { Duration::ZERO } else { RELEASE_GRACE };
        tokio::spawn(relay(child, request.request_id.clone(), outgoing, stopped, grace));
        Ok(PaneTerminal { stdin, _stop: stop })
    }

    /// 寫一行 herdr 的 control 訊息。herdr 已結束時忽略(結束會另外以 `pane.terminal.closed` 告知)。
    pub async fn write(&mut self, message: Value) {
        let Some(stdin) = self.stdin.as_mut() else { return };
        let mut line = serde_json::to_vec(&message).expect("control 訊息可序列化");
        line.push(b'\n');
        if stdin.write_all(&line).await.is_err() {
            self.stdin = None;
        }
    }

    pub async fn input(&mut self, bytes: String) {
        self.write(json!({"type": "terminal.input", "bytes": bytes})).await;
    }

    pub async fn resize(&mut self, columns: i64, rows: i64) {
        self.write(json!({"type": "terminal.resize", "cols": columns, "rows": rows, "cell_width_px": 0, "cell_height_px": 0}))
            .await;
    }

    pub async fn scroll(&mut self, direction: &str, lines: i64, column: i64, row: i64) {
        self.write(json!({
            "type": "terminal.scroll", "direction": direction, "lines": lines, "source": "wheel",
            "column": column, "row": row, "modifiers": 0,
        }))
        .await;
    }
}

/// herdr stdout 的一行(只取轉接需要的欄位)。
#[derive(Deserialize)]
struct HerdrLine {
    #[serde(rename = "type")]
    kind: String,
    seq: Option<i64>,
    width: Option<i64>,
    height: Option<i64>,
    full: Option<bool>,
    bytes: Option<String>,
    reason: Option<String>,
}

/// 讀 stdout 轉成協定訊息，直到 herdr 結束或被要求收尾。
async fn relay(mut child: Child, stream_id: String, outgoing: mpsc::Sender<ServerMessage>, stopped: oneshot::Receiver<()>, grace: Duration) {
    let stderr = child.stderr.take().map(|stderr| tokio::spawn(read_stderr(stderr)));
    let Some(stdout) = child.stdout.take() else { return };
    let mut lines = BufReader::new(stdout).lines();
    let mut stopped = stopped;
    let mut stop_deadline: Option<Instant> = None;
    let mut closed_reason: Option<String> = None;
    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Ok(Some(line)) = line else { break };
                let Ok(herdr) = serde_json::from_str::<HerdrLine>(&line) else { continue };
                let message = match herdr.kind.as_str() {
                    "terminal.frame" => match frame(&stream_id, herdr) {
                        Some(frame) => ServerMessage::PaneTerminalFrame(frame),
                        None => continue,
                    },
                    "terminal.closed" => {
                        closed_reason = Some(herdr.reason.unwrap_or_default());
                        break;
                    }
                    _ => continue,
                };
                if outgoing.send(message).await.is_err() && stop_deadline.is_none() {
                    // app 的連線已經結束。
                    stop_deadline = Some(Instant::now() + grace);
                }
            }
            _ = &mut stopped, if stop_deadline.is_none() => stop_deadline = Some(Instant::now() + grace),
            _ = tokio::time::sleep_until(stop_deadline.unwrap_or_else(Instant::now)), if stop_deadline.is_some() => {
                let _ = child.kill().await;
                // observe 不會自己送 closed:由主機服務補上(app 已關閉時送不出去也沒關係)。
                let _ = outgoing.try_send(closed(&stream_id, PaneTerminalEnding::Closed, Some("detached".into()), None, None));
                return;
            }
        }
    }
    let ending = match closed_reason {
        Some(reason) => closed(&stream_id, PaneTerminalEnding::Closed, Some(reason), None, None),
        None => {
            // 沒有 terminal.closed 就結束:exit 0 是連線被切(超大輸入、herdr client 被殺);非 0 是 herdr 沒跑起來。
            let status = tokio::time::timeout(RELEASE_GRACE, child.wait()).await;
            let exit_code = status.ok().and_then(Result::ok).and_then(|status| status.code()).unwrap_or(0);
            if exit_code == 0 {
                closed(&stream_id, PaneTerminalEnding::Disconnected, None, None, None)
            } else {
                let message = match stderr {
                    Some(task) => tokio::time::timeout(RELEASE_GRACE, task).await.ok().and_then(Result::ok).unwrap_or_default(),
                    None => String::new(),
                };
                closed(&stream_id, PaneTerminalEnding::Failed, None, Some(i64::from(exit_code)), Some(message))
            }
        }
    };
    let _ = outgoing.send(ending).await;
    if tokio::time::timeout(RELEASE_GRACE, child.wait()).await.is_err() {
        let _ = child.kill().await;
    }
}

fn frame(stream_id: &str, herdr: HerdrLine) -> Option<PaneTerminalFrame> {
    Some(PaneTerminalFrame {
        stream_id: stream_id.to_owned(),
        seq: herdr.seq?,
        width: herdr.width?,
        height: herdr.height?,
        full: herdr.full.unwrap_or(false),
        bytes: herdr.bytes?,
    })
}

fn closed(stream_id: &str, ending: PaneTerminalEnding, reason: Option<String>, exit_code: Option<i64>, message: Option<String>) -> ServerMessage {
    ServerMessage::PaneTerminalClosed(PaneTerminalClosed {
        stream_id: stream_id.to_owned(),
        ending,
        reason,
        exit_code,
        message,
    })
}

/// 讀完 stderr(不讀會讓 herdr 卡在寫入),保留最後 `MAX_STDERR_BYTES`。
async fn read_stderr(mut stderr: ChildStderr) -> String {
    let mut kept = Vec::new();
    let mut buffer = [0u8; 1024];
    while let Ok(count) = stderr.read(&mut buffer).await {
        if count == 0 {
            break;
        }
        kept.extend_from_slice(&buffer[..count]);
        if kept.len() > MAX_STDERR_BYTES {
            kept.drain(..kept.len() - MAX_STDERR_BYTES);
        }
    }
    String::from_utf8_lossy(&kept).trim().to_owned()
}
