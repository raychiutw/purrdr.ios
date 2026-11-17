//! 協定範例(protocol/examples/)以產生的 Rust 型別編解碼後不失真。
//! 同一組範例也由 Swift 的 `HostServiceProtocolExampleTests` 驗證。

use std::collections::BTreeSet;
use std::path::PathBuf;

use purrdr_host_service::protocol::{AgentStatus, ClientMessage, ErrorCode, PairRequest, PairResponse, ServerMessage};
use serde_json::Value;

fn protocol_directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../protocol")
}

/// (檔名, 內容);`client.` 開頭是 app 送出的，`server.` 開頭是主機服務送出的。
fn examples() -> Vec<(String, Value)> {
    let mut examples: Vec<(String, Value)> = std::fs::read_dir(protocol_directory().join("examples"))
        .expect("protocol/examples 存在")
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "json"))
        .map(|path| {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let text = std::fs::read_to_string(&path).unwrap();
            (name, serde_json::from_str(&text).unwrap())
        })
        .collect();
    examples.sort_by(|left, right| left.0.cmp(&right.0));
    examples
}

#[test]
fn every_example_round_trips_through_generated_types() {
    let examples = examples();
    assert!(examples.len() >= 8, "範例太少，路徑可能錯了:{}", examples.len());

    for (name, original) in examples {
        let reencoded = if name.starts_with("client.") {
            let message: ClientMessage = serde_json::from_value(original.clone()).unwrap_or_else(|error| panic!("{name}: {error}"));
            serde_json::to_value(message).unwrap()
        } else {
            let message: ServerMessage = serde_json::from_value(original.clone()).unwrap_or_else(|error| panic!("{name}: {error}"));
            serde_json::to_value(message).unwrap()
        };
        assert_eq!(reencoded, original, "{name} 編解碼後不同");
    }
}

#[test]
fn every_message_type_in_schema_has_an_example() {
    let schema: Value = serde_json::from_str(&std::fs::read_to_string(protocol_directory().join("host-service.schema.json")).unwrap()).unwrap();
    let definitions = &schema["$defs"];
    let mut schema_types = BTreeSet::new();
    for union in ["ClientMessage", "ServerMessage"] {
        for variant in definitions[union]["oneOf"].as_array().unwrap() {
            let name = variant["$ref"].as_str().unwrap().rsplit('/').next().unwrap();
            schema_types.insert(definitions[name]["properties"]["type"]["const"].as_str().unwrap().to_owned());
        }
    }

    let example_types: BTreeSet<String> = examples().iter().map(|(_, example)| example["type"].as_str().unwrap().to_owned()).collect();

    assert_eq!(example_types, schema_types);
}

#[test]
fn decoding_ignores_unknown_fields() {
    let json = r#"{"type":"agents.list","request_id":"r9","future_field":true}"#;

    let message: ClientMessage = serde_json::from_str(json).unwrap();

    assert_eq!(
        message,
        ClientMessage::AgentsList(purrdr_host_service::protocol::AgentsList { request_id: "r9".into() })
    );
}

#[test]
fn decoded_examples_carry_their_values() {
    let welcome: ServerMessage = serde_json::from_str(include_str!("../../../protocol/examples/server.welcome.json")).unwrap();
    let ServerMessage::Welcome(welcome) = welcome else { panic!("不是 welcome") };
    assert_eq!(welcome.protocol_version, 1);
    assert_eq!(welcome.herdr.protocol, 22);
    assert!(welcome.herdr.capabilities.contains(&"health_check".to_owned()));

    let result: ServerMessage = serde_json::from_str(include_str!("../../../protocol/examples/server.agents-list-result.json")).unwrap();
    let ServerMessage::AgentsListResult(result) = result else {
        panic!("不是 agents.list.result")
    };
    assert_eq!(result.agents[0].status, AgentStatus::Idle);
    assert_eq!(result.agents[1].agent, None);

    let error: ServerMessage = serde_json::from_str(include_str!("../../../protocol/examples/server.error.invalid-message.json")).unwrap();
    let ServerMessage::ErrorMessage(error) = error else { panic!("不是 error") };
    assert_eq!(error.code, ErrorCode::InvalidMessage);
    assert_eq!(error.request_id, None);
}

/// 配對與撤銷的 HTTPS 請求本文(protocol/examples/http/)。
#[test]
fn http_examples_round_trip_through_generated_types() {
    let directory = protocol_directory().join("examples/http");
    let mut count = 0;
    for entry in std::fs::read_dir(&directory).expect("protocol/examples/http 存在") {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let original: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let reencoded = match name.as_str() {
            "pair-request.json" => serde_json::to_value(serde_json::from_value::<PairRequest>(original.clone()).unwrap()).unwrap(),
            "pair-response.json" => serde_json::to_value(serde_json::from_value::<PairResponse>(original.clone()).unwrap()).unwrap(),
            error if error.starts_with("error.") => serde_json::to_value(serde_json::from_value::<ServerMessage>(original.clone()).unwrap()).unwrap(),
            other => panic!("不認得的範例 {other}"),
        };
        assert_eq!(reencoded, original, "{name} 編解碼後不同");
        count += 1;
    }
    assert_eq!(count, 3);
}

#[test]
fn only_write_messages_are_marked_as_write() {
    let decode = |name: &str| -> ClientMessage {
        serde_json::from_str(&std::fs::read_to_string(protocol_directory().join("examples").join(name)).unwrap()).unwrap()
    };

    assert!(decode("client.pane-send-keys.json").is_write());
    assert!(!decode("client.hello.json").is_write());
    assert!(!decode("client.agents-list.json").is_write());
}
