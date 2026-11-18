//! 安裝相關子命令的參數、主機資訊與真正執行程式的系統介面(#62)。

use std::time::{Duration, Instant};

use purrdr_host_service::install::system::{HostSystem, ProcessHostSystem};
use purrdr_host_service::install::{HostEnvironment, InstallCommand, InstallError, InstallPlatform};

fn arguments(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn install_subcommands_are_parsed() {
    assert_eq!(
        InstallCommand::parse(&arguments("install")),
        Some(Ok(InstallCommand::Install {
            port: 47_820,
            herdr_session: None,
            assume_yes: false
        }))
    );
    assert_eq!(
        InstallCommand::parse(&arguments("install --port 47999 --session work --yes")),
        Some(Ok(InstallCommand::Install {
            port: 47_999,
            herdr_session: Some("work".into()),
            assume_yes: true
        }))
    );
    assert_eq!(InstallCommand::parse(&arguments("uninstall")), Some(Ok(InstallCommand::Uninstall)));
    assert_eq!(InstallCommand::parse(&arguments("status")), Some(Ok(InstallCommand::Status)));
}

#[test]
fn other_arguments_are_left_to_the_service_or_rejected() {
    assert_eq!(InstallCommand::parse(&[]), None);
    assert_eq!(InstallCommand::parse(&arguments("--port 47999")), None);
    for text in [
        "install --bind 0.0.0.0",
        "install --port",
        "install --port x",
        "uninstall --force",
        "status extra",
    ] {
        assert!(matches!(InstallCommand::parse(&arguments(text)), Some(Err(_))), "{text}");
    }
}

#[test]
fn home_is_userprofile_on_windows_and_home_elsewhere() {
    let variables = |name: &str| match name {
        "HOME" => Some("/home/demo".to_owned()),
        "USERPROFILE" => Some(r"C:\Users\demo".to_owned()),
        "USERNAME" | "USER" => Some("demo".to_owned()),
        _ => None,
    };

    let windows = HostEnvironment::resolve(InstallPlatform::Windows, variables, "x.exe".into()).unwrap();
    let linux = HostEnvironment::resolve(InstallPlatform::Linux, variables, "x".into()).unwrap();
    let missing = HostEnvironment::resolve(InstallPlatform::MacOs, |_| None, "x".into());

    assert_eq!(windows.home, std::path::PathBuf::from(r"C:\Users\demo"));
    assert_eq!(linux.home, std::path::PathBuf::from("/home/demo"));
    assert_eq!(windows.user_name.as_deref(), Some("demo"));
    assert!(matches!(missing, Err(InstallError::Io(_))));
}

#[test]
fn process_system_runs_programs_and_reports_missing_ones() {
    let mut system = ProcessHostSystem;
    let this_test_binary = std::env::current_exe().unwrap().display().to_string();

    let listed = system.run(&this_test_binary, &arguments("--list")).unwrap();
    let missing = system.run("purrdr-no-such-program", &[]);

    assert!(listed.success);
    assert!(
        listed.stdout.contains("process_system_runs_programs_and_reports_missing_ones"),
        "{}",
        listed.stdout
    );
    assert!(missing.is_err());
}

#[test]
fn process_system_removes_directory_once_this_process_lets_go() {
    let root = std::env::temp_dir().join(format!("purrdr-deferred-removal-{}", std::process::id()));
    let directory = root.join("host-service");
    std::fs::create_dir_all(directory.join("bin")).unwrap();
    std::fs::write(directory.join("bin/file"), "x").unwrap();

    ProcessHostSystem.remove_directory_after_exit(&directory, std::slice::from_ref(&root)).unwrap();

    let deadline = Instant::now() + Duration::from_secs(30);
    while root.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    assert!(!root.exists(), "{} 還在", root.display());
}
