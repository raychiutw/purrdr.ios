//! Windows 登入時自動啟動的主機服務：與 `purrdr-host-service` 相同，但不開 console 視窗(#62)。

#![cfg_attr(windows, windows_subsystem = "windows")]

use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    purrdr_host_service::run_service(&arguments).await
}
