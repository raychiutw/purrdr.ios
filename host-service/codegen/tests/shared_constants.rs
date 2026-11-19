//! schema 頂層的共用常數(主機取檔的排除清單)兩端都產生，主機服務與 app 用同一份定義(#227)。

use protocol_codegen::Protocol;
use serde_json::json;

fn protocol() -> Protocol {
    Protocol::parse(&json!({
        "x-protocol-version": 1,
        "x-excluded-file-locations": [".ssh", ".purrdr/push-*"],
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
fn schemas_without_the_list_are_rejected() {
    let missing = Protocol::parse(&json!({"x-protocol-version": 1, "$defs": {}}));

    assert!(missing.is_err());
}
