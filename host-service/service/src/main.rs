//! `purrdr-host-service [--port <埠>] [--session <herdr session>]`
//! `purrdr-host-service install [--port <埠>] [--session <herdr session>] [--yes]`、`uninstall`、`status`

use std::process::ExitCode;

use purrdr_host_service::install::{self, InstallCommand};

#[tokio::main]
async fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if let Some(command) = InstallCommand::parse(&arguments) {
        return match command {
            Ok(command) => install::run_command(command).await,
            Err(message) => {
                eprintln!("{message}");
                ExitCode::from(2)
            }
        };
    }
    purrdr_host_service::run_service(&arguments).await
}
