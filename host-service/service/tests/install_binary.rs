//! 執行檔的 install／uninstall／status 子命令(#62)。只跑不改系統的情境：家目錄是暫存資料夾。

mod install_support;

use std::process::{Command, Output};

use install_support::TempDirectory;

/// 以暫存家目錄執行主機服務的執行檔。
fn run(home: &TempDirectory, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_purrdr-host-service"))
        .args(arguments)
        .env("HOME", &home.0)
        .env("USERPROFILE", &home.0)
        .env_remove("XDG_CONFIG_HOME")
        .env("HERDR_SOCKET_PATH", "purrdr-binary-test-missing-socket")
        .output()
        .unwrap()
}

#[test]
fn status_reports_not_installed_without_changing_home() {
    let home = TempDirectory::new("binary-status");

    let output = run(&home, &["status"]);

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{output:?}");
    assert!(stdout.contains("host service: not installed"), "{stdout}");
    assert!(stdout.contains("herdr: not running"), "{stdout}");
    assert_eq!(std::fs::read_dir(&home.0).unwrap().count(), 0);
}

#[test]
fn uninstall_without_install_says_so() {
    let home = TempDirectory::new("binary-uninstall");

    let output = run(&home, &["uninstall"]);

    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("not installed"), "{output:?}");
}

#[test]
fn invalid_install_arguments_exit_with_usage_error() {
    let home = TempDirectory::new("binary-arguments");

    let output = run(&home, &["install", "--bind", "0.0.0.0"]);

    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("unknown argument: --bind"), "{output:?}");
    assert_eq!(std::fs::read_dir(&home.0).unwrap().count(), 0);
}

#[test]
fn windows_background_executable_is_built_alongside() {
    assert!(std::path::Path::new(env!("CARGO_BIN_EXE_purrdr-host-service-background")).is_file());
}

/// 一行安裝腳本與 app 的更新提示都靠它認版本(#198)。
#[test]
fn version_flag_prints_version_without_touching_home() {
    let home = TempDirectory::new("binary-version");

    for flag in ["--version", "-V"] {
        let output = run(&home, &[flag]);

        assert!(output.status.success(), "{output:?}");
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            format!("purrdr-host-service {}\n", env!("CARGO_PKG_VERSION"))
        );
    }
    assert_eq!(std::fs::read_dir(&home.0).unwrap().count(), 0);
}
