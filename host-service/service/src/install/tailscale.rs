//! 安裝流程裡的 Tailscale:前置條件檢查與 `tailscale serve` 設定。

use std::collections::BTreeMap;

use serde::Deserialize;

use super::system::HostSystem;
use super::{InstallError, InstallPlatform};

/// `tailscale serve` 對外的 HTTPS 埠。
const HTTPS_PORT: u16 = 443;

/// 找到的 tailscale CLI。
pub(super) struct Tailscale {
    program: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Status {
    backend_state: String,
    #[serde(rename = "Self")]
    self_node: Option<SelfNode>,
    current_tailnet: Option<CurrentTailnet>,
    cert_domains: Option<Vec<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct SelfNode {
    #[serde(rename = "DNSName")]
    dns_name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct CurrentTailnet {
    #[serde(rename = "MagicDNSEnabled")]
    magic_dns_enabled: bool,
}

impl Tailscale {
    /// 依序試 PATH 上的 `tailscale` 與各平台的預設安裝位置。
    pub(super) fn locate(system: &mut impl HostSystem, platform: InstallPlatform) -> Result<Tailscale, InstallError> {
        let candidates: &[&str] = match platform {
            InstallPlatform::MacOs => &["tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"],
            InstallPlatform::Linux => &["tailscale"],
            InstallPlatform::Windows => &["tailscale", r"C:\Program Files\Tailscale\tailscale.exe"],
        };
        candidates
            .iter()
            .find(|program| system.run(program, &["version".into()]).is_ok_and(|output| output.success))
            .map(|program| Tailscale { program: (*program).into() })
            .ok_or(InstallError::TailscaleMissing)
    }

    /// 確認已連上 tailnet、MagicDNS 與 HTTPS Certificates 已啟用，回傳這台主機的 FQDN。
    pub(super) fn host_name(&self, system: &mut impl HostSystem) -> Result<String, InstallError> {
        let output = self.run(system, &["status", "--json"])?;
        let status: Status = serde_json::from_str(&output).map_err(|error| InstallError::Tailscale(format!("unexpected tailscale status: {error}")))?;
        if status.backend_state != "Running" {
            return Err(InstallError::TailscaleNotRunning(status.backend_state));
        }
        if !status.current_tailnet.is_some_and(|tailnet| tailnet.magic_dns_enabled) {
            return Err(InstallError::MagicDnsDisabled);
        }
        if status.cert_domains.unwrap_or_default().is_empty() {
            return Err(InstallError::HttpsCertificatesDisabled);
        }
        let host_name = status.self_node.map(|node| node.dns_name.trim_end_matches('.').to_owned()).unwrap_or_default();
        if host_name.is_empty() {
            return Err(InstallError::Tailscale("tailscale status has no DNS name for this machine".into()));
        }
        Ok(host_name)
    }

    /// 把 HTTPS 443 轉到主機服務。
    pub(super) fn serve(&self, system: &mut impl HostSystem, port: u16) -> Result<(), InstallError> {
        let arguments = vec!["serve".into(), "--bg".into(), format!("--https={HTTPS_PORT}"), serve_target(port)];
        let succeeded = system
            .run_attached(&self.program, &arguments)
            .map_err(|error| InstallError::Tailscale(error.to_string()))?;
        if succeeded { Ok(()) } else { Err(InstallError::ServeFailed) }
    }

    /// HTTPS 443 目前的 proxy 設定(路徑 → 目標);沒有設定時是空的。
    pub(super) fn https_handlers(&self, system: &mut impl HostSystem) -> Result<BTreeMap<String, String>, InstallError> {
        let output = self.run(system, &["serve", "status", "--json"])?;
        let output = output.trim();
        let config: ServeConfig = if output.is_empty() {
            ServeConfig::default()
        } else {
            serde_json::from_str(output).map_err(|_| InstallError::Tailscale(format!("unexpected tailscale serve status: {output}")))?
        };
        let suffix = format!(":{HTTPS_PORT}");
        Ok(config
            .web
            .unwrap_or_default()
            .into_iter()
            .filter(|(host_port, _)| host_port.ends_with(&suffix))
            .flat_map(|(_, web)| web.handlers.unwrap_or_default())
            .map(|(path, handler)| (path, handler.proxy.unwrap_or_else(|| "(not a proxy)".into())))
            .collect())
    }

    /// 移除 HTTPS 443 的設定，但只在它仍是安裝時設的那一個時才移除。
    pub(super) fn remove_serve(&self, system: &mut impl HostSystem, port: u16) -> Result<(), InstallError> {
        let handlers = self.https_handlers(system)?;
        if handlers.is_empty() {
            return Ok(());
        }
        if handlers != BTreeMap::from([("/".to_owned(), serve_target(port))]) {
            return Err(InstallError::ServeChanged(describe(&handlers)));
        }
        self.run(system, &[&format!("--https={HTTPS_PORT}"), "off"]).map(|_| ())
    }

    fn run(&self, system: &mut impl HostSystem, arguments: &[&str]) -> Result<String, InstallError> {
        let arguments: Vec<String> = arguments.iter().map(|argument| (*argument).to_owned()).collect();
        let output = system
            .run(&self.program, &arguments)
            .map_err(|error| InstallError::Tailscale(error.to_string()))?;
        if !output.success {
            return Err(InstallError::Tailscale(format!("tailscale {} failed: {}", arguments.join(" "), output.stderr.trim())));
        }
        Ok(output.stdout)
    }
}

/// `tailscale serve status --json` 裡用得到的部分。
#[derive(Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ServeConfig {
    web: Option<BTreeMap<String, WebServer>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct WebServer {
    handlers: Option<BTreeMap<String, Handler>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Handler {
    proxy: Option<String>,
}

/// 例如 `/ → http://127.0.0.1:3000`。
pub(super) fn describe(handlers: &BTreeMap<String, String>) -> String {
    handlers.iter().map(|(path, target)| format!("{path} -> {target}")).collect::<Vec<_>>().join(", ")
}

/// `tailscale serve` 的 proxy 目標(官方文件：proxy 只支援 `http://127.0.0.1`)。
pub(super) fn serve_target(port: u16) -> String {
    format!("http://127.0.0.1:{port}")
}
