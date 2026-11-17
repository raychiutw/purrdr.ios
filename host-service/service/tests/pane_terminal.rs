//! Pane 終端機(#61、ADR-0005):主機服務以子行程執行 `herdr terminal session control`／`observe`,
//! 轉接 NDJSON 畫面更新與輸入。以真正的 WebSocket client 從協定這一端驗證。
//!
//! 假的 herdr CLI 就是這支測試執行檔本身(`fake-herdr` 參數):回放 #4 spike 錄製的 stdout,
//! 並把收到的參數與 stdin 寫進紀錄檔。所以這個測試不用 libtest(`harness = false`),自己跑測試。

mod support;

use std::future::Future;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::pin::Pin;
use std::time::Duration;

use base64::Engine;
use purrdr_host_service::herdr_cli::HerdrCli;
use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, TestHostService, recorded, start_service_with_herdr_cli};
use tempfile::TempDir;

const FAKE_HERDR: &str = "fake-herdr";

fn fixtures_directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/PurrdrTestSupport/Fixtures/herdr-0.9.5/session-control")
}

fn fixture_lines(name: &str) -> Vec<Value> {
    let path = fixtures_directory().join(format!("{name}.stdout.ndjson"));
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// 錄製的 frame 換成協定的 `pane.terminal.frame`(欄位原樣，加上串流識別碼)。
fn relayed_frames(fixture: &str, stream_id: &str) -> Vec<Value> {
    fixture_lines(fixture)
        .into_iter()
        .filter(|line| line["type"] == "terminal.frame")
        .map(|frame| {
            json!({
                "type": "pane.terminal.frame", "stream_id": stream_id, "seq": frame["seq"], "width": frame["width"],
                "height": frame["height"], "full": frame["full"], "bytes": frame["bytes"],
            })
        })
        .collect()
}

// MARK: - 假的 herdr CLI

/// `fake-herdr <紀錄檔> [--session <名稱>] terminal session control|observe <target> --cols N --rows N [--takeover]`
///
/// - target `fail`:stderr 印一行後 exit 3(herdr 沒跑起來)。
/// - observe:印出錄製的 frame 後一直執行，每 50 ms 在紀錄檔寫 `alive`,不讀 stdin(實測：observer 關 stdin 也不會結束)。
/// - control,錄製檔最後是 `detached`:印出前面的行，讀 stdin 到 `terminal.release` 或 EOF,再印最後一行。
/// - 其他:原樣印出錄製檔後結束(herdr 主動結束、或沒有 `terminal.closed` 就斷線)。
fn fake_herdr(arguments: &[String]) -> i32 {
    let log_path = PathBuf::from(&arguments[0]);
    let herdr_arguments = &arguments[1..];
    let log = |line: String| {
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&log_path).unwrap();
        writeln!(file, "{line}").unwrap();
    };
    log(format!("args {}", serde_json::to_string(herdr_arguments).unwrap()));
    let subcommand = herdr_arguments.iter().position(|argument| argument == "terminal").unwrap();
    let mode = herdr_arguments[subcommand + 2].as_str();
    let target = herdr_arguments[subcommand + 3].as_str();
    if target == "fail" {
        eprintln!("herdr: cannot connect to the herdr server");
        return 3;
    }
    let lines: Vec<String> = fixture_lines(target).iter().map(Value::to_string).collect();
    let mut stdout = std::io::stdout();
    let mut print = |line: &str| {
        writeln!(stdout, "{line}").unwrap();
        stdout.flush().unwrap();
    };
    if mode == "observe" {
        lines.iter().filter(|line| !line.contains("terminal.closed")).for_each(|line| print(line));
        loop {
            log("alive".into());
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    let last = lines.last().cloned().unwrap_or_default();
    if !last.contains(r#""reason":"detached""#) {
        lines.iter().for_each(|line| print(line));
        log("exit".into());
        return 0;
    }
    lines[..lines.len() - 1].iter().for_each(|line| print(line));
    let mut released = false;
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        log(format!("stdin {line}"));
        if line.contains("terminal.release") {
            released = true;
            break;
        }
    }
    if !released {
        log("eof".into());
    }
    print(&last);
    log("exit".into());
    0
}

/// 一次測試用的假 herdr CLI 與它的紀錄檔。
struct FakeHerdrCli {
    directory: TempDir,
}

impl FakeHerdrCli {
    fn new() -> FakeHerdrCli {
        FakeHerdrCli {
            directory: tempfile::tempdir().unwrap(),
        }
    }

    fn log_path(&self) -> PathBuf {
        self.directory.path().join("herdr.log")
    }

    fn cli(&self) -> HerdrCli {
        HerdrCli::at_path(
            std::env::current_exe().unwrap(),
            vec![FAKE_HERDR.to_owned(), self.log_path().to_string_lossy().into_owned()],
        )
    }

    fn log(&self) -> Vec<String> {
        std::fs::read_to_string(self.log_path())
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn arguments(&self) -> Vec<Vec<String>> {
        self.log()
            .iter()
            .filter_map(|line| line.strip_prefix("args "))
            .map(|json| serde_json::from_str(json).unwrap())
            .collect()
    }

    fn stdin(&self) -> Vec<Value> {
        self.log()
            .iter()
            .filter_map(|line| line.strip_prefix("stdin "))
            .map(|json| serde_json::from_str(json).unwrap())
            .collect()
    }

    /// 等到紀錄檔有 `entry` 這一行。
    async fn wait_for(&self, entry: &str) {
        let waited = tokio::time::timeout(Duration::from_secs(10), async {
            while !self.log().iter().any(|line| line == entry) {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        assert!(waited.is_ok(), "等不到紀錄 {entry}:{:?}", self.log());
    }
}

// MARK: - 測試環境

struct Harness {
    _herdr: FakeHerdr,
    herdr_cli: FakeHerdrCli,
    service: TestHostService,
}

impl Harness {
    async fn start() -> Harness {
        let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson"))]).await;
        let herdr_cli = FakeHerdrCli::new();
        let service = start_service_with_herdr_cli(herdr.socket.clone(), herdr_cli.cli()).await;
        Harness {
            _herdr: herdr,
            herdr_cli,
            service,
        }
    }

    async fn client(&self) -> TestClient {
        let mut client = TestClient::connect(&self.service).await;
        client.request(hello()).await;
        client
    }

    async fn read_only_client(&self) -> TestClient {
        let device = self.service.pair_device("借出的 iPad", true);
        let mut client = TestClient::connect_with_token(&self.service, Some(&device.device_token)).await;
        client.request(hello()).await;
        client
    }
}

fn hello() -> Value {
    json!({"type": "hello", "request_id": "h1", "protocol_version": 1})
}

fn open(request_id: &str, target: &str) -> Value {
    json!({"type": "pane.terminal.open", "request_id": request_id, "target": target, "columns": 40, "rows": 12})
}

fn base64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

async fn receive_frames(client: &mut TestClient, count: usize) -> Vec<Value> {
    let mut frames = Vec::new();
    for _ in 0..count {
        frames.push(client.receive().await);
    }
    frames
}

// MARK: - 測試

async fn recorded_frames_are_relayed_unchanged_and_input_reaches_herdr() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;

    let opened = client.request(open("t1", "01-handshake-echo-release")).await;
    let frames = receive_frames(&mut client, 3).await;
    client
        .send(json!({"type": "pane.terminal.input", "stream_id": "t1", "bytes": base64(b"echo hello-\"\"world\r")}))
        .await;
    client.send(json!({"type": "pane.terminal.close", "stream_id": "t1"})).await;
    let closed = client.receive().await;

    assert_eq!(
        opened,
        json!({"type": "pane.terminal.open.result", "request_id": "t1", "stream_id": "t1", "read_only": false})
    );
    assert_eq!(frames, relayed_frames("01-handshake-echo-release", "t1"));
    assert_eq!(
        closed,
        json!({"type": "pane.terminal.closed", "stream_id": "t1", "ending": "closed", "reason": "detached"})
    );
    assert_eq!(
        harness.herdr_cli.arguments(),
        [["terminal", "session", "control", "01-handshake-echo-release", "--cols", "40", "--rows", "12"]]
    );
    assert_eq!(
        harness.herdr_cli.stdin(),
        [json!({"type": "terminal.input", "bytes": base64(b"echo hello-\"\"world\r")})]
    );
    harness.herdr_cli.wait_for("eof").await;
}

async fn resize_and_scroll_reach_herdr_in_its_wire_format() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.request(open("t1", "02-resize")).await;

    client
        .send(json!({"type": "pane.terminal.resize", "stream_id": "t1", "columns": 60, "rows": 15}))
        .await;
    client
        .send(json!({"type": "pane.terminal.scroll", "stream_id": "t1", "direction": "down", "lines": 2, "column": 0, "row": 0}))
        .await;
    client.send(json!({"type": "pane.terminal.close", "stream_id": "t1"})).await;
    harness.herdr_cli.wait_for("exit").await;

    // 與 spike 實際送給 herdr 的行相同(02-resize、03-scroll-host-scrollback 的 stdin 錄製檔)。
    assert_eq!(
        harness.herdr_cli.stdin(),
        [
            json!({"type": "terminal.resize", "cols": 60, "rows": 15, "cell_width_px": 0, "cell_height_px": 0}),
            json!({"type": "terminal.scroll", "direction": "down", "lines": 2, "source": "wheel", "column": 0, "row": 0, "modifiers": 0}),
        ]
    );
}

async fn takeover_is_passed_to_herdr() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    let mut request = open("t1", "06-takeover-A");
    request["takeover"] = json!(true);

    client.request(request).await;
    harness.herdr_cli.wait_for("exit").await;

    assert_eq!(
        harness.herdr_cli.arguments(),
        [["terminal", "session", "control", "06-takeover-A", "--cols", "40", "--rows", "12", "--takeover"]]
    );
}

async fn herdr_close_reason_is_relayed_verbatim() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;

    client.request(open("t1", "13-not-found-control")).await;
    let closed = client.receive().await;

    assert_eq!(
        closed,
        json!({
            "type": "pane.terminal.closed", "stream_id": "t1", "ending": "closed",
            "reason": "terminal session control failed: terminal target term_doesnotexist not found",
        })
    );
}

async fn output_ending_without_terminal_closed_is_a_disconnect() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    let expected_frames = relayed_frames("11-oversize-input-disconnect", "t1");

    client.request(open("t1", "11-oversize-input-disconnect")).await;
    let frames = receive_frames(&mut client, expected_frames.len()).await;
    let closed = client.receive().await;

    assert_eq!(frames, expected_frames);
    assert_eq!(closed, json!({"type": "pane.terminal.closed", "stream_id": "t1", "ending": "disconnected"}));
}

async fn herdr_that_fails_to_start_reports_exit_code_and_stderr() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;

    client.request(open("t1", "fail")).await;
    let closed = client.receive().await;

    assert_eq!(closed["type"], "pane.terminal.closed");
    assert_eq!(closed["ending"], "failed");
    assert_eq!(closed["exit_code"], 3);
    assert_eq!(closed["message"], "herdr: cannot connect to the herdr server");
}

async fn missing_herdr_is_reported_as_unavailable() {
    let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson"))]).await;
    let missing = HerdrCli::at_path(PathBuf::from("/purrdr/no-such-herdr"), Vec::new());
    let service = start_service_with_herdr_cli(herdr.socket.clone(), missing).await;
    let mut client = TestClient::connect(&service).await;
    client.request(hello()).await;

    let reply = client.request(open("t1", "w1:p1")).await;

    assert_eq!(reply["type"], "error");
    assert_eq!(reply["request_id"], "t1");
    assert_eq!(reply["code"], "herdr_unavailable");
}

async fn read_only_device_observes_and_cannot_type() {
    let harness = Harness::start().await;
    let mut client = harness.read_only_client().await;
    let mut request = open("t1", "06-takeover-observer");
    request["takeover"] = json!(true);

    let opened = client.request(request).await;
    let first_frame = client.receive().await;
    client
        .send(json!({"type": "pane.terminal.input", "stream_id": "t1", "bytes": base64(b"rm -rf ~\r")}))
        .await;
    // 拒絕之前可能還有 observer 的其他 frame。
    let rejected = loop {
        let message = client.receive().await;
        if message["type"] == "error" {
            break message;
        }
    };

    assert_eq!(opened["read_only"], true);
    assert_eq!(first_frame, relayed_frames("06-takeover-observer", "t1")[0]);
    assert_eq!(rejected["code"], "read_only_device");
    assert_eq!(
        harness.herdr_cli.arguments(),
        [["terminal", "session", "observe", "06-takeover-observer", "--cols", "40", "--rows", "12"]]
    );
    assert!(harness.herdr_cli.stdin().is_empty());
}

async fn invalid_target_and_size_are_rejected_without_running_herdr() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    let mut huge = open("t2", "w1:p1");
    huge["columns"] = json!(100_000);

    let option_like = client.request(open("t1", "--help")).await;
    let too_large = client.request(huge).await;

    assert_eq!(option_like["code"], "invalid_message");
    assert_eq!(too_large["code"], "invalid_message");
    assert!(harness.herdr_cli.arguments().is_empty());
}

async fn open_before_handshake_requires_handshake() {
    let harness = Harness::start().await;
    let mut client = TestClient::connect(&harness.service).await;

    let reply = client.request(open("t1", "01-handshake-echo-release")).await;

    assert_eq!(reply["code"], "handshake_required");
    assert!(harness.herdr_cli.arguments().is_empty());
}

async fn closing_the_websocket_releases_control_and_ends_observers() {
    let harness = Harness::start().await;
    let mut controller = harness.client().await;
    let mut observer = harness.read_only_client().await;
    controller.request(open("t1", "01-handshake-echo-release")).await;
    observer.request(open("t1", "06-takeover-observer")).await;
    harness.herdr_cli.wait_for("alive").await;

    drop(controller);
    drop(observer);

    // control:stdin EOF 等同 release,herdr 自己結束。
    harness.herdr_cli.wait_for("eof").await;
    harness.herdr_cli.wait_for("exit").await;
    // observe:關 stdin 不會結束，主機服務要結束子行程。
    tokio::time::sleep(Duration::from_secs(1)).await;
    let alive_count = || harness.herdr_cli.log().iter().filter(|line| *line == "alive").count();
    let before = alive_count();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(alive_count(), before, "observer 子行程還在執行");
}

async fn terminal_content_never_reaches_the_audit_log() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    let secret = b"s3cret-passphrase\r";

    client.request(open("t1", "01-handshake-echo-release")).await;
    receive_frames(&mut client, 3).await;
    client
        .send(json!({"type": "pane.terminal.input", "stream_id": "t1", "bytes": base64(secret)}))
        .await;
    client.send(json!({"type": "pane.terminal.close", "stream_id": "t1"})).await;
    client.receive().await;

    let audit = harness.service.audit_log();
    assert!(!audit.contains("s3cret"), "{audit}");
    assert!(!audit.contains(&base64(secret)), "{audit}");
    assert!(!audit.contains("hello"), "{audit}");
    let opened: Vec<Value> = audit
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|event| event["operation"] == "pane.terminal.open")
        .collect();
    assert_eq!(opened.len(), 1, "{audit}");
    assert_eq!(opened[0]["pane_id"], "01-handshake-echo-release");
    assert_eq!(
        audit.lines().filter(|line| line.contains("pane.terminal.input")).count(),
        0,
        "每個按鍵都不記：{audit}"
    );
}

// MARK: - 執行

type TestCase = (&'static str, fn() -> Pin<Box<dyn Future<Output = ()>>>);

fn tests() -> Vec<TestCase> {
    vec![
        ("recorded_frames_are_relayed_unchanged_and_input_reaches_herdr", || {
            Box::pin(recorded_frames_are_relayed_unchanged_and_input_reaches_herdr())
        }),
        ("resize_and_scroll_reach_herdr_in_its_wire_format", || {
            Box::pin(resize_and_scroll_reach_herdr_in_its_wire_format())
        }),
        ("takeover_is_passed_to_herdr", || Box::pin(takeover_is_passed_to_herdr())),
        ("herdr_close_reason_is_relayed_verbatim", || Box::pin(herdr_close_reason_is_relayed_verbatim())),
        ("output_ending_without_terminal_closed_is_a_disconnect", || {
            Box::pin(output_ending_without_terminal_closed_is_a_disconnect())
        }),
        ("herdr_that_fails_to_start_reports_exit_code_and_stderr", || {
            Box::pin(herdr_that_fails_to_start_reports_exit_code_and_stderr())
        }),
        ("missing_herdr_is_reported_as_unavailable", || {
            Box::pin(missing_herdr_is_reported_as_unavailable())
        }),
        ("read_only_device_observes_and_cannot_type", || {
            Box::pin(read_only_device_observes_and_cannot_type())
        }),
        ("invalid_target_and_size_are_rejected_without_running_herdr", || {
            Box::pin(invalid_target_and_size_are_rejected_without_running_herdr())
        }),
        ("open_before_handshake_requires_handshake", || {
            Box::pin(open_before_handshake_requires_handshake())
        }),
        ("closing_the_websocket_releases_control_and_ends_observers", || {
            Box::pin(closing_the_websocket_releases_control_and_ends_observers())
        }),
        ("terminal_content_never_reaches_the_audit_log", || {
            Box::pin(terminal_content_never_reaches_the_audit_log())
        }),
    ]
}

fn main() -> std::process::ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.first().map(String::as_str) == Some(FAKE_HERDR) {
        return std::process::ExitCode::from(fake_herdr(&arguments[1..]) as u8);
    }
    // cargo test 傳進來的篩選字(不是 `--` 開頭的參數)。
    let filters: Vec<&String> = arguments.iter().filter(|argument| !argument.starts_with('-')).collect();
    let selected: Vec<TestCase> = tests()
        .into_iter()
        .filter(|(name, _)| filters.is_empty() || filters.iter().any(|filter| name.contains(filter.as_str())))
        .collect();
    println!("\nrunning {} tests", selected.len());
    let mut failures = Vec::new();
    for (name, test) in &selected {
        let outcome = std::panic::catch_unwind(|| {
            tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(test());
        });
        println!("test {name} ... {}", if outcome.is_ok() { "ok" } else { "FAILED" });
        if outcome.is_err() {
            failures.push(*name);
        }
    }
    println!("\ntest result: {} passed; {} failed", selected.len() - failures.len(), failures.len());
    if failures.is_empty() {
        std::process::ExitCode::SUCCESS
    } else {
        println!("failures: {failures:?}");
        std::process::ExitCode::FAILURE
    }
}
