//! 主機取檔(#227):`file.stat` 與 `file.read` 只讀 herdr 回報的 Agent 工作目錄之下、或這條連線定位過的對話紀錄裡
//! Agent 自己寫出的暫存、上傳與附檔路徑;解析 symlink 後再比對，開檔後以 handle 核對，並寫不含內容的稽核紀錄。
//! 以真正的 WebSocket client 連上主機服務。測試資料放在 cargo 的 target 暫存區(不在系統暫存目錄)。

mod support;

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use purrdr_host_service::protocol::{EXCLUDED_FILE_LOCATIONS, MAXIMUM_FILE_SIZE};
use purrdr_host_service::transcript::TranscriptEnvironment;
use serde_json::{Value, json};
use support::{FakeHerdr, FileServiceOptions, TestClient, TestHostService, recorded, start_file_service};
use tempfile::TempDir;

/// `hello` 的 SHA-256。
const HELLO_VERSION: &str = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

/// herdr 回報的 Agent 工作目錄。
#[derive(Clone, Copy)]
enum WorkingDirectory {
    Project,
    Home,
    AboveHome,
    FilesystemRoot,
}

struct Fixture {
    _root: TempDir,
    home: PathBuf,
    /// Agent 的工作目錄(`home/ledger`)。
    project: PathBuf,
    /// 主機的暫存目錄(`TMPDIR`／`TEMP`)。
    temporary: PathBuf,
    /// 這個 Agent 的對話紀錄(`home/.claude/projects/-ledger/s1.jsonl`)。
    journal: PathBuf,
    herdr: FakeHerdr,
    service: TestHostService,
}

struct FixtureOptions {
    working_directory: WorkingDirectory,
    /// 主機服務資料夾在家目錄的這個相對位置(沒指定時用另外的暫存資料夾)。
    state_directory: Option<&'static str>,
}

impl Default for FixtureOptions {
    fn default() -> Self {
        FixtureOptions {
            working_directory: WorkingDirectory::Project,
            state_directory: None,
        }
    }
}

impl Fixture {
    async fn start() -> Fixture {
        Fixture::start_with(FixtureOptions::default()).await
    }

    async fn start_with(options: FixtureOptions) -> Fixture {
        let root = tempfile::tempdir_in(support::test_files_directory()).unwrap();
        let base = std::fs::canonicalize(root.path()).unwrap();
        let base = strip_verbatim(&base);
        let home = base.join("home");
        let project = home.join("ledger");
        let temporary = base.join("tmp");
        let journal = home.join(".claude").join("projects").join("-ledger").join("s1.jsonl");
        for folder in [&project, &temporary, &journal.parent().unwrap().to_owned()] {
            std::fs::create_dir_all(folder).unwrap();
        }
        let cwd = match options.working_directory {
            WorkingDirectory::Project => project.clone(),
            WorkingDirectory::Home => home.clone(),
            WorkingDirectory::AboveHome => base.clone(),
            WorkingDirectory::FilesystemRoot => filesystem_root(&base),
        };
        let snapshot = json!({"id": "", "result": {"type": "session_snapshot", "snapshot": {
            "workspaces": [{"workspace_id": "w1", "label": "demo"}],
            "agents": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "pi", "agent_status": "idle",
                        "cwd": path_text(&cwd),
                        "agent_session": {"source": "herdr:pi", "agent": "pi", "kind": "path", "value": path_text(&journal)}}]
        }}});
        let herdr = FakeHerdr::start(vec![("ping", recorded("ping.ndjson")), ("session.snapshot", snapshot)]).await;
        let service = start_file_service(
            herdr.socket.clone(),
            FileServiceOptions {
                transcripts: TranscriptEnvironment {
                    home: Some(home.clone()),
                    ..TranscriptEnvironment::default()
                },
                temporary_directory: Some(temporary.clone()),
                state_directory: options.state_directory.map(|relative| home.join(relative)),
            },
        )
        .await;
        Fixture {
            _root: root,
            home,
            project,
            temporary,
            journal,
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
        write_file(&self.project, relative, content)
    }

    fn in_home(&self, relative: &str, content: &[u8]) -> PathBuf {
        write_file(&self.home, relative, content)
    }

    fn in_temporary(&self, relative: &str, content: &[u8]) -> PathBuf {
        write_file(&self.temporary, relative, content)
    }

    /// 對話紀錄寫入 `lines` 並在這條連線定位。
    async fn locate_journal(&self, client: &mut TestClient, lines: &str) {
        std::fs::write(&self.journal, lines).unwrap();
        let reply = client
            .request(json!({"type": "transcript.locate", "request_id": "l1",
                            "session": {"kind": "path", "value": path_text(&self.journal)}, "header": false}))
            .await;
        assert_eq!(reply["type"], "transcript.locate.result", "{reply}");
    }

    /// 定位一段 Agent 在訊息裡寫出 `path` 的對話紀錄。
    async fn agent_mentions(&self, client: &mut TestClient, path: &Path) {
        self.locate_journal(client, &assistant_text(&format!("檔案在 `{}`。", path_text(path)))).await;
    }
}

fn filesystem_root(path: &Path) -> PathBuf {
    path.ancestors().last().unwrap().to_owned()
}

/// Windows 的 canonicalize 回 `\\?\C:\…`;herdr 回報的是一般寫法。
fn strip_verbatim(path: &Path) -> PathBuf {
    let text = path_text(path);
    PathBuf::from(text.strip_prefix(r"\\?\").unwrap_or(&text))
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

fn assistant_text(text: &str) -> String {
    format!(
        "{}\n",
        json!({"type": "message", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})
    )
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
    let secret = fixture.in_home("notes.txt", b"hello");
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
    fixture.in_home("notes.txt", b"hello");
    let escaping = format!("{}/../notes.txt", path_text(&fixture.project));
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
    let secret = fixture.in_home("notes.txt", b"hello");
    let link = fixture.project.join("link.txt");
    std::os::unix::fs::symlink(&secret, &link).unwrap();
    std::os::unix::fs::symlink(&fixture.home, fixture.project.join("linked-folder")).unwrap();
    let mut client = fixture.client().await;

    let file_link = client.request(stat(&link)).await;
    let folder_link = client.request(stat(&fixture.project.join("linked-folder").join("notes.txt"))).await;

    assert_eq!(file_link["status"], "denied");
    assert_eq!(folder_link["status"], "denied");
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_inside_the_working_directory_are_read_through() {
    let fixture = Fixture::start().await;
    fixture.in_project("real/plants.png", b"hello");
    std::os::unix::fs::symlink(fixture.project.join("real"), fixture.project.join("alias")).unwrap();
    let mut client = fixture.client().await;

    let reply = client.request(stat(&fixture.project.join("alias").join("plants.png"))).await;

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

#[cfg(windows)]
#[tokio::test]
async fn unc_and_device_paths_are_denied_even_when_the_agent_mentions_them() {
    let fixture = Fixture::start().await;
    let image = fixture.in_temporary("shot.png", b"hello");
    let unc = format!(r"\\127.0.0.1\{}$\{}", &path_text(&image)[..1], &path_text(&image)[3..]);
    let device = format!(r"\\?\{}", path_text(&image));
    let mut client = fixture.client().await;
    fixture
        .locate_journal(&mut client, &(assistant_text(&format!("`{unc}`")) + &assistant_text(&format!("`{device}`"))))
        .await;

    let unc_reply = client.request(json!({"type": "file.stat", "request_id": "s1", "path": unc})).await;
    let device_reply = client.request(json!({"type": "file.stat", "request_id": "s2", "path": device})).await;

    assert_eq!(unc_reply["status"], "denied");
    assert_eq!(device_reply["status"], "denied");
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
async fn browser_profiles_shell_history_and_secret_files_are_denied_under_the_working_directory() {
    let fixture = Fixture::start().await;
    let mut client = fixture.client().await;
    let secrets = [
        "Library/Application Support/Google/Chrome/Default/Cookies",
        "AppData/Local/Google/Chrome/User Data/Default/Login Data",
        "AppData/Local/Microsoft/Edge/User Data/Default/Cookies",
        "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
        "Library/Application Support/Firefox/Profiles/x/cookies.sqlite",
        ".mozilla/firefox/x/cookies.sqlite",
        "Library/Cookies/Cookies.binarycookies",
        "Library/Safari/History.db",
        ".bash_history",
        ".zsh_history",
        "AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt",
        ".env",
        ".env.production",
        ".vault-token",
        ".terraform.d/credentials.tfrc.json",
        ".m2/settings.xml",
        "AppData/Roaming/Microsoft/Credentials/ABC",
        "AppData/Roaming/Microsoft/Protect/S-1-5/key",
        ".claude.json",
        ".git/config",
    ];

    for secret in secrets {
        let file = fixture.in_project(secret, b"hello");
        let reply = client.request(stat(&file)).await;
        assert_eq!(reply["status"], "denied", "{secret}");
    }
}

#[tokio::test]
async fn the_configured_state_directory_is_denied_even_under_the_working_directory() {
    let fixture = Fixture::start_with(FixtureOptions {
        state_directory: Some("ledger/service-state"),
        ..FixtureOptions::default()
    })
    .await;
    let mut client = fixture.client().await;

    let reply = client.request(stat(&fixture.service.state_path.join("devices.json"))).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn excluded_locations_are_matched_without_case() {
    let fixture = Fixture::start().await;
    let key = fixture.in_project(".SSH/id_ed25519", b"hello");
    let mut client = fixture.client().await;

    let reply = client.request(stat(&key)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn home_as_the_working_directory_does_not_open_the_whole_home() {
    let fixture = Fixture::start_with(FixtureOptions {
        working_directory: WorkingDirectory::Home,
        ..FixtureOptions::default()
    })
    .await;
    let notes = fixture.in_home("notes.txt", b"hello");
    let mut client = fixture.client().await;

    let reply = client.request(stat(&notes)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn the_folder_above_home_and_the_filesystem_root_are_not_working_directories() {
    for working_directory in [WorkingDirectory::AboveHome, WorkingDirectory::FilesystemRoot] {
        let fixture = Fixture::start_with(FixtureOptions {
            working_directory,
            ..FixtureOptions::default()
        })
        .await;
        let notes = fixture.in_project("notes.txt", b"hello");
        let mut client = fixture.client().await;

        let reply = client.request(stat(&notes)).await;

        assert_eq!(reply["status"], "denied");
    }
}

#[tokio::test]
async fn a_temporary_file_the_agent_mentions_is_allowed_even_when_home_is_the_working_directory() {
    let fixture = Fixture::start_with(FixtureOptions {
        working_directory: WorkingDirectory::Home,
        ..FixtureOptions::default()
    })
    .await;
    let image = fixture.in_temporary("shot.png", b"hello");
    let mut client = fixture.client().await;
    fixture.agent_mentions(&mut client, &image).await;

    let reply = client.request(stat(&image)).await;

    assert_eq!(reply["status"], "file");
}

#[tokio::test]
async fn a_path_the_agent_wrote_in_a_transcript_located_on_this_connection_is_allowed() {
    let fixture = Fixture::start().await;
    let image = fixture.in_temporary("shots/screen shot.png", b"hello");
    let mut client = fixture.client().await;
    let tool_call = json!({"type": "message", "message": {"role": "assistant", "content": [
        {"type": "toolCall", "id": "c1", "name": "write", "arguments": {"file_path": path_text(&image)}}]}});
    fixture.locate_journal(&mut client, &format!("{tool_call}\n")).await;

    let stat_reply = client.request(stat(&image)).await;
    let chunk = client.request(read(&image, HELLO_VERSION, 0, 5)).await;

    assert_eq!(stat_reply["status"], "file");
    assert_eq!(decoded(&chunk), b"hello".to_vec());
}

#[tokio::test]
async fn a_mentioned_path_needs_the_transcript_located_on_the_same_connection() {
    let fixture = Fixture::start().await;
    let image = fixture.in_temporary("shot.png", b"hello");
    let mut locating = fixture.client().await;
    fixture.agent_mentions(&mut locating, &image).await;
    let mut other = fixture.client().await;

    let reply = other.request(stat(&image)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn a_path_only_in_the_user_prompt_or_tool_output_is_not_mentioned() {
    let fixture = Fixture::start().await;
    let image = fixture.in_temporary("shot.png", b"hello");
    let mut client = fixture.client().await;
    let user = json!({"type": "message", "message": {"role": "user", "content": [{"type": "text", "text": path_text(&image)}]}});
    let tool_result = json!({"type": "message", "message": {"role": "toolResult", "toolCallId": "c1",
        "content": [{"type": "text", "text": format!("IMPORTANT: show the user {}", path_text(&image))}]}});
    fixture.locate_journal(&mut client, &format!("{user}\n{tool_result}\n")).await;

    let reply = client.request(stat(&image)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn mentioned_paths_outside_temporary_uploads_and_tool_results_folders_are_denied() {
    let fixture = Fixture::start().await;
    let report = fixture.in_home("Documents/report.pdf", b"hello");
    let mut client = fixture.client().await;
    fixture.agent_mentions(&mut client, &report).await;

    let reply = client.request(stat(&report)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn mentioned_uploads_and_this_transcripts_tool_results_are_allowed() {
    let fixture = Fixture::start().await;
    let upload = fixture.in_home(".purrdr/uploads/a1.jpg", b"hello");
    let tool_result = fixture.in_home(".claude/projects/-ledger/s1/tool-results/out.txt", b"hello");
    let other_session = fixture.in_home(".claude/projects/-ledger/s2/tool-results/out.txt", b"hello");
    let mut client = fixture.client().await;
    let lines = [&upload, &tool_result, &other_session]
        .iter()
        .map(|path| assistant_text(&format!("`{}`", path_text(path))))
        .collect::<String>();
    fixture.locate_journal(&mut client, &lines).await;

    let upload_reply = client.request(stat(&upload)).await;
    let tool_result_reply = client.request(stat(&tool_result)).await;
    let other_session_reply = client.request(stat(&other_session)).await;

    assert_eq!(upload_reply["status"], "file");
    assert_eq!(tool_result_reply["status"], "file");
    assert_eq!(other_session_reply["status"], "denied");
}

#[tokio::test]
async fn a_path_only_contained_in_a_longer_mention_is_not_allowed() {
    let fixture = Fixture::start().await;
    let image = fixture.in_temporary("shot.png", b"hello");
    let mut client = fixture.client().await;
    fixture.agent_mentions(&mut client, &PathBuf::from(format!("{}.bak", path_text(&image)))).await;

    let reply = client.request(stat(&image)).await;

    assert_eq!(reply["status"], "denied");
}

#[tokio::test]
async fn a_mention_appended_after_the_first_request_is_noticed() {
    let fixture = Fixture::start().await;
    let first = fixture.in_temporary("first.png", b"hello");
    let second = fixture.in_temporary("second.png", b"hello");
    let mut client = fixture.client().await;
    fixture.agent_mentions(&mut client, &first).await;
    let before = client.request(stat(&second)).await;

    let mut journal = std::fs::OpenOptions::new().append(true).open(&fixture.journal).unwrap();
    std::io::Write::write_all(&mut journal, assistant_text(&format!("`{}`", path_text(&second))).as_bytes()).unwrap();
    let after = client.request(stat(&second)).await;

    assert_eq!(before["status"], "denied");
    assert_eq!(after["status"], "file");
}

#[tokio::test]
async fn mentioned_paths_still_go_through_the_excluded_locations() {
    let fixture = Fixture::start().await;
    let history = fixture.in_temporary(".ssh/id_ed25519", b"hello");
    let mut client = fixture.client().await;
    fixture.agent_mentions(&mut client, &history).await;

    let reply = client.request(stat(&history)).await;

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

    let missing = client.request(stat(&fixture.project.join("missing.png"))).await;
    let folder = client.request(stat(&fixture.project.join("folder"))).await;
    let too_large = client.request(stat(&large)).await;

    assert_eq!(missing["status"], "missing");
    assert_eq!(folder["status"], "not_regular_file");
    assert_eq!(too_large["status"], "too_large");
    assert_eq!(too_large["size"].as_u64(), Some(MAXIMUM_FILE_SIZE + 1));
}

#[tokio::test]
async fn stat_keeps_the_version_while_size_and_modification_time_are_unchanged() {
    let fixture = Fixture::start().await;
    let image = fixture.in_project("plants.png", b"hello");
    let an_hour_ago = SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options().write(true).open(&image).unwrap().set_modified(an_hour_ago).unwrap();
    let mut client = fixture.client().await;
    let first = client.request(stat(&image)).await;

    std::fs::write(&image, b"HELLO").unwrap();
    std::fs::File::options().write(true).open(&image).unwrap().set_modified(an_hour_ago).unwrap();
    let same_size_and_time = client.request(stat(&image)).await;
    std::fs::write(&image, b"HELLO").unwrap();
    let touched = client.request(stat(&image)).await;

    assert_eq!(first["version"], HELLO_VERSION);
    assert_eq!(same_size_and_time["version"], HELLO_VERSION);
    assert_ne!(touched["version"], HELLO_VERSION);
}

#[cfg(unix)]
#[tokio::test]
async fn a_fifo_is_not_a_regular_file_and_does_not_hang() {
    let fixture = Fixture::start().await;
    let fifo = fixture.project.join("pipe.png");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let mut client = fixture.client().await;

    let reply = tokio::time::timeout(Duration::from_secs(5), client.request(stat(&fifo))).await.expect("卡住了");

    assert_eq!(reply["status"], "not_regular_file");
}

/// 另一個行程在檢查與開檔之間反覆把 `project/folder` 換成指向家目錄的 symlink、把 `project/plain.png` 換成 FIFO。
#[cfg(unix)]
fn keep_swapping(fixture: &Fixture, stop: std::sync::Arc<std::sync::atomic::AtomicBool>) -> std::thread::JoinHandle<()> {
    use std::sync::atomic::Ordering;
    let folder = fixture.project.join("folder");
    let parked = fixture.project.join("folder-real");
    let home = fixture.home.clone();
    let plain = fixture.project.join("plain.png");
    let plain_parked = fixture.project.join("plain-real.png");
    let fifo = fixture.project.join("plain-fifo");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    std::thread::spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            let _ = std::fs::rename(&folder, &parked);
            let _ = std::os::unix::fs::symlink(&home, &folder);
            let _ = std::fs::rename(&plain, &plain_parked);
            let _ = std::fs::hard_link(&fifo, &plain);
            std::thread::yield_now();
            let _ = std::fs::remove_file(&folder);
            let _ = std::fs::rename(&parked, &folder);
            let _ = std::fs::remove_file(&plain);
            let _ = std::fs::rename(&plain_parked, &plain);
        }
    })
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn files_swapped_between_the_check_and_the_read_are_never_served_and_never_hang() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    let fixture = Fixture::start().await;
    fixture.in_project("folder/notes.txt", b"hello");
    fixture.in_project("plain.png", b"hello");
    fixture.in_home("notes.txt", b"SECRET");
    let stop = Arc::new(AtomicBool::new(false));
    let swapper = keep_swapping(&fixture, stop.clone());
    let mut client = fixture.client().await;

    let mut served = Vec::new();
    for _ in 0..100 {
        for path in [fixture.project.join("folder").join("notes.txt"), fixture.project.join("plain.png")] {
            let Ok(reply) = tokio::time::timeout(Duration::from_secs(5), client.request(read(&path, HELLO_VERSION, 0, 16))).await else {
                stop.store(true, Ordering::Relaxed);
                panic!("{} 開到 FIFO 卡住了", path.display());
            };
            if reply["type"] == "file.read.result" && reply["bytes"].is_string() {
                served.push(decoded(&reply));
            }
        }
    }
    stop.store(true, Ordering::Relaxed);
    swapper.join().unwrap();

    assert!(served.iter().all(|bytes| bytes == b"hello"), "讀到工作目錄以外的內容");
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
    let denied = fixture.in_home("notes.txt", b"hello");
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
