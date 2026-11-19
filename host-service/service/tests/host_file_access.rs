//! 主機取檔的存取規則：與 app、SSH 取檔腳本共用 `protocol/host-file-access.json` 的案例。

use std::path::PathBuf;

use purrdr_host_service::host_files::{FileAccessRules, Grant, agent_written_paths};
use serde_json::Value;

fn vectors() -> Value {
    serde_json::from_str(include_str!("../../../protocol/host-file-access.json")).unwrap()
}

fn applies_here(case: &Value) -> bool {
    let platform = if cfg!(windows) { "windows" } else { "posix" };
    let for_host_service = case["only"]
        .as_array()
        .is_none_or(|only| only.iter().any(|implementation| implementation == "host-service"));
    case["platform"] == platform && for_host_service
}

#[test]
fn access_cases_match_the_app_and_the_ssh_scripts() {
    let vectors = vectors();
    let platform = if cfg!(windows) { "windows" } else { "posix" };
    let environment = &vectors["environment"][platform];
    let cases: Vec<&Value> = vectors["accessCases"].as_array().unwrap().iter().filter(|case| applies_here(case)).collect();
    assert!(cases.len() >= 10);
    for case in cases {
        let rules = FileAccessRules {
            working_directories: case["workingDirectory"].as_str().map(PathBuf::from).into_iter().collect(),
            home: environment["home"].as_str().map(PathBuf::from),
            transcripts: vec![PathBuf::from(environment["transcript"].as_str().unwrap())],
            ..FileAccessRules::default()
        };
        let mentioned = case["mentioned"].as_bool().unwrap();

        let grant = rules.grant(case["path"].as_str().unwrap(), || mentioned);

        let expected_root = case["root"].as_str().map(PathBuf::from);
        match (case["expected"].as_str().unwrap(), grant) {
            ("allowed", Some(Grant::WorkingDirectory(root))) => assert_eq!(Some(root), expected_root, "{}", case["name"]),
            ("allowed", Some(Grant::MentionedLocation)) => assert_eq!(expected_root, None, "{}", case["name"]),
            ("denied", None) => {}
            (expected, grant) => panic!("{}:預期 {expected},得到 {grant:?}", case["name"]),
        }
    }
}

#[test]
fn mention_cases_count_only_what_the_agent_wrote() {
    let vectors = vectors();
    for case in vectors["mentionCases"].as_array().unwrap() {
        let written: Vec<String> = case["lines"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|line| agent_written_paths(&serde_json::from_str(line.as_str().unwrap()).unwrap()))
            .collect();
        let path = case["path"].as_str().unwrap().to_owned();
        assert_eq!(written.contains(&path), case["mentioned"].as_bool().unwrap(), "{}:{written:?}", case["name"]);
    }
}

#[test]
fn file_checks_beyond_the_burst_are_spaced_out() {
    use purrdr_host_service::host_files::RequestPacing;
    use std::time::{Duration, Instant};
    let start = Instant::now();
    let mut pacing = RequestPacing::new(3, Duration::from_millis(100));

    let burst: Vec<Duration> = (0..5).map(|_| pacing.delay_for(start)).collect();
    let later = pacing.delay_for(start + Duration::from_secs(1));

    let milliseconds = |value: u64| Duration::from_millis(value);
    assert_eq!(
        burst,
        vec![milliseconds(0), milliseconds(0), milliseconds(0), milliseconds(100), milliseconds(200)]
    );
    assert_eq!(later, Duration::ZERO);
}
