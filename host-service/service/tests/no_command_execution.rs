//! 主機服務不提供任意指令執行、不呼叫 `herdr remote-api-bridge`(ADR-0010):直接連 herdr socket。
//! 例外只有本機的安裝指令(#62)執行 tailscale、launchctl 等固定程式(`install/system.rs`),
//! 以及 Pane 終端機(#61)以子行程執行 `herdr terminal session control|observe`(`pane_terminal.rs`)。

use std::path::{Path, PathBuf};

const FORBIDDEN: [&str; 5] = ["remote-api-bridge", "std::process::Command", "tokio::process", "Command::new", "process::Stdio"];
/// 可以執行子行程的檔案(相對 `src/`)。
const PROCESS_ALLOWED: [&str; 2] = ["install/system.rs", "pane_terminal.rs"];

fn rust_files(directory: &Path, files: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_files(&path, files);
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            files.push(path);
        }
    }
}

fn source_directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

#[test]
fn service_source_never_spawns_processes_or_uses_remote_api_bridge() {
    let mut files = Vec::new();
    rust_files(&source_directory(), &mut files);
    assert!(files.len() >= 3, "沒有掃到原始碼，路徑可能錯了");
    for allowed in PROCESS_ALLOWED {
        assert!(source_directory().join(allowed).is_file(), "例外的檔案 {allowed} 不存在，更新 PROCESS_ALLOWED");
    }

    let violations: Vec<String> = files
        .iter()
        .flat_map(|file| {
            let source = std::fs::read_to_string(file).unwrap();
            let allowed = PROCESS_ALLOWED.iter().any(|allowed| file.ends_with(allowed));
            FORBIDDEN
                .iter()
                .filter(|pattern| source.contains(*pattern) && !(allowed && **pattern != "remote-api-bridge"))
                .map(|pattern| format!("{}: {pattern}", file.display()))
                .collect::<Vec<_>>()
        })
        .collect();

    assert!(violations.is_empty(), "{violations:?}");
}

#[test]
fn pane_terminal_only_runs_herdr_terminal_session() {
    let source = std::fs::read_to_string(source_directory().join("pane_terminal.rs")).unwrap();

    assert_eq!(source.matches("Command::new(").count(), 1, "只能有一個子行程");
    assert!(source.contains("Command::new(herdr.program())"));
    assert!(source.contains(r#"["terminal", "session", if observe { "observe" } else { "control" }"#));
}

#[test]
fn websocket_connections_cannot_reach_the_installer() {
    let connection = std::fs::read_to_string(source_directory().join("connection.rs")).unwrap();

    assert!(!connection.contains("install"), "connection.rs 不能用到安裝模組");
}
