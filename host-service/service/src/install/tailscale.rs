//! 安裝流程裡的 Tailscale:前置條件檢查與 `tailscale serve` 設定。

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

/// `tailscale serve` 的 proxy 目標(官方文件：proxy 只支援 `http://127.0.0.1`)。
pub(super) fn serve_target(port: u16) -> String {
    format!("http://127.0.0.1:{port}")
}
