//! herdr CLI:Pane 終端機以子行程執行 `herdr terminal session control`(ADR-0010 唯一會執行的 herdr CLI)。

use std::path::{Path, PathBuf};

use crate::herdr_socket::Platform;

/// 找 herdr 執行檔的位置。
#[derive(Debug, Clone, Default)]
pub struct HerdrSearch {
    /// `PATH`。
    pub path: Option<String>,
    /// `HOME`。
    pub home: Option<String>,
    /// `LOCALAPPDATA`(Windows)。
    pub local_app_data: Option<String>,
}

impl HerdrSearch {
    /// 目前行程的環境;Unix 另外找 Homebrew 與 `/usr/local/bin`(自動啟動時 PATH 只有系統目錄)。
    pub fn from_process(platform: Platform) -> Self {
        let variable = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        let mut path = variable("PATH");
        if platform == Platform::Unix {
            path = Some([path.as_deref().unwrap_or_default(), "/opt/homebrew/bin", "/usr/local/bin"].join(":"));
        }
        HerdrSearch {
            path,
            home: variable("HOME"),
            local_app_data: variable("LOCALAPPDATA"),
        }
    }

    /// 依序找 PATH、herdr 的安裝位置(Unix `~/.local/bin`、`~/bin`;Windows `%LOCALAPPDATA%\Programs\Herdr\bin`)。
    pub fn locate(&self, platform: Platform) -> Option<PathBuf> {
        let (separator, name) = match platform {
            Platform::Unix => (':', "herdr"),
            Platform::Windows => (';', "herdr.exe"),
        };
        let path_directories = self
            .path
            .iter()
            .flat_map(|path| path.split(separator))
            .filter(|directory| !directory.is_empty())
            .map(PathBuf::from);
        let install_directories: Vec<PathBuf> = match platform {
            Platform::Unix => self
                .home
                .iter()
                .flat_map(|home| [Path::new(home).join(".local").join("bin"), Path::new(home).join("bin")])
                .collect(),
            Platform::Windows => self
                .local_app_data
                .iter()
                .map(|local| Path::new(local).join("Programs").join("Herdr").join("bin"))
                .collect(),
        };
        path_directories
            .chain(install_directories)
            .map(|directory| directory.join(name))
            .find(|candidate| candidate.is_file())
    }
}

/// 執行 herdr CLI 的方式。
#[derive(Debug, Clone)]
pub struct HerdrCli {
    /// `None`:每次執行時才找(herdr 可能在主機服務啟動後才安裝)。
    program: Option<PathBuf>,
    leading_arguments: Vec<String>,
}

impl HerdrCli {
    /// 每次執行時才找 herdr;`session` 以 `--session` 放在子指令前。
    pub fn search(session: Option<&str>) -> Self {
        HerdrCli {
            program: None,
            leading_arguments: session
                .filter(|name| !name.is_empty())
                .map(|name| vec!["--session".to_owned(), name.to_owned()])
                .unwrap_or_default(),
        }
    }

    /// 固定的執行檔與子指令前的參數(測試的假 herdr CLI)。
    pub fn at_path(program: PathBuf, leading_arguments: Vec<String>) -> Self {
        HerdrCli {
            program: Some(program),
            leading_arguments,
        }
    }

    /// 子指令前的參數。
    pub fn leading_arguments(&self) -> &[String] {
        &self.leading_arguments
    }

    /// 要執行的檔案;找不到時回 `herdr`,由執行失敗回報。
    pub(crate) fn program(&self) -> PathBuf {
        self.program.clone().unwrap_or_else(|| {
            let platform = Platform::current();
            HerdrSearch::from_process(platform).locate(platform).unwrap_or_else(|| PathBuf::from("herdr"))
        })
    }
}
