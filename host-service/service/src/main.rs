//! `purrdr-host-service [--port <埠>] [--session <herdr session>]`

use std::process::ExitCode;

use purrdr_host_service::herdr_socket::{Platform, SocketEnvironment};
use purrdr_host_service::{HostServiceConfig, WEBSOCKET_PATH};

#[tokio::main]
async fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let config = match HostServiceConfig::from_arguments(&arguments, Platform::current(), &SocketEnvironment::from_process()) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    let herdr_socket = config.herdr_socket.native_name();
    let service = match purrdr_host_service::start(config).await {
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
