//! 登入後自動啟動:macOS LaunchAgent。

use std::path::PathBuf;

use super::system::HostSystem;
use super::{InstallError, InstallPlatform, ServiceLayout};

/// LaunchAgent 的 label(依 bundle id)。
pub(super) const LAUNCH_AGENT_LABEL: &str = "com.raychiu.purrdr.host-service";

/// 自動啟動的登記檔(macOS plist);沒有檔案的平台回 None。
pub(super) fn registration_file(layout: &ServiceLayout) -> Option<PathBuf> {
    match layout.platform {
        InstallPlatform::MacOs => Some(layout.home.join("Library/LaunchAgents").join(format!("{LAUNCH_AGENT_LABEL}.plist"))),
        _ => None,
    }
}

/// 寫好登記檔之後，向系統登記並立即啟動。
pub(super) fn register(system: &mut impl HostSystem, layout: &ServiceLayout, service_arguments: &[String]) -> Result<(), InstallError> {
    let plist = registration_file(layout).expect("macOS 有 plist");
    std::fs::write(&plist, launch_agent_plist(layout, service_arguments)).map_err(InstallError::io)?;
    let domain = gui_domain(system)?;
    run_checked(system, "launchctl", &["bootstrap".into(), domain, plist.display().to_string()])
}

fn gui_domain(system: &mut impl HostSystem) -> Result<String, InstallError> {
    let output = system.run("id", &["-u".into()]).map_err(|error| InstallError::Autostart(error.to_string()))?;
    Ok(format!("gui/{}", output.stdout.trim()))
}

fn run_checked(system: &mut impl HostSystem, program: &str, arguments: &[String]) -> Result<(), InstallError> {
    let output = system
        .run(program, arguments)
        .map_err(|error| InstallError::Autostart(format!("{program}: {error}")))?;
    if output.success {
        Ok(())
    } else {
        Err(InstallError::Autostart(format!("{program} {} failed: {}", arguments.join(" "), output.stderr.trim())))
    }
}

fn launch_agent_plist(layout: &ServiceLayout, service_arguments: &[String]) -> String {
    let program_arguments: String = std::iter::once(layout.executable().display().to_string())
        .chain(service_arguments.iter().cloned())
        .map(|argument| format!("\n        <string>{}</string>", xml_escape(&argument)))
        .collect();
    let log = xml_escape(&layout.log_file().display().to_string());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>{program_arguments}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{log}</string>
    <key>StandardErrorPath</key>
    <string>{log}</string>
</dict>
</plist>
"#
    )
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}
