//! 安裝流程對作業系統的接縫：執行 tailscale、launchctl、systemctl、reg 等固定程式。

use std::path::{Path, PathBuf};

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
