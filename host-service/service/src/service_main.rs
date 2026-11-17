//! 以命令列參數執行主機服務(`purrdr-host-service` 與 Windows 的 `purrdr-host-service-background` 共用)。

use std::process::ExitCode;

use crate::herdr_socket::{Platform, SocketEnvironment};
use crate::{HostServiceConfig, WEBSOCKET_PATH};

/// `[--port <埠>] [--session <herdr session>]`:啟動並一直執行。
pub async fn run_service(arguments: &[String]) -> ExitCode {
    let config = match HostServiceConfig::from_arguments(arguments, Platform::current(), &SocketEnvironment::from_process()) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    let herdr_socket = config.herdr_socket.native_name();
    let service = match crate::start(config).await {
        Ok(service) => service,
        Err(error) => {
            eprintln!("cannot listen: {error}");
            return ExitCode::FAILURE;
        }
    };
    println!(
        "purrdr-host-service {} listening on ws://{}{WEBSOCKET_PATH} (herdr socket {herdr_socket})",
        env!("CARGO_PKG_VERSION"),
        service.local_addr()
    );
    service.wait().await;
    ExitCode::SUCCESS
}
