//! `install`／`uninstall`／`status` 子命令：接上真正的系統與終端機。

use std::io::{BufRead, Write};
use std::process::ExitCode;

use super::system::ProcessHostSystem;
use super::{HostEnvironment, InstallCommand, InstallError, InstallOptions, Installer};
use crate::herdr_socket::SocketEnvironment;

/// 執行子命令並回傳結束碼。
pub async fn run_command(command: InstallCommand) -> ExitCode {
    let environment = match HostEnvironment::from_process() {
        Ok(environment) => environment,
        Err(error) => return fail(&error),
    };
    let source_directory = environment.current_executable.parent().map(|parent| parent.to_path_buf()).unwrap_or_default();
    let mut installer = Installer::new(environment, ProcessHostSystem);
    match command {
        InstallCommand::Install {
            port,
            herdr_session,
            assume_yes,
        } => {
            let options = InstallOptions {
                port,
                herdr_session,
                source_directory,
            };
            let confirm = |notice: &str| {
                println!("{notice}");
                assume_yes || ask("Continue? [y/N] ")
            };
            match installer.install(&options, confirm) {
                Ok(installed) => {
                    println!("Installed. The host service starts at login and is served at {}.", installed.https_address);
                    ExitCode::SUCCESS
                }
                Err(error) => fail(&error),
            }
        }
        InstallCommand::Uninstall => match installer.uninstall() {
            Ok(uninstalled) => {
                for warning in &uninstalled.warnings {
                    eprintln!("warning: {warning}");
                }
                println!("Uninstalled.");
                ExitCode::SUCCESS
            }
            Err(error) => fail(&error),
        },
        InstallCommand::Status => {
            println!("{}", installer.status(&SocketEnvironment::from_process()).await);
            ExitCode::SUCCESS
        }
    }
}

fn fail(error: &InstallError) -> ExitCode {
    eprintln!("{error}");
    ExitCode::FAILURE
}

fn ask(prompt: &str) -> bool {
    print!("{prompt}");
    let _ = std::io::stdout().flush();
    let mut answer = String::new();
    std::io::stdin().lock().read_line(&mut answer).is_ok() && matches!(answer.trim(), "y" | "Y" | "yes")
}
