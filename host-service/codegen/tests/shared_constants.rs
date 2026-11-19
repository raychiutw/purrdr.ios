//! schema 頂層的共用常數(主機取檔的排除清單、暫存位置與大小上限)兩端都產生，主機服務與 app 用同一份定義(#227)。

use protocol_codegen::Protocol;
use serde_json::json;

fn protocol() -> Protocol {
    Protocol::parse(&json!({
        "x-protocol-version": 1,
        "x-excluded-file-locations": [".ssh", ".purrdr/push-*"],
        "x-temporary-file-locations": ["/tmp", "/var/folders"],
        "x-maximum-file-size": 26_214_400,
        "x-maximum-file-chunk": 1_048_576,
        "$defs": {}
    }))
    .unwrap()
}

#[test]
fn excluded_file_locations_become_a_rust_constant() {
    assert!(
        protocol()
            .rust()
            .contains("pub const EXCLUDED_FILE_LOCATIONS: &[&str] = &[\".ssh\", \".purrdr/push-*\"];"),
        "{}",
        protocol().rust()
    );
}

#[test]
fn excluded_file_locations_become_a_swift_constant() {
    assert!(
        protocol()
            .swift()
            .contains("public static let excludedFileLocations = [\".ssh\", \".purrdr/push-*\"]"),
        "{}",
        protocol().swift()
    );
}

#[test]
fn temporary_locations_and_size_limits_become_rust_constants() {
    let rust = protocol().rust();

    for expected in [
        "pub const TEMPORARY_FILE_LOCATIONS: &[&str] = &[\"/tmp\", \"/var/folders\"];",
        "pub const MAXIMUM_FILE_SIZE: u64 = 26214400;",
        "pub const MAXIMUM_FILE_CHUNK: u64 = 1048576;",
    ] {
        assert!(rust.contains(expected), "缺少 {expected}:\n{rust}");
    }
}

#[test]
fn temporary_locations_and_size_limits_become_swift_constants() {
    let swift = protocol().swift();

    for expected in [
        "public static let temporaryFileLocations = [\"/tmp\", \"/var/folders\"]",
        "public static let maximumFileSize = 26214400",
        "public static let maximumFileChunk = 1048576",
    ] {
        assert!(swift.contains(expected), "缺少 {expected}:\n{swift}");
    }
}

#[test]
fn schemas_without_the_list_are_rejected() {
    let missing = Protocol::parse(&json!({"x-protocol-version": 1, "$defs": {}}));

    assert!(missing.is_err());
}

#[test]
fn schemas_without_the_size_limits_are_rejected() {
    let missing = Protocol::parse(&json!({
        "x-protocol-version": 1,
        "x-excluded-file-locations": [],
        "x-temporary-file-locations": [],
        "$defs": {}
    }));

    assert!(missing.is_err());
}
