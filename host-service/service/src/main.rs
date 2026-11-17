//! `purrdr-host-service [--port <埠>] [--session <herdr session>] [--state-dir <資料夾>]`:執行主機服務。
//! `purrdr-host-service pair | devices | revoke …`:管理連線配對與裝置(見 `management`)。

use std::process::ExitCode;
use std::time::SystemTime;

use purrdr_host_service::herdr_socket::{Platform, SocketEnvironment};
use purrdr_host_service::{HostServiceConfig, WEBSOCKET_PATH, management};

#[tokio::main]
async fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("pair" | "devices" | "revoke") => run_management(&arguments),
        _ => serve(&arguments).await,
    }
}

fn run_management(arguments: &[String]) -> ExitCode {
    match management::run(arguments, Platform::current(), &SocketEnvironment::from_process(), SystemTime::now()) {
        Ok(output) => {
            print!("{output}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(2)
        }
    }
}

async fn serve(arguments: &[String]) -> ExitCode {
    let config = match HostServiceConfig::from_arguments(arguments, Platform::current(), &SocketEnvironment::from_process()) {
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
        "purrdr-host-service {} listening on http://{} (WebSocket {WEBSOCKET_PATH}, herdr socket {herdr_socket})",
        env!("CARGO_PKG_VERSION"),
        service.local_addr()
    );
    service.wait().await;
    ExitCode::SUCCESS
}
