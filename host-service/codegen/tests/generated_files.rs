//! 產生的 Rust 與 Swift 型別必須跟 schema 同步(協定只改 schema,再重新產生)。

use std::path::Path;

use protocol_codegen::{Protocol, RUST_OUTPUT_PATH, SCHEMA_PATH, SWIFT_OUTPUT_PATH};

fn repository_file(relative_path: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(relative_path);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()))
        .replace("\r\n", "\n")
}

fn protocol() -> Protocol {
    Protocol::parse(&serde_json::from_str(&repository_file(SCHEMA_PATH)).unwrap()).unwrap()
}

#[test]
fn generated_rust_types_match_schema() {
    assert!(
        repository_file(RUST_OUTPUT_PATH) == protocol().rust(),
        "{RUST_OUTPUT_PATH} 不是最新，請執行 cargo run -p protocol-codegen"
    );
}

#[test]
fn generated_swift_types_match_schema() {
    assert!(
        repository_file(SWIFT_OUTPUT_PATH) == protocol().swift(),
        "{SWIFT_OUTPUT_PATH} 不是最新，請執行 cargo run -p protocol-codegen"
    );
}
