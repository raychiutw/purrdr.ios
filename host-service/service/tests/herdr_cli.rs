//! 找 herdr CLI(Pane 終端機的子行程，#61):先找 PATH,自動啟動時 PATH 可能很短，再找 herdr 的安裝位置。

use std::path::Path;

use purrdr_host_service::HostServiceConfig;
use purrdr_host_service::herdr_cli::HerdrSearch;
use purrdr_host_service::herdr_socket::{Platform, SocketEnvironment};

fn touch(path: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, b"").unwrap();
}

#[test]
fn herdr_on_path_wins_over_install_locations() {
    // 以執行測試的平台組 PATH(Windows 的路徑有磁碟代號的 `:`)。
    let platform = Platform::current();
    let name = if platform == Platform::Windows { "herdr.exe" } else { "herdr" };
    let home = tempfile::tempdir().unwrap();
    let on_path = home.path().join("tools");
    touch(&on_path.join(name));
    touch(&home.path().join(".local/bin/herdr"));
    let missing = home.path().join("missing");
    let path = std::env::join_paths([missing.as_path(), on_path.as_path()]).unwrap();
    let search = HerdrSearch {
        path: Some(path.to_string_lossy().into_owned()),
        home: Some(home.path().to_string_lossy().into_owned()),
        local_app_data: None,
    };

    assert_eq!(search.locate(platform), Some(on_path.join(name)));
}

#[test]
fn unix_falls_back_to_the_herdr_install_location() {
    let home = tempfile::tempdir().unwrap();
    touch(&home.path().join(".local/bin/herdr"));
    let search = HerdrSearch {
        path: Some("/usr/bin:/bin".into()),
        home: Some(home.path().to_string_lossy().into_owned()),
        local_app_data: None,
    };

    assert_eq!(search.locate(Platform::Unix), Some(home.path().join(".local/bin/herdr")));
}

#[test]
fn windows_looks_for_herdr_exe_and_the_local_app_data_alias() {
    let local_app_data = tempfile::tempdir().unwrap();
    let alias = local_app_data.path().join("Programs").join("Herdr").join("bin").join("herdr.exe");
    touch(&alias);
    let search = HerdrSearch {
        path: Some(r"C:\purrdr\missing".into()),
        home: None,
        local_app_data: Some(local_app_data.path().to_string_lossy().into_owned()),
    };

    assert_eq!(search.locate(Platform::Windows), Some(alias));
}

#[test]
fn missing_herdr_is_not_found() {
    let search = HerdrSearch {
        path: Some("/purrdr/missing".into()),
        home: Some("/purrdr/missing-home".into()),
        local_app_data: None,
    };

    assert_eq!(search.locate(Platform::Unix), None);
}

#[test]
fn named_session_is_passed_before_the_subcommand() {
    let environment = SocketEnvironment {
        home: Some("/Users/demo".into()),
        ..SocketEnvironment::default()
    };
    let arguments = ["--session".to_owned(), "work".to_owned()];

    let named = HostServiceConfig::from_arguments(&arguments, Platform::Unix, &environment).unwrap();
    let default = HostServiceConfig::from_arguments(&[], Platform::Unix, &environment).unwrap();

    assert_eq!(named.herdr_cli.leading_arguments(), ["--session", "work"]);
    assert!(default.herdr_cli.leading_arguments().is_empty());
}
