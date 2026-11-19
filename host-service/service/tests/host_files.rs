//! 主機取檔(#227):`file.stat` 與 `file.read` 只讀 herdr 回報的 Agent 工作目錄之下、或這條連線定位過的對話紀錄裡出現的檔案;
//! 解析 symlink 後再比對工作目錄與排除清單，並寫不含內容的稽核紀錄。以真正的 WebSocket client 連上主機服務。

mod support;

use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use purrdr_host_service::host_files::{self, MAXIMUM_FILE_SIZE};
use purrdr_host_service::protocol::EXCLUDED_FILE_LOCATIONS;
use purrdr_host_service::transcript::TranscriptEnvironment;
use serde_json::{Value, json};
use support::{FakeHerdr, TestClient, TestHostService, recorded, start_service_with_transcripts};
use tempfile::TempDir;

/// `hello` 的 SHA-256。
const HELLO_VERSION: &str = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

struct Fixture {
    /// Agent 的工作目錄。
    project: TempDir,
    /// 工作目錄以外的地方。
    elsewhere: TempDir,
    herdr: FakeHerdr,
    service: TestHostService,
}

impl Fixture {
    /// 一個 Pi Agent,工作目錄是 `project`,對話紀錄是 `elsewhere/journal.jsonl`。
    async fn start() -> Fixture {
        let project = tempfile::tempdir().unwrap();
        let elsewhere = tempfile::tempdir().unwrap();
        let journal = path_text(&elsewhere.path().join("journal.jsonl"));
        let snapshot = json!({"id": "", "result": {"type": "session_snapshot", "snapshot": {
            "workspaces": [{"workspace_id": "w1", "label": "demo"}],
            "agents": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "pi", "agent_status": "idle",
                        "cwd": path_text(project.path()),
                        "agent_session": {"source": "herdr:pi", "agent": "pi", "kind": "path", "value": journal}}]
        }}});
        let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson")), ("session.snapshot", snapshot)]).await;
        let service = start_service_with_transcripts(herdr.socket.clone(), TranscriptEnvironment::default()).await;
        Fixture {
            project,
            elsewhere,
            herdr,
            service,
        }
    }

    async fn client(&self) -> TestClient {
        let mut client = TestClient::connect(&self.service).await;
        let welcome = client.request(json!({"type": "hello", "request_id": "r0", "protocol_version": 1})).await;
        assert_eq!(welcome["type"], "welcome");
        client
    }

    fn in_project(&self, relative: &str, content: &[u8]) -> PathBuf {
        write_file(self.project.path(), relative, content)
    }

    fn elsewhere(&self, relative: &str, content: &[u8]) -> PathBuf {
        write_file(self.elsewhere.path(), relative, content)
    }

    /// 對話紀錄寫入 `lines` 並在這條連線定位。
    async fn locate_journal(&self, client: &mut TestClient, lines: &str) {
        let journal = self.elsewhere("journal.jsonl", lines.as_bytes());
        let reply = client
            .request(json!({"type": "transcript.locate", "request_id": "l1",
                            "session": {"kind": "path", "value": path_text(&journal)}, "header": false}))
            .await;
        assert_eq!(reply["type"], "transcript.locate.result", "{reply}");
    }
}

fn write_file(root: &Path, relative: &str, content: &[u8]) -> PathBuf {
    let path = relative.split('/').fold(root.to_owned(), |path, component| path.join(component));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, content).unwrap();
    path
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn stat(path: &Path) -> Value {
    json!({"type": "file.stat", "request_id": "s1", "path": path_text(path)})
}

fn read(path: &Path, version: &str, offset: u64, length: u64) -> Value {
    json!({"type": "file.read", "request_id": "f1", "path": path_text(path), "version": version, "offset": offset, "length": length})
}

fn decoded(reply: &Value) -> Vec<u8> {
    STANDARD.decode(reply["bytes"].as_str().unwrap()).unwrap()
}

#[tokio::test]
async fn stat_reports_the_version_and_size_of_a_file_under_an_agent_working_directory() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("docs/plants.png", b"hello");
    let mut client = fixture.client().await;

    let reply = client.request(stat(&image)).await;

    assert_eq!(
        reply,
        json!({"type": "file.stat.result", "request_id": "s1", "status": "file", "version": HELLO_VERSION, "size": 5})
    );
}

#[tokio::test]
async fn read_returns_chunks_of_the_requested_version() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"hello");
    let mut client = fixture.client().await;

    let first = client.request(read(&image, HELLO_VERSION, 0, 3)).await;
    let second = client.request(read(&image, HELLO_VERSION, 3, 3)).await;
    let past_end = client.request(read(&image, HELLO_VERSION, 5, 3)).await;

    assert_eq!(first["type"], "file.read.result");
    assert_eq!(first["status"], "file");
    assert_eq!((first["offset"].as_u64(), decoded(&first)), (Some(0), b"hel".to_vec()));
    assert_eq!((second["offset"].as_u64(), decoded(&second)), (Some(3), b"lo".to_vec()));
    assert_eq!(decoded(&past_end), Vec::<u8>::new());
}

#[tokio::test]
async fn read_of_another_version_reports_file_changed() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"hello");
    let mut client = fixture.client().await;

    let reply = client.request(read(&image, "stale", 0, 3)).await;

    assert_eq!(reply["type"], "error");
    assert_eq!(reply["code"], "file_changed");
    assert_eq!(reply["request_id"], "f1");
}

#[tokio::test]
async fn chunks_after_the_first_come_from_the_snapshot_even_when_the_file_is_overwritten() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"hello");
    let mut client = fixture.client().await;

    client.request(read(&image, HELLO_VERSION, 0, 3)).await;
    std::fs::write(&image, b"HELLO world").unwrap();
    let rest = client.request(read(&image, HELLO_VERSION, 3, 10)).await;
    let restarted = client.request(read(&image, HELLO_VERSION, 0, 3)).await;

    assert_eq!(decoded(&rest), b"lo".to_vec());
    assert_eq!(restarted["code"], "file_changed");
}

#[tokio::test]
async fn files_outside_every_agent_working_directory_are_denied() {
    let fixture = Fixture::start().await;
    let secret = fixture.elsewhere("notes.txt", b"hello");
    let mut client = fixture.client().await;

    let stat_reply = client.request(stat(&secret)).await;
    let read_reply = client.request(read(&secret, HELLO_VERSION, 0, 3)).await;

    assert_eq!(stat_reply["status"], "denied");
    assert_eq!(read_reply["type"], "file.read.result");
    assert_eq!(read_reply["status"], "denied");
    assert!(read_reply.get("bytes").is_none());
}

#[tokio::test]
async fn relative_paths_and_dot_dot_are_denied() {
    let fixture = Fixture::start().await;
    fixture.elsewhere("notes.txt", b"hello");
    let escaping = format!(
        "{}/../{}/notes.txt",
        path_text(fixture.project.path()),
        fixture.elsewhere.path().file_name().unwrap().to_string_lossy()
    );
    let mut client = fixture.client().await;

    let relative = client.request(json!({"type": "file.stat", "request_id": "s1", "path": "notes.txt"})).await;
    let dot_dot = client.request(json!({"type": "file.stat", "request_id": "s2", "path": escaping})).await;

    assert_eq!(relative["status"], "denied");
    assert_eq!(dot_dot["status"], "denied");
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_resolving_outside_the_working_directory_are_denied() {
    let fixture = Fixture::start().await;
    let secret = fixture.elsewhere("notes.txt", b"hello");
    let link = fixture.project.path().join("link.txt");
    std::os::unix::fs::symlink(&secret, &link).unwrap();
    std::os::unix::fs::symlink(fixture.elsewhere.path(), fixture.project.path().join("linked-folder")).unwrap();
    let mut client = fixture.client().await;

    let file_link = client.request(stat(&link)).await;
    let folder_link = client.request(stat(&fixture.project.path().join("linked-folder").join("notes.txt"))).await;

    assert_eq!(file_link["status"], "denied");
    assert_eq!(folder_link["status"], "denied");
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_inside_the_working_directory_are_read_through() {
    let fixture = Fixture::start().await;
    fixture.in_project("real/plants.png", b"hello");
    std::os::unix::fs::symlink(fixture.project.path().join("real"), fixture.project.path().join("alias")).unwrap();
    let mut client = fixture.client().await;

    let reply = client.request(stat(&fixture.project.path().join("alias").join("plants.png"))).await;

    assert_eq!(reply["status"], "file");
}

#[cfg(windows)]
#[tokio::test]
async fn windows_paths_match_the_working_directory_without_case_and_with_either_separator() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("docs/plants.png", b"hello");
    let mut client = fixture.client().await;

    let upper = client
        .request(json!({"type": "file.stat", "request_id": "s1", "path": path_text(&image).to_uppercase()}))
        .await;
    let forward = client
        .request(json!({"type": "file.stat", "request_id": "s2", "path": path_text(&image).replace('\\', "/")}))
        .await;

    assert_eq!(upper["status"], "file");
    assert_eq!(forward["status"], "file");
}

#[tokio::test]
async fn every_excluded_location_is_denied_even_under_the_working_directory() {
    let fixture = Fixture::start().await;
    let mut client = fixture.client().await;

    for location in EXCLUDED_FILE_LOCATIONS {
        let concrete = location.replace('*', "device");
        let file = fixture.in_project(&format!("{concrete}/inner"), b"hello");
        let reply = client.request(stat(&file)).await;
        assert_eq!(reply["status"], "denied", "{location}");
    }
}

#[tokio::test]
async fn excluded_locations_are_matched_without_case() {
    let fixture = Fixture::start().await;
    let key = fixture.in_project(".SSH/id_ed25519", b"hello");
    let mut client = fixture.client().await;

    let reply = client.request(stat(&key)).await;

    assert_eq!(reply["status"], "denied");
}

#[test]
fn purrdr_uploads_are_not_excluded_but_host_service_files_are() {
    assert!(!host_files::is_excluded(Path::new("/home/demo/.purrdr/uploads/photo.png")));
    assert!(host_files::is_excluded(Path::new("/home/demo/.purrdr/host-service/devices.json")));
    assert!(host_files::is_excluded(Path::new("/home/demo/.purrdr/push-relay/config.json")));
    assert!(host_files::is_excluded(Path::new("/home/demo/.ssh")));
}

#[tokio::test]
async fn a_path_mentioned_in_a_transcript_located_on_this_connection_is_allowed() {
    let fixture = Fixture::start().await;
    let image = fixture.elsewhere("shots/screen shot.png", b"hello");
    let mentioned = serde_json::to_string(&path_text(&image)).unwrap();
    let mut client = fixture.client().await;
    fixture
        .locate_journal(&mut client, &format!("{{\"type\":\"tool_use\",\"input\":{{\"file_path\":{mentioned}}}}}\n"))
        .await;

    let stat_reply = client.request(stat(&image)).await;
    let chunk = client.request(read(&image, HELLO_VERSION, 0, 5)).await;

    assert_eq!(stat_reply["status"], "file");
    assert_eq!(decoded(&chunk), b"hello".to_vec());
}

#[tokio::test]
async fn a_mentioned_path_needs_the_transcript_located_on_the_same_connection() {
    let fixture = Fixture::start().await;
    let image = fixture.elsewhere("shot.png", b"hello");
    let mentioned = serde_json::to_string(&path_text(&image)).unwrap();
    let mut locating = fixture.client().await;
    fixture.locate_journal(&mut locating, &format!("{{\"file_path\":{mentioned}}}\n")).await;
    let mut other = fixture.client().await;

    let reply = other.request(stat(&image)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn a_path_only_contained_in_a_longer_mention_is_not_allowed() {
    let fixture = Fixture::start().await;
    let image = fixture.elsewhere("shot.png", b"hello");
    let longer = serde_json::to_string(&format!("{}.bak", path_text(&image))).unwrap();
    let mut client = fixture.client().await;
    fixture.locate_journal(&mut client, &format!("{{\"file_path\":{longer}}}\n")).await;

    let reply = client.request(stat(&image)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn a_path_written_in_message_text_counts_as_mentioned() {
    let fixture = Fixture::start().await;
    let report = fixture.elsewhere("報告/screen shot.png", b"hello");
    let text = serde_json::to_string(&format!("截圖在 `{}`。", path_text(&report))).unwrap();
    let mut client = fixture.client().await;
    fixture
        .locate_journal(
            &mut client,
            &format!("{{\"type\":\"assistant\",\"message\":{{\"content\":[{{\"type\":\"text\",\"text\":{text}}}]}}}}\n"),
        )
        .await;

    let reply = client.request(stat(&report)).await;

    assert_eq!(reply["status"], "file");
}

#[tokio::test]
async fn a_path_that_message_text_only_contains_as_a_prefix_is_not_mentioned() {
    let fixture = Fixture::start().await;
    let image = fixture.elsewhere("shot.png", b"hello");
    let text = serde_json::to_string(&format!("See {}.bak and {}x/a.png", path_text(&image), path_text(&image))).unwrap();
    let mut client = fixture.client().await;
    fixture.locate_journal(&mut client, &format!("{{\"text\":{text}}}\n")).await;

    let reply = client.request(stat(&image)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn mentioned_paths_still_go_through_the_excluded_locations() {
    let fixture = Fixture::start().await;
    let key = fixture.elsewhere(".ssh/id_ed25519", b"hello");
    let mentioned = serde_json::to_string(&path_text(&key)).unwrap();
    let mut client = fixture.client().await;
    fixture.locate_journal(&mut client, &format!("{{\"file_path\":{mentioned}}}\n")).await;

    let reply = client.request(stat(&key)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn stat_reports_missing_folders_and_files_over_the_limit() {
    let fixture = Fixture::start().await;
    fixture.in_project("folder/inner.txt", b"x");
    let large = fixture.in_project("large.bin", b"");
    std::fs::File::options()
        .write(true)
        .open(&large)
        .unwrap()
        .set_len(MAXIMUM_FILE_SIZE + 1)
        .unwrap();
    let mut client = fixture.client().await;

    let missing = client.request(stat(&fixture.project.path().join("missing.png"))).await;
    let folder = client.request(stat(&fixture.project.path().join("folder"))).await;
    let too_large = client.request(stat(&large)).await;

    assert_eq!(missing["status"], "missing");
    assert_eq!(folder["status"], "not_regular_file");
    assert_eq!(too_large["status"], "too_large");
    assert_eq!(too_large["size"].as_u64(), Some(MAXIMUM_FILE_SIZE + 1));
}

#[tokio::test]
async fn the_working_directory_comes_from_the_current_herdr_snapshot() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"hello");
    let mut client = fixture.client().await;

    client.request(stat(&image)).await;

    assert!(fixture.herdr.methods().iter().any(|method| method == "session.snapshot"));
}

#[tokio::test]
async fn read_only_devices_can_fetch_files() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"hello");
    let read_only = fixture.service.pair_device("iPad", true);
    let mut client = TestClient::connect_with_token(&fixture.service, Some(&read_only.device_token)).await;
    client.request(json!({"type": "hello", "request_id": "r0", "protocol_version": 1})).await;

    let reply = client.request(read(&image, HELLO_VERSION, 0, 5)).await;

    assert_eq!(decoded(&reply), b"hello".to_vec());
}

#[tokio::test]
async fn file_requests_need_the_handshake_first() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"hello");
    let mut client = TestClient::connect(&fixture.service).await;

    let reply = client.request(stat(&image)).await;

    assert_eq!(reply["code"], "handshake_required");
}

#[tokio::test]
async fn audit_log_records_path_size_and_result_without_content() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"secret-bytes");
    let denied = fixture.elsewhere("notes.txt", b"hello");
    let mut client = fixture.client().await;
    let version = client.request(stat(&image)).await["version"].as_str().unwrap().to_owned();

    client.request(read(&image, &version, 0, 4)).await;
    client.request(read(&image, &version, 4, 4)).await;
    client.request(stat(&denied)).await;

    let entries: Vec<Value> = fixture
        .service
        .audit_log()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .filter(|entry: &Value| entry["event"] == "file_access")
        .collect();
    let summary: Vec<(String, String, String, Option<u64>)> = entries
        .iter()
        .map(|entry| {
            (
                entry["operation"].as_str().unwrap().to_owned(),
                entry["path"].as_str().unwrap().to_owned(),
                entry["result"].as_str().unwrap().to_owned(),
                entry["size"].as_u64(),
            )
        })
        .collect();
    assert_eq!(
        summary,
        vec![
            ("file.stat".to_owned(), path_text(&image), "file".to_owned(), Some(12)),
            ("file.read".to_owned(), path_text(&image), "file".to_owned(), Some(12)),
            ("file.stat".to_owned(), path_text(&denied), "denied".to_owned(), None),
        ]
    );
    assert!(entries.iter().all(|entry| entry["device_id"].is_string()));
    assert!(!fixture.service.audit_log().contains("secret-bytes"));
    assert!(!fixture.service.audit_log().contains(&STANDARD.encode(b"secr")));
}
