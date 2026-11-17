//! 安裝流程對作業系統的接縫：執行 tailscale、launchctl、systemctl、reg 等固定程式。

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// 程式執行完的結果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

/// 安裝流程用到的系統操作;測試以假系統取代。
pub trait HostSystem {
    /// 執行程式並取得輸出;程式不存在時回 `Err`。
    fn run(&mut self, program: &str, arguments: &[String]) -> std::io::Result<CommandOutput>;
    /// 執行程式並接上終端機(它可能印出網址並等待使用者),回傳是否成功。
    fn run_attached(&mut self, program: &str, arguments: &[String]) -> std::io::Result<bool>;
    /// 在背景啟動程式，不等它結束。
    fn spawn_detached(&mut self, program: &str, arguments: &[String]) -> std::io::Result<()>;
    /// 這個行程結束後刪除資料夾，再刪除仍是空的 `empty_directories`(Windows 不能刪除執行中的執行檔)。
    fn remove_directory_after_exit(&mut self, directory: &Path, empty_directories: &[PathBuf]) -> std::io::Result<()>;
}

/// 真正執行程式的系統。這是主機服務裡唯一會執行子行程的地方(`no_command_execution` 測試把關)，
/// 只由本機的 install／uninstall／status 指令使用，WebSocket 連線碰不到。
pub struct ProcessHostSystem;

#[cfg(windows)]
mod windows_flags {
    pub const DETACHED_PROCESS: u32 = 0x0000_0008;
    pub const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;
}

impl HostSystem for ProcessHostSystem {
    fn run(&mut self, program: &str, arguments: &[String]) -> std::io::Result<CommandOutput> {
        let output = Command::new(program).args(arguments).stdin(Stdio::null()).output()?;
        Ok(CommandOutput {
            success: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    fn run_attached(&mut self, program: &str, arguments: &[String]) -> std::io::Result<bool> {
        Ok(Command::new(program).args(arguments).status()?.success())
    }

    fn spawn_detached(&mut self, program: &str, arguments: &[String]) -> std::io::Result<()> {
        let mut command = Command::new(program);
        command.args(arguments).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(windows_flags::DETACHED_PROCESS | windows_flags::CREATE_NEW_PROCESS_GROUP);
        }
        command.spawn().map(drop)
    }

    #[cfg(windows)]
    fn remove_directory_after_exit(&mut self, directory: &Path, empty_directories: &[PathBuf]) -> std::io::Result<()> {
        use std::os::windows::process::CommandExt;
        // 等這個行程結束(約 2 秒)再刪;rmdir 不加 /s 只刪空資料夾。
        let mut script = format!("ping -n 3 127.0.0.1 >nul & rmdir /s /q \"{}\"", directory.display());
        for empty in empty_directories {
            script.push_str(&format!(" & rmdir \"{}\" 2>nul", empty.display()));
        }
        Command::new("cmd.exe")
            .raw_arg(format!("/d /s /c \"{script}\""))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(windows_flags::CREATE_NO_WINDOW | windows_flags::CREATE_NEW_PROCESS_GROUP)
            .spawn()
            .map(drop)
    }

    /// Unix 可以刪除執行中的執行檔，直接刪。
    #[cfg(not(windows))]
    fn remove_directory_after_exit(&mut self, directory: &Path, empty_directories: &[PathBuf]) -> std::io::Result<()> {
        std::fs::remove_dir_all(directory)?;
        for empty in empty_directories {
            let _ = std::fs::remove_dir(empty);
        }
        Ok(())
    }
}
