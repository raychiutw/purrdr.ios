//! 訊息文字中的主機路徑辨識(#229):與 app 的 `HostPathMention` 共用 `protocol/host-path-mentions.json` 的案例。

use purrdr_host_service::host_path_mentions;
use serde_json::Value;

#[test]
fn recognizes_the_same_paths_as_the_app() {
    let vectors: Value = serde_json::from_str(include_str!("../../../protocol/host-path-mentions.json")).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 20);
    for case in cases {
        let expected: Vec<String> = case["paths"].as_array().unwrap().iter().map(|path| path.as_str().unwrap().to_owned()).collect();
        assert_eq!(host_path_mentions::paths(case["text"].as_str().unwrap()), expected, "{}", case["name"]);
    }
}
