//! `cargo run -p protocol-codegen`:由 schema 重新產生 Rust 與 Swift 協定型別。
//! `cargo run -p protocol-codegen -- --check`:只檢查產生的檔案是否最新。

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use protocol_codegen::{Protocol, RUST_OUTPUT_PATH, SCHEMA_PATH, SWIFT_OUTPUT_PATH};

fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn main() -> ExitCode {
    let check_only = std::env::args().any(|argument| argument == "--check");
    let root = repository_root();
    let schema_text = std::fs::read_to_string(root.join(SCHEMA_PATH)).expect("讀取 schema");
    let schema = serde_json::from_str(&schema_text).expect("schema 是合法 JSON");
    let protocol = match Protocol::parse(&schema) {
        Ok(protocol) => protocol,
        Err(error) => {
            eprintln!("schema 不支援:{error}");
            return ExitCode::FAILURE;
        }
    };

    let mut outdated = Vec::new();
    for (relative_path, content) in [(RUST_OUTPUT_PATH, protocol.rust()), (SWIFT_OUTPUT_PATH, protocol.swift())] {
        let path = root.join(relative_path);
        let current = std::fs::read_to_string(&path).unwrap_or_default().replace("\r\n", "\n");
        if current == content {
            continue;
        }
        if check_only {
            outdated.push(relative_path);
        } else {
            std::fs::write(&path, content).expect("寫入產生的檔案");
            println!("已更新 {relative_path}");
        }
    }
    if outdated.is_empty() {
        ExitCode::SUCCESS
    } else {
        eprintln!("產生的檔案不是最新，請執行 cargo run -p protocol-codegen:{outdated:?}");
        ExitCode::FAILURE
    }
}
