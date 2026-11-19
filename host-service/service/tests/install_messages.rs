//! 安裝失敗與成功時給使用者看的訊息(#218):發生什麼、為什麼、下一步的完整指令。

mod install_support;

use install_support::{FQDN, FakeSystem, TestHost};
use purrdr_host_service::install::{InstallCommand, InstallError, InstallPlatform, Installer, rerun_install_command};

const RERUN: &str = "curl -fsSL https://example.test/install.sh | sh -s -- --yes";

fn assert_contains_all(message: &str, expected: &[&str]) {
    for part in expected {
        assert!(message.contains(part), "缺少 {part:?}:\n{message}");
    }
}

#[test]
fn each_failure_says_what_happened_and_ends_with_the_command_to_run_next() {
    let cases: Vec<(InstallError, &[&str])> = vec![
        (
            InstallError::TailscaleMissing,
            &["Tailscale is not installed", "https://tailscale.com/download"],
        ),
        (
            InstallError::TailscaleNotRunning("NeedsLogin".into()),
            &["not connected (state: NeedsLogin)", "tailscale up"],
        ),
        (InstallError::MagicDnsDisabled, &["MagicDNS is off", "https://login.tailscale.com/admin/dns"]),
        (
            InstallError::HttpsCertificatesDisabled,
            &["HTTPS Certificates are off", "Enable HTTPS", "https://login.tailscale.com/admin/dns"],
        ),
        (
            InstallError::ServeFailed { https_port: 8443 },
            &["tailscale serve --bg --https=8443", "sudo tailscale set --operator=$USER"],
        ),
        (
            InstallError::Autostart("systemctl --user enable failed: Failed to connect to bus".into()),
            &["start at login", "Failed to connect to bus"],
        ),
        (
            InstallError::Tailscale("tailscale serve status --json failed: boom".into()),
            &["boom", "tailscale status"],
        ),
        (InstallError::Io("permission denied".into()), &["permission denied"]),
    ];
    for (error, expected) in cases {
        let message = error.explain(RERUN);

        assert_contains_all(&message, expected);
        let next = message.lines().skip_while(|line| !line.starts_with("Next:")).collect::<Vec<_>>().join("\n");
        assert!(next.contains(RERUN), "{error:?} 的下一步沒有重跑指令:\n{message}");
    }
}

#[test]
fn taken_https_port_lists_who_uses_it_and_offers_the_full_rerun_on_a_free_port() {
    let error = InstallError::ServePortTaken {
        https_port: 443,
        handlers: "/ -> http://127.0.0.1:8765".into(),
        available: Some(8443),
    };

    let message = error.explain(RERUN);

    assert_contains_all(
        &message,
        &[
            "tailscale serve already uses HTTPS 443",
            "/ -> http://127.0.0.1:8765",
            "does not change existing tailscale serve settings",
            &format!("{RERUN} --https-port 8443"),
            "tailscale serve --https=443 off",
        ],
    );
}

#[test]
fn taken_https_port_with_no_free_candidate_asks_for_a_port_of_your_choice() {
    let error = InstallError::ServePortTaken {
        https_port: 443,
        handlers: "/ -> http://127.0.0.1:3000".into(),
        available: None,
    };

    let message = error.explain(RERUN);

    assert_contains_all(&message, &["tailscale serve status", &format!("{RERUN} --https-port <port>")]);
}

#[test]
fn rerun_command_repeats_every_given_option_including_the_https_port() {
    let command = InstallCommand::Install {
        port: 47_999,
        herdr_session: Some("work".into()),
        https_port: Some(8443),
        assume_yes: true,
    };

    let rerun = rerun_install_command("curl -fsSL https://example.test/install.sh | sh -s --", &command, InstallPlatform::Linux);

    assert_eq!(
        rerun,
        "curl -fsSL https://example.test/install.sh | sh -s -- --port 47999 --session work --yes --https-port 8443"
    );
}

#[test]
fn rerun_command_quotes_a_session_name_for_the_shell_that_runs_it() {
    let command = |session: &str| InstallCommand::Install {
        port: purrdr_host_service::DEFAULT_PORT,
        herdr_session: Some(session.into()),
        https_port: None,
        assume_yes: false,
    };

    let posix = rerun_install_command("sh -s --", &command("my work; rm -rf ~"), InstallPlatform::MacOs);
    let posix_quote = rerun_install_command("sh -s --", &command("it's"), InstallPlatform::Linux);
    let windows = rerun_install_command("& $install", &command("it's $(boom)"), InstallPlatform::Windows);

    assert_eq!(posix, "sh -s -- --session 'my work; rm -rf ~'");
    assert_eq!(posix_quote, r"sh -s -- --session 'it'\''s'");
    assert_eq!(windows, "& $install --session 'it''s $(boom)'");
}

#[test]
fn taken_https_port_suggests_the_other_port_without_repeating_the_taken_one() {
    let command = InstallCommand::Install {
        port: purrdr_host_service::DEFAULT_PORT,
        herdr_session: None,
        https_port: Some(8443),
        assume_yes: true,
    };
    let rerun = rerun_install_command("sh -s --", &command, InstallPlatform::Linux);
    let error = InstallError::ServePortTaken {
        https_port: 8443,
        handlers: "/ -> http://127.0.0.1:3000".into(),
        available: Some(8444),
    };

    let message = error.explain(&rerun);

    assert_contains_all(&message, &["sh -s -- --yes --https-port 8444", "and run:\n  sh -s -- --yes --https-port 8443"]);
    assert!(!message.contains("--https-port 8443 --https-port"), "{message}");
}

#[test]
fn success_shows_the_https_address_and_how_to_pair() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));

    let installed = installer.install(&host.options_on_https_port(47_820, 8443), |_| true).unwrap();

    let installed_binary = host.service_directory().join("bin").join("purrdr-host-service");
    assert_contains_all(
        &installed.to_string(),
        &[
            &format!("https://{FQDN}:8443"),
            &format!("{} pair", installed_binary.display()),
            "Add host",
            "HTTPS",
        ],
    );
}
