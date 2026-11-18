//! 對話紀錄(#59):主機服務依 herdr snapshot 的 agent_session 定位對話紀錄，讀視窗並追蹤尾端推給 app。
//! 以真正的 WebSocket client 連上主機服務，背後是回放錄製 snapshot 的假 herdr 與暫存家目錄裡的對話紀錄。

mod support;

use std::path::{Path, PathBuf};

use purrdr_host_service::transcript::TranscriptEnvironment;
use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, TestHostService, recorded, start_service_with_transcripts};
use tempfile::TempDir;

/// 錄製 snapshot 裡 `w1:p6` 的 Claude Code session 與它的 cwd 轉成的專案資料夾。
const CLAUDE_SESSION: &str = "00000000-0000-0000-0000-000000000001";
const CLAUDE_PROJECT_FOLDER: &str = "-Users-demo-Projects-garden-journal";

struct Fixture {
    home: TempDir,
    _herdr: FakeHerdr,
    service: TestHostService,
}

impl Fixture {
    async fn start(snapshot: Value) -> Fixture {
        Fixture::start_in(tempfile::tempdir().unwrap(), snapshot).await
    }

    /// `home` 是對話紀錄的家目錄。
    async fn start_in(home: TempDir, snapshot: Value) -> Fixture {
        let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson")), ("session.snapshot", snapshot)]).await;
        let service = start_service_with_transcripts(
            herdr.socket.clone(),
            TranscriptEnvironment {
                home: Some(home.path().to_owned()),
                ..TranscriptEnvironment::default()
            },
        )
        .await;
        Fixture { home, _herdr: herdr, service }
    }

    async fn recorded_snapshot() -> Fixture {
        Fixture::start(recorded("session.snapshot.ndjson")).await
    }

    /// 在暫存家目錄寫一個檔案(含上層資料夾)。
    fn write(&self, relative: &str, content: &str) -> PathBuf {
        write_file(self.home.path(), relative, content)
    }

    fn claude_transcript(&self, content: &str) -> PathBuf {
        self.write(&format!(".claude/projects/{CLAUDE_PROJECT_FOLDER}/{CLAUDE_SESSION}.jsonl"), content)
    }

    async fn client(&self) -> TestClient {
        let mut client = TestClient::connect(&self.service).await;
        let welcome = client.request(json!({"type": "hello", "request_id": "r0", "protocol_version": 1})).await;
        assert_eq!(welcome["type"], "welcome");
        client
    }
}

/// 在 `root` 底下寫一個檔案(含上層資料夾)。
fn write_file(root: &Path, relative: &str, content: &str) -> PathBuf {
    // 逐段 join:Windows 上與主機服務回報的路徑一樣都是 `\`。
    let path = relative.split('/').fold(root.to_owned(), |path, component| path.join(component));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, content).unwrap();
    path
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn locate(request_id: &str, kind: &str, value: &str) -> Value {
    json!({"type": "transcript.locate", "request_id": request_id, "session": {"kind": kind, "value": value}, "header": false})
}

#[tokio::test]
async fn locate_finds_the_claude_transcript_of_a_session_herdr_reports() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"a\":1}\n{\"b\":2}\n");
    let mut client = fixture.client().await;

    let reply = client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    assert_eq!(
        reply,
        json!({"type": "transcript.locate.result", "request_id": "r1", "path": path_text(&transcript), "size": 16})
    );
}

#[tokio::test]
async fn locate_rejects_sessions_herdr_does_not_report() {
    let fixture = Fixture::recorded_snapshot().await;
    fixture.write(".claude/projects/-tmp/secret.jsonl", "{}\n");
    let mut client = fixture.client().await;

    let reply = client.request(locate("r1", "id", "secret")).await;

    assert_eq!(reply["code"], "transcript_not_allowed");
    assert_eq!(reply["request_id"], "r1");
}

#[tokio::test]
async fn locate_reports_absent_before_the_first_prompt_writes_the_transcript() {
    let fixture = Fixture::recorded_snapshot().await;
    let mut client = fixture.client().await;

    let reply = client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    assert_eq!(reply["code"], "transcript_absent");
}

#[tokio::test]
async fn locate_falls_back_to_the_same_session_file_in_another_project_folder() {
    // worktree:Claude 以 worktree 的 cwd 建資料夾，herdr 回報的 cwd 是主資料夾(行為規格 §4.1)。
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.write(
        &format!(".claude/projects/-Users-demo-Projects-garden-journal-wt/{CLAUDE_SESSION}.jsonl"),
        "{}\n",
    );
    let mut client = fixture.client().await;

    let reply = client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    assert_eq!(reply["path"], path_text(&transcript));
}

/// 只有一個 agent 的 snapshot。
fn snapshot_with(agent: &str, kind: &str, value: &str) -> Value {
    json!({"id": "", "result": {"type": "session_snapshot", "snapshot": {
        "workspaces": [{"workspace_id": "w1", "label": "demo"}],
        "agents": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": agent, "agent_status": "idle",
                    "cwd": "/Users/demo/Projects/demo",
                    "agent_session": {"source": format!("herdr:{agent}"), "agent": agent, "kind": kind, "value": value}}]
    }}})
}

const CODEX_SESSION: &str = "019a5b2c-0000-7000-8000-000000000042";

#[tokio::test]
async fn locate_finds_the_codex_rollout_and_returns_its_header() {
    let fixture = Fixture::start(snapshot_with("codex", "id", CODEX_SESSION)).await;
    let meta = format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{CODEX_SESSION}\"}}}}");
    let rollout = fixture.write(
        &format!(".codex/sessions/2026/11/17/rollout-2026-11-17T10-00-00-{CODEX_SESSION}.jsonl"),
        &format!("{meta}\n{{\"n\":2}}\n{{\"n\":3}}\n"),
    );
    let mut client = fixture.client().await;

    let reply = client
        .request(json!({"type": "transcript.locate", "request_id": "r1", "session": {"kind": "id", "value": CODEX_SESSION}, "header": true}))
        .await;

    assert_eq!(reply["path"], path_text(&rollout));
    assert_eq!(reply["header"], json!([meta, "{\"n\":2}"]));
}

#[tokio::test]
async fn locate_refuses_to_guess_between_codex_rollouts_and_reports_compressed_ones() {
    let ambiguous = Fixture::start(snapshot_with("codex", "id", CODEX_SESSION)).await;
    ambiguous.write(&format!(".codex/sessions/2026/11/17/rollout-a-{CODEX_SESSION}.jsonl"), "{}\n");
    ambiguous.write(&format!(".codex/archived_sessions/rollout-b-{CODEX_SESSION}_7.jsonl"), "{}\n");
    let compressed = Fixture::start(snapshot_with("codex", "id", CODEX_SESSION)).await;
    compressed.write(&format!(".codex/sessions/2026/11/10/rollout-a-{CODEX_SESSION}.jsonl.zst"), "zstd");

    let ambiguous_reply = ambiguous.client().await.request(locate("r1", "id", CODEX_SESSION)).await;
    let compressed_reply = compressed.client().await.request(locate("r1", "id", CODEX_SESSION)).await;

    assert_eq!(ambiguous_reply["code"], "transcript_ambiguous");
    assert_eq!(compressed_reply["code"], "transcript_compressed");
}

#[tokio::test]
async fn locate_uses_the_path_an_antigravity_or_pi_integration_reports() {
    let home = tempfile::tempdir().unwrap();
    let journal = write_file(home.path(), "pi/sessions/2026-11-17_abc.jsonl", "{}\n");
    let fixture = Fixture::start_in(home, snapshot_with("pi", "path", &path_text(&journal))).await;
    let mut client = fixture.client().await;

    let reply = client.request(locate("r1", "path", &path_text(&journal))).await;

    assert_eq!(reply["path"], path_text(&journal));
    assert_eq!(reply["size"], 3);
}

#[tokio::test]
async fn locate_finds_the_antigravity_transcript_of_a_session_id() {
    let fixture = Fixture::start(snapshot_with("agy", "id", "abc-123")).await;
    let transcript = fixture.write(".gemini/antigravity-cli/brain/abc-123/.system_generated/logs/transcript.jsonl", "{}\n");

    let reply = fixture.client().await.request(locate("r1", "id", "abc-123")).await;

    assert_eq!(reply["path"], path_text(&transcript));
}

#[tokio::test]
async fn locate_rejects_unsafe_session_references_even_when_herdr_reports_them() {
    let traversal = Fixture::start(snapshot_with("claude", "id", "../../etc")).await;
    let claude_path = Fixture::start(snapshot_with("claude", "path", "/etc/passwd.jsonl")).await;
    let not_jsonl = Fixture::start(snapshot_with("pi", "path", "/etc/passwd")).await;
    let dot_dot = Fixture::start(snapshot_with("agy", "path", "/home/demo/../../etc/x.jsonl")).await;

    let replies = [
        traversal.client().await.request(locate("r1", "id", "../../etc")).await,
        claude_path.client().await.request(locate("r1", "path", "/etc/passwd.jsonl")).await,
        not_jsonl.client().await.request(locate("r1", "path", "/etc/passwd")).await,
        dot_dot.client().await.request(locate("r1", "path", "/home/demo/../../etc/x.jsonl")).await,
    ];

    for reply in replies {
        assert_eq!(reply["code"], "transcript_not_allowed", "{reply}");
    }
}

#[tokio::test]
async fn locate_reports_agents_whose_transcripts_the_host_service_cannot_read_yet() {
    let fixture = Fixture::start(snapshot_with("grok", "id", "abc-1")).await;

    let reply = fixture.client().await.request(locate("r1", "id", "abc-1")).await;

    assert_eq!(reply["code"], "transcript_unsupported");
}

fn window(request_id: &str, path: &str, end: u64, lines: u64) -> Value {
    json!({"type": "transcript.window", "request_id": request_id, "path": path, "end": end, "lines": lines})
}

#[tokio::test]
async fn window_reads_the_last_lines_with_raw_lengths_and_images_stripped() {
    let fixture = Fixture::recorded_snapshot().await;
    let image = "A".repeat(200);
    let second = format!("{{\"image\":\"{image}\",\"uri\":\"data:image/png;base64,iVBOR\"}}");
    let content = format!("{{\"n\":1}}\n{second}\n{{\"n\":3}}\n{{\"partial\"");
    let transcript = fixture.claude_transcript(&content);
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    let reply = client.request(window("r2", &path_text(&transcript), content.len() as u64, 2)).await;

    let second_start = "{\"n\":1}\n".len();
    let complete_end = content.len() - "{\"partial\"".len();
    assert_eq!(
        reply,
        json!({
            "type": "transcript.window.result",
            "request_id": "r2",
            "start": second_start,
            "end": complete_end,
            "records": [
                {"length": second.len(), "text": "{\"image\":\"\",\"uri\":\"\"}"},
                {"length": 7, "text": "{\"n\":3}"}
            ]
        })
    );
}

#[tokio::test]
async fn window_grows_its_chunk_until_it_has_enough_lines() {
    let fixture = Fixture::recorded_snapshot().await;
    let content: String = (0..2000)
        .map(|index| format!("{{\"line\":{index:05},\"pad\":\"{}\"}}\n", "x".repeat(4000)))
        .collect();
    let transcript = fixture.claude_transcript(&content);
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    let reply = client.request(window("r2", &path_text(&transcript), content.len() as u64, 1500)).await;

    let records = reply["records"].as_array().unwrap();
    assert_eq!(records.len(), 1500);
    assert!(records[0]["text"].as_str().unwrap().starts_with("{\"line\":00500"));
    assert_eq!(reply["end"], content.len());
}

#[tokio::test]
async fn window_refuses_paths_this_connection_did_not_locate() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{}\n");
    let secret = fixture.write("secret.jsonl", "{\"token\":\"x\"}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    let reply = client.request(window("r2", &path_text(&secret), 14, 10)).await;
    let other_connection = fixture.client().await.request(window("r3", &path_text(&transcript), 3, 10)).await;

    assert_eq!(reply["code"], "transcript_not_allowed");
    assert_eq!(other_connection["code"], "transcript_not_allowed");
}

fn follow(request_id: &str, stream_id: &str, path: &str, from: usize, limit: usize) -> Value {
    json!({"type": "transcript.follow", "request_id": request_id, "stream_id": stream_id, "path": path, "from": from, "limit": limit})
}

fn append(path: &Path, text: &str) {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    file.write_all(text.as_bytes()).unwrap();
}

#[tokio::test]
async fn follow_returns_lines_after_the_cursor_then_pushes_new_complete_lines() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"n\":1}\n{\"n\":2}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    let started = client.request(follow("r2", "s1", &path_text(&transcript), 8, 65536)).await;
    append(&transcript, "{\"n\":3}\n{\"n\":");
    let first_push = client.receive().await;
    append(&transcript, "4}\n");
    let second_push = client.receive().await;

    assert_eq!(
        started,
        json!({"type": "transcript.follow.result", "request_id": "r2", "stream_id": "s1", "size": 16, "start": 8,
               "records": [{"length": 7, "text": "{\"n\":2}"}]})
    );
    assert_eq!(
        first_push,
        json!({"type": "transcript.update", "stream_id": "s1", "size": 29, "start": 16, "records": [{"length": 7, "text": "{\"n\":3}"}]})
    );
    assert_eq!(
        second_push,
        json!({"type": "transcript.update", "stream_id": "s1", "size": 32, "start": 24, "records": [{"length": 7, "text": "{\"n\":4}"}]})
    );
}

#[tokio::test]
async fn follow_ends_with_shrank_when_the_transcript_is_replaced_by_a_shorter_one() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"n\":1}\n{\"n\":2}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;
    client.request(follow("r2", "s1", &path_text(&transcript), 16, 65536)).await;

    std::fs::write(&transcript, "{}\n").unwrap();
    let ended = client.receive().await;

    assert_eq!(
        ended,
        json!({"type": "transcript.update", "stream_id": "s1", "size": 3, "start": 16, "records": [], "ended": "shrank"})
    );
}

#[tokio::test]
async fn follow_ends_with_replaced_when_the_transcript_is_replaced_by_one_of_the_same_length() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"n\":1}\n{\"n\":2}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;
    client.request(follow("r2", "s1", &path_text(&transcript), 16, 65536)).await;

    std::fs::write(&transcript, "{\"m\":1}\n{\"m\":2}\n").unwrap();
    let ended = client.receive().await;

    assert_eq!(
        ended,
        json!({"type": "transcript.update", "stream_id": "s1", "size": 16, "start": 16, "records": [], "ended": "replaced"})
    );
}

#[tokio::test]
async fn follow_ends_with_replaced_instead_of_pushing_lines_of_a_longer_replacement() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"n\":1}\n{\"n\":2}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;
    client.request(follow("r2", "s1", &path_text(&transcript), 16, 65536)).await;

    std::fs::write(&transcript, "{\"m\":1}\n{\"m\":2}\n{\"m\":3}\n").unwrap();
    let ended = client.receive().await;

    assert_eq!(
        ended,
        json!({"type": "transcript.update", "stream_id": "s1", "size": 24, "start": 16, "records": [], "ended": "replaced"})
    );
}

#[tokio::test]
async fn follow_that_starts_too_far_behind_ends_immediately_so_the_app_reads_a_window() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"n\":1}\n{\"n\":2}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;

    let started = client.request(follow("r2", "s1", &path_text(&transcript), 0, 10)).await;

    assert_eq!(
        started,
        json!({"type": "transcript.follow.result", "request_id": "r2", "stream_id": "s1", "size": 16, "start": 0, "records": [],
               "ended": "too_far_behind"})
    );
}

#[tokio::test]
async fn unfollow_stops_pushing_updates() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"n\":1}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;
    client.request(follow("r2", "s1", &path_text(&transcript), 8, 65536)).await;

    let stopped = client
        .request(json!({"type": "transcript.unfollow", "request_id": "r3", "stream_id": "s1"}))
        .await;
    append(&transcript, "{\"n\":2}\n");
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    let next = client.request(json!({"type": "agents.list", "request_id": "r4"})).await;

    assert_eq!(stopped, json!({"type": "transcript.unfollow.result", "request_id": "r3"}));
    assert_eq!(next["type"], "agents.list.result");
}

#[tokio::test]
async fn follow_refuses_paths_this_connection_did_not_locate() {
    let fixture = Fixture::recorded_snapshot().await;
    let secret = fixture.write("secret.jsonl", "{\"token\":\"x\"}\n");
    let mut client = fixture.client().await;

    let reply = client.request(follow("r1", "s1", &path_text(&secret), 0, 65536)).await;

    assert_eq!(reply["code"], "transcript_not_allowed");
}

#[tokio::test]
async fn two_streams_on_one_connection_are_followed_independently() {
    let fixture = Fixture::recorded_snapshot().await;
    let transcript = fixture.claude_transcript("{\"n\":1}\n");
    let mut client = fixture.client().await;
    client.request(locate("r1", "id", CLAUDE_SESSION)).await;
    client.request(follow("r2", "first", &path_text(&transcript), 8, 65536)).await;
    client.request(follow("r3", "second", &path_text(&transcript), 0, 65536)).await;
    client
        .request(json!({"type": "transcript.unfollow", "request_id": "r4", "stream_id": "second"}))
        .await;

    append(&transcript, "{\"n\":2}\n");
    let pushed = client.receive().await;
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    let next = client.request(json!({"type": "agents.list", "request_id": "r5"})).await;

    assert_eq!(pushed["stream_id"], "first");
    assert_eq!(next["type"], "agents.list.result");
}
