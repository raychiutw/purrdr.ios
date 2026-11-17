//! 主機上的管理指令(與執行中的主機服務共用 `devices.json`):
//! - `pair [--read-only] [--address <https 位址>]`:顯示 QR code、HTTPS 位址與一次性配對碼
//! - `devices`:列出裝置與最後連線時間
//! - `revoke <裝置 ID>`:撤銷裝置
//!
//! 每個指令都接受 `--state-dir <資料夾>`(預設 `~/.purrdr/host-service`)。

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use qrcode::QrCode;
use qrcode::render::unicode::Dense1x2;

use crate::audit_log::{AuditEvent, AuditLog, RevokedBy};
use crate::device_store::{DeviceStore, PAIRING_CODE_LIFETIME, RevokeFailure};
use crate::herdr_socket::{Platform, SocketEnvironment};
use crate::state_directory::resolve_state_directory;


const USAGE: &str = "usage: purrdr-host-service pair [--read-only] [--address <https address>] | devices | revoke <device id>  [--state-dir <dir>]";

#[derive(Default)]
struct Options {
    state_directory: Option<PathBuf>,
    address: Option<String>,
    read_only: bool,
    positionals: Vec<String>,
}

impl Options {
    fn parse(arguments: &[String]) -> Result<Options, String> {
        let mut options = Options::default();
        let mut remaining = arguments.iter();
        while let Some(argument) = remaining.next() {
            let mut value = || remaining.next().cloned().ok_or_else(|| format!("{argument} needs a value"));
            match argument.as_str() {
                "--state-dir" => options.state_directory = Some(PathBuf::from(value()?)),
                "--address" => options.address = Some(value()?),
                "--read-only" => options.read_only = true,
                flag if flag.starts_with("--") => return Err(format!("unknown argument: {flag}\n{USAGE}")),
                positional => options.positionals.push(positional.to_owned()),
            }
        }
        Ok(options)
    }
}

/// 執行管理指令，回傳要印到 stdout 的內容;錯誤時回傳要印到 stderr 的訊息。
pub fn run(arguments: &[String], platform: Platform, environment: &SocketEnvironment, now: SystemTime) -> Result<String, String> {
    let (command, rest) = arguments.split_first().ok_or(USAGE)?;
    let options = Options::parse(rest)?;
    let state_directory = options
        .state_directory
        .clone()
        .or_else(|| resolve_state_directory(platform, environment))
        .ok_or("cannot find the home directory; pass --state-dir")?;
    let accepts_only = |allowed_positionals: usize, allows_pair_flags: bool| {
        if options.positionals.len() != allowed_positionals || (!allows_pair_flags && (options.read_only || options.address.is_some())) {
            Err(USAGE.to_owned())
        } else {
            Ok(())
        }
    };
    match command.as_str() {
        "pair" => {
            accepts_only(0, true)?;
            pair(&state_directory, options.address, options.read_only, now)
        }
        "devices" => {
            accepts_only(0, false)?;
            devices(&state_directory)
        }
        "revoke" => {
            accepts_only(1, false)?;
            revoke(&state_directory, &options.positionals[0], now)
        }
        _ => Err(USAGE.to_owned()),
    }
}

fn pair(state_directory: &Path, address: Option<String>, read_only: bool, now: SystemTime) -> Result<String, String> {
    let address = match address {
        Some(address) => address,
        None => saved_address(state_directory).ok_or("no HTTPS address configured; pass --address https://<host>.<tailnet>.ts.net")?,
    };
    let address = address.trim_end_matches('/').to_owned();
    let host = address.strip_prefix("https://").unwrap_or_default();
    if host.is_empty() || host.contains(['/', ' ', '?', '#']) {
        return Err(format!("address must look like https://<host>.<tailnet>.ts.net, got {address}"));
    }

    let pairing_code = DeviceStore::new(state_directory)
        .create_pairing_code(read_only, now)
        .map_err(|error| format!("cannot save pairing code in {}: {error}", state_directory.display()))?;
    AuditLog::new(state_directory).record(AuditEvent::PairingCodeCreated { read_only }, now);

    let invitation = format!("purrdr://pair?address={}&code={}", percent_encoded(&address), pairing_code.code);
    let qr_code = QrCode::new(invitation.as_bytes()).map_err(|error| format!("cannot render QR code: {error}"))?;
    // 終端機多半是深色背景：反轉顏色，讓 QR code 以淺底深點呈現。
    let rendered = qr_code
        .render::<Dense1x2>()
        .dark_color(Dense1x2::Light)
        .light_color(Dense1x2::Dark)
        .quiet_zone(true)
        .build();
    let access = if read_only { "read-only" } else { "full access" };
    let minutes = PAIRING_CODE_LIFETIME.as_secs() / 60;
    let mut output = String::new();
    let _ = writeln!(output, "{rendered}");
    let _ = writeln!(output, "Scan with Purrdr (Add host → HTTPS), or enter manually:");
    let _ = writeln!(output, "  Address:      {address}");
    let _ = writeln!(output, "  Pairing code: {}  ({access}; single use, expires in {minutes} minutes)", pairing_code.code);
    let _ = writeln!(output, "  Link:         {invitation}");
    Ok(output)
}

/// 安裝流程寫在 `config.json` 的 `https_address`。
fn saved_address(state_directory: &Path) -> Option<String> {
    let text = std::fs::read_to_string(state_directory.join("config.json")).ok()?;
    let config: serde_json::Value = serde_json::from_str(&text).ok()?;
    config["https_address"].as_str().map(str::to_owned)
}

fn percent_encoded(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (byte as char).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

fn devices(state_directory: &Path) -> Result<String, String> {
    let devices = DeviceStore::new(state_directory)
        .devices()
        .map_err(|error| format!("cannot read devices in {}: {error}", state_directory.display()))?;
    if devices.is_empty() {
        return Ok("No paired devices. Run `purrdr-host-service pair` to add one.\n".to_owned());
    }
    let time = |time: SystemTime| humantime::format_rfc3339_seconds(time).to_string();
    let mut output = format!(
        "{:<16}  {:<9}  {:<7}  {:<20}  {:<20}  NAME\n",
        "DEVICE ID", "ACCESS", "STATUS", "PAIRED", "LAST CONNECTED"
    );
    for device in devices {
        let _ = writeln!(
            output,
            "{:<16}  {:<9}  {:<7}  {:<20}  {:<20}  {}",
            device.device_id,
            if device.read_only { "read-only" } else { "full" },
            if device.revoked_at.is_some() { "revoked" } else { "active" },
            time(device.paired_at),
            device.last_connected_at.map(time).unwrap_or_else(|| "never".to_owned()),
            device.name
        );
    }
    Ok(output)
}

fn revoke(state_directory: &Path, device_id: &str, now: SystemTime) -> Result<String, String> {
    match DeviceStore::new(state_directory).revoke(device_id, now) {
        Ok(device) => {
            AuditLog::new(state_directory).record(
                AuditEvent::Revoked {
                    device_id: device.device_id.clone(),
                    by: RevokedBy::Host,
                },
                now,
            );
            Ok(format!(
                "Revoked {} ({}). Its open connections close on their next message.\n",
                device.device_id, device.name
            ))
        }
        Err(RevokeFailure::UnknownDevice) => Err(format!("no device with id {device_id}; run `purrdr-host-service devices`")),
        Err(RevokeFailure::Storage(error)) => Err(format!("cannot update devices in {}: {error}", state_directory.display())),
    }
}
