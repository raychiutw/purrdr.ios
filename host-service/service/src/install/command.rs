//! `install`／`uninstall`／`status` 子命令：接上真正的系統與終端機。

use std::io::{BufRead, Write};
use std::process::ExitCode;

use super::system::ProcessHostSystem;
use super::{HostEnvironment, InstallCommand, InstallError, InstallOptions, InstallQuestion, Installer, rerun_install_command, shell_quoted};
use crate::herdr_socket::SocketEnvironment;

/// 一行安裝腳本設定的環境變數：重跑安裝的指令(不含選項)。
pub const INSTALL_COMMAND_VARIABLE: &str = "PURRDR_HOST_SERVICE_INSTALL_COMMAND";

/// 執行子命令並回傳結束碼。
pub async fn run_command(command: InstallCommand) -> ExitCode {
    let environment = match HostEnvironment::from_process() {
        Ok(environment) => environment,
        Err(error) => return fail(&error),
    };
    let source_directory = environment.current_executable.parent().map(|parent| parent.to_path_buf()).unwrap_or_default();
    // 一行安裝腳本傳入重跑用的指令;直接執行時用這支執行檔。
    let rerun_prefix = std::env::var(INSTALL_COMMAND_VARIABLE)
        .ok()
        .filter(|prefix| !prefix.trim().is_empty())
        .unwrap_or_else(|| format!("{} install", shell_quoted(&environment.current_executable, environment.platform)));
    let rerun = rerun_install_command(&rerun_prefix, &command, environment.platform);
    let mut installer = Installer::new(environment, ProcessHostSystem);
    match command {
        InstallCommand::Install {
            port,
            herdr_session,
            https_port,
            assume_yes,
        } => {
            let options = InstallOptions {
                port,
                herdr_session,
                https_port,
                source_directory,
            };
            let confirm = |question: &InstallQuestion| {
                println!("{question}");
                let prompt = match question {
                    InstallQuestion::UseAnotherHttpsPort { alternative, .. } => format!("Use HTTPS {alternative}? [y/N] "),
                    InstallQuestion::CertificateTransparency { .. } => "Continue? [y/N] ".to_owned(),
                };
                if assume_yes {
                    println!("{prompt}yes (--yes)");
                    return true;
                }
                ask(&prompt)
            };
            match installer.install(&options, confirm) {
                Ok(installed) => {
                    for warning in &installed.warnings {
                        eprintln!("warning: {warning}");
                    }
                    println!("{installed}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("{}", error.explain(&rerun));
                    ExitCode::FAILURE
                }
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
