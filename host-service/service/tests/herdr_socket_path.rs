//! herdr 本機 socket 路徑解析(herdr 官方文件 socket-api「Socket paths」)。
//!
//! 順序：明確指定的 session → `HERDR_SOCKET_PATH` → `HERDR_SESSION` → 預設 session。
//! Unix 在 `~/.config/herdr/`,Windows 在 `%APPDATA%\herdr\`,named pipe 名稱是 `\\.\pipe\` 加上 socket 路徑。

use purrdr_host_service::herdr_socket::{HerdrSocket, Platform, SocketEnvironment, SocketPathError};

fn unix_environment() -> SocketEnvironment {
    SocketEnvironment {
        home: Some("/Users/demo".into()),
        ..SocketEnvironment::default()
    }
}

fn windows_environment() -> SocketEnvironment {
    SocketEnvironment {
        app_data: Some(r"C:\Users\demo\AppData\Roaming".into()),
        ..SocketEnvironment::default()
    }
}

#[test]
fn unix_default_session_socket_is_under_config_directory() {
    let socket = HerdrSocket::resolve(Platform::Unix, None, &unix_environment()).unwrap();

    assert_eq!(socket.path(), "/Users/demo/.config/herdr/herdr.sock");
    assert_eq!(socket.native_name(), "/Users/demo/.config/herdr/herdr.sock");
}

#[test]
fn unix_named_session_has_its_own_socket() {
    let socket = HerdrSocket::resolve(Platform::Unix, Some("work"), &unix_environment()).unwrap();

    assert_eq!(socket.path(), "/Users/demo/.config/herdr/sessions/work/herdr.sock");
}

#[test]
fn explicit_session_wins_over_socket_path_and_session_variables() {
    let environment = SocketEnvironment {
        socket_path: Some("/tmp/override.sock".into()),
        session: Some("from-env".into()),
        ..unix_environment()
    };

    let socket = HerdrSocket::resolve(Platform::Unix, Some("explicit"), &environment).unwrap();

    assert_eq!(socket.path(), "/Users/demo/.config/herdr/sessions/explicit/herdr.sock");
}

#[test]
fn socket_path_variable_wins_over_session_variable() {
    let environment = SocketEnvironment {
        socket_path: Some("/tmp/override.sock".into()),
        session: Some("from-env".into()),
        ..unix_environment()
    };

    let socket = HerdrSocket::resolve(Platform::Unix, None, &environment).unwrap();

    assert_eq!(socket.path(), "/tmp/override.sock");
}

#[test]
fn session_variable_selects_named_session() {
    let environment = SocketEnvironment {
        session: Some("from-env".into()),
        ..unix_environment()
    };

    let socket = HerdrSocket::resolve(Platform::Unix, None, &environment).unwrap();

    assert_eq!(socket.path(), "/Users/demo/.config/herdr/sessions/from-env/herdr.sock");
}

#[test]
fn empty_variables_are_treated_as_unset() {
    let environment = SocketEnvironment {
        socket_path: Some(String::new()),
        session: Some(String::new()),
        ..unix_environment()
    };

    let socket = HerdrSocket::resolve(Platform::Unix, None, &environment).unwrap();

    assert_eq!(socket.path(), "/Users/demo/.config/herdr/herdr.sock");
}

#[test]
fn unix_without_home_cannot_resolve_default_socket() {
    let result = HerdrSocket::resolve(Platform::Unix, None, &SocketEnvironment::default());

    assert_eq!(result.unwrap_err(), SocketPathError::MissingHome);
}

#[test]
fn windows_default_session_is_a_named_pipe_under_app_data() {
    let socket = HerdrSocket::resolve(Platform::Windows, None, &windows_environment()).unwrap();

    assert_eq!(socket.path(), r"C:\Users\demo\AppData\Roaming\herdr\herdr.sock");
    assert_eq!(socket.native_name(), r"\\.\pipe\C:\Users\demo\AppData\Roaming\herdr\herdr.sock");
}

#[test]
fn windows_named_session_pipe_matches_recorded_herdr_path() {
    // tests/PurrdrTestSupport/Fixtures/herdr-0.9.5/windows/error.server-not-running.stderr.txt 錄到的路徑。
    let socket = HerdrSocket::resolve(Platform::Windows, Some("purrdr-nosuch"), &windows_environment()).unwrap();

    assert_eq!(socket.path(), r"C:\Users\demo\AppData\Roaming\herdr\sessions\purrdr-nosuch\herdr.sock");
}

#[test]
fn windows_socket_path_variable_becomes_pipe_name() {
    let environment = SocketEnvironment {
        socket_path: Some(r"D:\herdr\custom.sock".into()),
        ..windows_environment()
    };

    let socket = HerdrSocket::resolve(Platform::Windows, None, &environment).unwrap();

    assert_eq!(socket.native_name(), r"\\.\pipe\D:\herdr\custom.sock");
}

#[test]
fn windows_without_app_data_cannot_resolve_default_socket() {
    let result = HerdrSocket::resolve(Platform::Windows, None, &SocketEnvironment::default());

    assert_eq!(result.unwrap_err(), SocketPathError::MissingAppData);
}

#[cfg(windows)]
#[test]
fn current_platform_resolves_named_pipe_from_process_environment() {
    let socket = HerdrSocket::resolve(Platform::current(), Some("purrdr-test"), &SocketEnvironment::from_process()).unwrap();

    assert!(socket.native_name().starts_with(r"\\.\pipe\"), "{}", socket.native_name());
    assert!(socket.path().ends_with(r"\herdr\sessions\purrdr-test\herdr.sock"), "{}", socket.path());
}

#[cfg(unix)]
#[test]
fn current_platform_resolves_unix_socket_from_process_environment() {
    let socket = HerdrSocket::resolve(Platform::current(), Some("purrdr-test"), &SocketEnvironment::from_process()).unwrap();

    assert!(socket.path().ends_with("/.config/herdr/sessions/purrdr-test/herdr.sock"), "{}", socket.path());
    assert_eq!(socket.native_name(), socket.path());
}
