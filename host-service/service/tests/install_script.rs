//! 一行安裝腳本(#198):`curl -fsSL …/install.sh | sh`、PowerShell 的 `irm …/install.ps1 | iex`。
//!
//! 以真的 `sh`／`powershell.exe` 跑 repo 裡的腳本，下載來源指向暫存的「Release 資料夾」(不連網路)。
//! 壓縮檔裡的主機服務是這支測試執行檔本身：帶 `PURRDR_FAKE_HOST_SERVICE_RECORD` 環境變數執行時，
//! 把收到的參數與旁邊的檔案寫進紀錄檔就結束，所以不會真的安裝。因此這個測試不用 libtest(`harness = false`)。

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use sha2::{Digest, Sha256};
use tempfile::TempDir;

const RECORD_VARIABLE: &str = "PURRDR_FAKE_HOST_SERVICE_RECORD";
/// 設了這個變數，假的主機服務就把它的值印到 stderr 並以 1 結束(模擬安裝失敗)。
const FAILURE_VARIABLE: &str = "PURRDR_FAKE_HOST_SERVICE_FAILURE";
const FAILURE_REASON: &str = "tailscale serve already uses HTTPS 443 for another service:\n  / -> http://127.0.0.1:8765\nNext: install on HTTPS 8443 instead";

fn scripts_directory() -> PathBuf {
    // 交叉編譯到別台執行時以 `PURRDR_HOST_SERVICE_PACKAGE_DIR` 指定 `host-service/service`。
    std::env::var_os("PURRDR_HOST_SERVICE_PACKAGE_DIR")
        .map_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")), PathBuf::from)
        .join("../install")
}

/// 這台機器該下載的 Release 檔名(獨立於腳本的對照：作業系統與架構 → Rust target)。
fn expected_asset() -> String {
    let target = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "aarch64-apple-darwin",
        ("macos", "x86_64") => "x86_64-apple-darwin",
        ("linux", "x86_64") => "x86_64-unknown-linux-musl",
        ("linux", "aarch64") => "aarch64-unknown-linux-musl",
        ("windows", _) => "x86_64-pc-windows-msvc",
        other => panic!("沒有對應的 Release:{other:?}"),
    };
    let extension = if cfg!(windows) { "zip" } else { "tar.gz" };
    format!("purrdr-host-service-{target}.{extension}")
}

fn executable_names() -> Vec<&'static str> {
    if cfg!(windows) {
        vec!["purrdr-host-service.exe", "purrdr-host-service-background.exe"]
    } else {
        vec!["purrdr-host-service"]
    }
}

fn sha256(path: &Path) -> String {
    Sha256::digest(std::fs::read(path).unwrap()).iter().map(|byte| format!("{byte:02x}")).collect()
}

fn run_ok(command: &mut Command) {
    let output = command.output().unwrap();
    assert!(output.status.success(), "{command:?}: {output:?}");
}

/// 一個暫存的 Release:壓縮檔(內含假的主機服務)與 `SHA256SUMS`。
struct Release {
    root: TempDir,
}

impl Release {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let staging = root.path().join("staging");
        let release = root.path().join("release");
        std::fs::create_dir_all(&staging).unwrap();
        std::fs::create_dir_all(&release).unwrap();
        let fake = std::env::current_exe().unwrap();
        for name in executable_names() {
            std::fs::copy(&fake, staging.join(name)).unwrap();
        }
        let archive = release.join(expected_asset());
        if cfg!(windows) {
            run_ok(Command::new("powershell.exe").args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                &format!("Compress-Archive -Path '{}\\*' -DestinationPath '{}'", staging.display(), archive.display()),
            ]));
        } else {
            run_ok(Command::new("tar").arg("-czf").arg(&archive).arg("-C").arg(&staging).arg("."));
        }
        let release = Self { root };
        release.write_checksums(&sha256(&archive));
        release
    }

    fn directory(&self) -> PathBuf {
        self.root.path().join("release")
    }

    /// 寫 `SHA256SUMS`:這台機器的壓縮檔是 `digest`,另外放一個別的平台的項目(腳本要挑對那一行)。
    fn write_checksums(&self, digest: &str) {
        let other = "0".repeat(64);
        let contents = format!("{other}  purrdr-host-service-other-target.tar.gz\n{digest}  {}\n", expected_asset());
        std::fs::write(self.directory().join("SHA256SUMS"), contents).unwrap();
    }
}

/// 一次執行：暫存資料夾(腳本下載解壓用)與紀錄檔。
struct Run {
    output: Output,
    temporary: TempDir,
    record: PathBuf,
    _record_directory: TempDir,
}

impl Run {
    fn record(&self) -> Option<String> {
        std::fs::read_to_string(&self.record).ok()
    }

    fn temporary_is_empty(&self) -> bool {
        std::fs::read_dir(self.temporary.path()).unwrap().next().is_none()
    }
}

/// 照使用者的一行指令執行：POSIX 把腳本從 stdin 餵給 `sh`;Windows 以 scriptblock 執行(可帶參數)。
fn run_script(release: &Release, arguments: &[&str]) -> Run {
    run_script_with(release, arguments, &[])
}

/// 照使用者的一行指令執行，另外設定 `variables`。
fn run_script_with(release: &Release, arguments: &[&str], variables: &[(&str, &str)]) -> Run {
    let temporary = tempfile::tempdir().unwrap();
    let record_directory = tempfile::tempdir().unwrap();
    let record = record_directory.path().join("record.txt");
    let mut command = if cfg!(windows) {
        let script = scripts_directory().join("install.ps1");
        let quoted: Vec<String> = arguments.iter().map(|argument| format!("'{argument}'")).collect();
        let mut command = Command::new("powershell.exe");
        command.args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &format!(
                "& ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '{}'))) {}",
                script.display(),
                quoted.join(" ")
            ),
        ]);
        command.stdin(Stdio::null());
        command
    } else {
        let script = std::fs::File::open(scripts_directory().join("install.sh")).unwrap();
        let mut command = Command::new("sh");
        command.arg("-s").arg("--").args(arguments).stdin(script);
        command
    };
    command
        .env("PURRDR_HOST_SERVICE_DOWNLOAD_URL", release.directory())
        .env("TMPDIR", temporary.path())
        .env("TEMP", temporary.path())
        .env("TMP", temporary.path())
        .env(RECORD_VARIABLE, &record)
        .env_remove("PURRDR_HOST_SERVICE_VERSION")
        .env_remove(FAILURE_VARIABLE);
    for (name, value) in variables {
        command.env(name, value);
    }
    let output = command.output().unwrap();
    Run {
        output,
        temporary,
        record,
        _record_directory: record_directory,
    }
}

fn installs_verified_archive_with_arguments() {
    let release = Release::new();

    let run = run_script(&release, &["--yes", "--port", "47999"]);

    assert!(run.output.status.success(), "{:?}", run.output);
    let record = run.record().expect("沒有執行壓縮檔裡的主機服務");
    let mut lines = record.lines();
    assert_eq!(lines.next(), Some("install --yes --port 47999"));
    let siblings: Vec<&str> = lines.collect();
    for name in executable_names() {
        assert!(siblings.contains(&name), "解壓後缺 {name}:{siblings:?}");
    }
    assert!(run.temporary_is_empty(), "暫存資料夾沒清掉");
}

fn stderr(run: &Run) -> String {
    String::from_utf8_lossy(&run.output.stderr).into_owned()
}

fn checksum_mismatch_aborts_without_running_or_leaving_files() {
    let release = Release::new();
    release.write_checksums(&"f".repeat(64));

    let run = run_script(&release, &["--yes"]);

    assert!(!run.output.status.success(), "{:?}", run.output);
    let message = stderr(&run);
    for expected in ["checksum mismatch", "nothing was installed", "Next:"] {
        assert!(message.contains(expected), "缺少 {expected:?}:\n{message}");
    }
    assert_eq!(run.record(), None, "checksum 不符還執行了主機服務");
    assert!(run.temporary_is_empty(), "暫存資料夾沒清掉");
}

fn missing_checksum_entry_aborts() {
    let release = Release::new();
    std::fs::write(
        release.directory().join("SHA256SUMS"),
        format!("{}  purrdr-host-service-other-target.tar.gz\n", "0".repeat(64)),
    )
    .unwrap();

    let run = run_script(&release, &["--yes"]);

    assert!(!run.output.status.success(), "{:?}", run.output);
    assert_eq!(run.record(), None);
    assert!(run.temporary_is_empty(), "暫存資料夾沒清掉");
}

fn install_command_for_rerun_is_passed_to_the_host_service() {
    let release = Release::new();

    let run = run_script(&release, &["--yes"]);

    let record = run.record().expect("沒有執行壓縮檔裡的主機服務");
    let expected = if cfg!(windows) {
        "rerun: & ([scriptblock]::Create((irm https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.ps1)))"
    } else {
        "rerun: curl -fsSL https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.sh | sh -s --"
    };
    assert!(record.lines().any(|line| line == expected), "{record}");
}

fn pinned_version_is_shown_quoted_in_the_rerun_command() {
    let release = Release::new();
    let version = "0.4.0'; echo pwned #";

    let run = run_script_with(&release, &["--yes"], &[("PURRDR_HOST_SERVICE_VERSION", version)]);

    let record = run.record().expect("沒有執行壓縮檔裡的主機服務");
    let expected = if cfg!(windows) {
        "rerun: $env:PURRDR_HOST_SERVICE_VERSION = '0.4.0''; echo pwned #'; & ([scriptblock]::Create((irm https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.ps1)))"
    } else {
        r"rerun: curl -fsSL https://github.com/raychiutw/purrdr.ios/releases/latest/download/install.sh | PURRDR_HOST_SERVICE_VERSION='0.4.0'\''; echo pwned #' sh -s --"
    };
    assert!(record.lines().any(|line| line == expected), "{record}");
}

fn failed_install_keeps_the_host_service_reason_and_points_to_it() {
    let release = Release::new();

    let run = run_script_with(&release, &["--yes"], &[(FAILURE_VARIABLE, FAILURE_REASON)]);

    assert!(!run.output.status.success(), "{:?}", run.output);
    let message = stderr(&run);
    assert!(message.contains(FAILURE_REASON.lines().last().unwrap()), "主機服務印出的原因不見了:\n{message}");
    assert!(message.contains("/ -> http://127.0.0.1:8765"), "{message}");
    assert!(message.contains("see the reason and next step above"), "{message}");
    assert!(!message.contains("install exited with"), "{message}");
    assert!(run.temporary_is_empty(), "暫存資料夾沒清掉");
}

fn unreachable_download_says_what_failed_and_what_to_do() {
    let release = Release::new();
    let missing = release.root.path().join("no-such-release");

    let run = run_script_with(&release, &["--yes"], &[("PURRDR_HOST_SERVICE_DOWNLOAD_URL", missing.to_str().unwrap())]);

    assert!(!run.output.status.success(), "{:?}", run.output);
    let message = stderr(&run);
    for expected in ["download failed", "SHA256SUMS", "Next:"] {
        assert!(message.contains(expected), "缺少 {expected:?}:\n{message}");
    }
    assert_eq!(run.record(), None);
}

/// 假的主機服務：參數一行、重跑指令一行(`rerun: …`)，接著是執行檔所在資料夾的檔名(排序)。
fn fake_host_service(record: &str) -> std::process::ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let directory = std::env::current_exe().unwrap().parent().unwrap().to_path_buf();
    let mut names: Vec<String> = std::fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let rerun = std::env::var("PURRDR_HOST_SERVICE_INSTALL_COMMAND").unwrap_or_default();
    std::fs::write(record, format!("{}\nrerun: {rerun}\n{}\n", arguments.join(" "), names.join("\n"))).unwrap();
    if let Ok(reason) = std::env::var(FAILURE_VARIABLE) {
        eprintln!("{reason}");
        return std::process::ExitCode::FAILURE;
    }
    std::process::ExitCode::SUCCESS
}

type TestCase = (&'static str, fn());

fn main() -> std::process::ExitCode {
    if let Ok(record) = std::env::var(RECORD_VARIABLE) {
        return fake_host_service(&record);
    }
    let tests: Vec<TestCase> = vec![
        ("installs_verified_archive_with_arguments", installs_verified_archive_with_arguments),
        (
            "checksum_mismatch_aborts_without_running_or_leaving_files",
            checksum_mismatch_aborts_without_running_or_leaving_files,
        ),
        ("missing_checksum_entry_aborts", missing_checksum_entry_aborts),
        (
            "install_command_for_rerun_is_passed_to_the_host_service",
            install_command_for_rerun_is_passed_to_the_host_service,
        ),
        (
            "pinned_version_is_shown_quoted_in_the_rerun_command",
            pinned_version_is_shown_quoted_in_the_rerun_command,
        ),
        (
            "failed_install_keeps_the_host_service_reason_and_points_to_it",
            failed_install_keeps_the_host_service_reason_and_points_to_it,
        ),
        (
            "unreachable_download_says_what_failed_and_what_to_do",
            unreachable_download_says_what_failed_and_what_to_do,
        ),
    ];
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let filters: Vec<&String> = arguments.iter().filter(|argument| !argument.starts_with('-')).collect();
    let selected: Vec<&TestCase> = tests
        .iter()
        .filter(|(name, _)| filters.is_empty() || filters.iter().any(|filter| name.contains(filter.as_str())))
        .collect();
    println!("\nrunning {} tests", selected.len());
    let mut failures = Vec::new();
    for (name, test) in &selected {
        let outcome = std::panic::catch_unwind(test);
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
