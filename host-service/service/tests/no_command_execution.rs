//! 主機服務不提供任意指令執行、不呼叫 `herdr remote-api-bridge`(ADR-0010):直接連 herdr socket。
//! Pane 終端機(#61)會以子行程執行 `herdr terminal session control`,屆時只對那個模組放寬。

use std::path::{Path, PathBuf};

const FORBIDDEN: [&str; 5] = ["remote-api-bridge", "std::process::Command", "tokio::process", "Command::new", "process::Stdio"];

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

#[test]
fn service_source_never_spawns_processes_or_uses_remote_api_bridge() {
    let mut files = Vec::new();
    rust_files(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
    assert!(files.len() >= 3, "沒有掃到原始碼，路徑可能錯了");

    let violations: Vec<String> = files
        .iter()
        .flat_map(|file| {
            let source = std::fs::read_to_string(file).unwrap();
            FORBIDDEN
                .iter()
                .filter(|pattern| source.contains(*pattern))
                .map(|pattern| format!("{}: {pattern}", file.display()))
                .collect::<Vec<_>>()
        })
        .collect();

    assert!(violations.is_empty(), "{violations:?}");
}
