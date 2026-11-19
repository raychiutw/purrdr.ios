//! 主機服務的安裝、自動啟動與解除安裝(#62、ADR-0010):暫存家目錄加上假系統，三平台流程都在每個 CI 平台跑。

mod install_support;

use install_support::{FQDN, FakeSystem, LAUNCH_AGENT_LABEL, RUN_VALUE, SYSTEMD_UNIT, TestHost, executable_names, occupy_https_port, snapshot};
use std::time::SystemTime;

use purrdr_host_service::herdr_socket::{Platform, SocketEnvironment};
use purrdr_host_service::install::{InstallError, InstallPlatform, InstallQuestion, Installer};
use purrdr_host_service::management;
use purrdr_host_service::state_directory::default_state_directory;

const PORT: u16 = 47_820;
const PLATFORMS: [InstallPlatform; 3] = [InstallPlatform::MacOs, InstallPlatform::Linux, InstallPlatform::Windows];

#[test]
fn macos_install_starts_launch_agent_and_serves_https_through_tailscale() {
    let host = TestHost::new(InstallPlatform::MacOs);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));

    let installed = installer.install(&host.options(PORT), |_| true).unwrap();

    assert_eq!(installed.https_address, format!("https://{FQDN}"));
    let system = installer.system();
    assert!(system.state.launchd_loaded.contains(LAUNCH_AGENT_LABEL));
    assert_eq!(system.state.serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:47820");
    let plist = std::fs::read_to_string(host.home.0.join(format!("Library/LaunchAgents/{LAUNCH_AGENT_LABEL}.plist"))).unwrap();
    let installed_binary = host.service_directory().join("bin").join("purrdr-host-service");
    assert!(plist.contains(&format!("<string>{}</string>", installed_binary.display())), "{plist}");
    assert!(plist.contains("<key>RunAtLoad</key>"));
    assert_eq!(std::fs::read_to_string(&installed_binary).unwrap(), "binary purrdr-host-service");
    let config: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(host.service_directory().join("config.json")).unwrap()).unwrap();
    assert_eq!(config["https_address"], format!("https://{FQDN}"));
}

#[test]
fn linux_install_enables_systemd_user_unit_started_at_login() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));

    installer.install(&host.options(PORT), |_| true).unwrap();

    let system = installer.system();
    assert!(system.state.systemd_enabled.contains(SYSTEMD_UNIT));
    assert!(system.state.systemd_active.contains(SYSTEMD_UNIT));
    assert_eq!(system.state.serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:47820");
    let unit = std::fs::read_to_string(host.home.0.join(".config/systemd/user").join(SYSTEMD_UNIT)).unwrap();
    // systemd 引號內的反斜線要跳脫(只有在 Windows CI 跑 Linux 流程時路徑才會有反斜線)。
    let installed_binary = host.service_directory().join("bin").join("purrdr-host-service");
    let quoted_binary = installed_binary.display().to_string().replace('\\', "\\\\");
    assert!(unit.contains(&format!("ExecStart=\"{quoted_binary}\" --port 47820")), "{unit}");
    assert!(unit.contains("WantedBy=default.target"), "{unit}");
}

#[test]
fn linux_unit_goes_to_xdg_config_home_when_set() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut environment = host.environment();
    environment.xdg_config_home = Some(host.home.0.join("xdg"));
    let mut system = FakeSystem::ready(&host.home.0);
    system.systemd_user_directory = host.home.0.join("xdg/systemd/user");
    let mut installer = Installer::new(environment, system);

    installer.install(&host.options(PORT), |_| true).unwrap();

    assert!(host.home.0.join("xdg/systemd/user").join(SYSTEMD_UNIT).is_file());
    assert!(!host.home.0.join(".config").exists());
}

#[test]
fn windows_install_registers_windowless_executable_at_logon_and_starts_it() {
    let host = TestHost::new(InstallPlatform::Windows);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));

    installer.install(&host.options(PORT), |_| true).unwrap();

    let background = host.service_directory().join("bin").join("purrdr-host-service-background.exe");
    let system = installer.system();
    assert_eq!(system.state.run_values[RUN_VALUE], format!("\"{}\" --port 47820", background.display()));
    assert_eq!(
        system.state.background_processes,
        vec![vec![background.display().to_string(), "--port".into(), "47820".into()]]
    );
    assert_eq!(system.state.serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:47820");
    assert!(host.service_directory().join("bin/purrdr-host-service.exe").is_file());
}

#[test]
fn windows_uninstall_from_installed_copy_removes_files_after_it_exits() {
    let host = TestHost::new(InstallPlatform::Windows);
    let home_before = snapshot(&host.home.0);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
    installer.install(&host.options(PORT), |_| true).unwrap();
    let mut environment = host.environment();
    environment.current_executable = host.service_directory().join("bin/purrdr-host-service.exe");
    let mut installer = Installer::new(environment, FakeSystem::ready(&host.home.0));

    installer.uninstall().unwrap();

    assert_eq!(installer.system().deferred_removals, vec![host.service_directory()]);
    assert_eq!(snapshot(&host.home.0), home_before);
}

#[test]
fn missing_prerequisites_fail_with_actionable_message_and_change_nothing() {
    type Breaks = fn(&mut FakeSystem);
    let cases: [(Breaks, InstallError, &[&str]); 4] = [
        (
            |system| system.tailscale_program = None,
            InstallError::TailscaleMissing,
            &["https://tailscale.com/download"],
        ),
        (
            |system| system.backend_state = "NeedsLogin".into(),
            InstallError::TailscaleNotRunning("NeedsLogin".into()),
            &["tailscale up"],
        ),
        (
            |system| system.magic_dns = false,
            InstallError::MagicDnsDisabled,
            &["MagicDNS", "https://login.tailscale.com/admin/dns"],
        ),
        (
            |system| system.https_certificates = false,
            InstallError::HttpsCertificatesDisabled,
            &["HTTPS Certificates", "https://login.tailscale.com/admin/dns"],
        ),
    ];
    for platform in PLATFORMS {
        for (breaks, expected, hints) in &cases {
            let host = TestHost::new(platform);
            let mut system = FakeSystem::ready(&host.home.0);
            breaks(&mut system);
            let system_before = system.state.clone();
            let mut installer = Installer::new(host.environment(), system);

            let error = installer.install(&host.options(PORT), |_| true).unwrap_err();

            assert_eq!(&error, expected);
            for hint in *hints {
                assert!(error.to_string().contains(hint), "{platform:?}: {error} 缺少 {hint}");
            }
            assert!(snapshot(&host.home.0).is_empty(), "{platform:?}: {expected:?}");
            assert_eq!(installer.system().state, system_before);
        }
    }
}

#[test]
fn macos_finds_tailscale_cli_inside_the_app_when_not_on_path() {
    let host = TestHost::new(InstallPlatform::MacOs);
    let mut system = FakeSystem::ready(&host.home.0);
    system.tailscale_program = Some("/Applications/Tailscale.app/Contents/MacOS/Tailscale".into());
    let mut installer = Installer::new(host.environment(), system);

    installer.install(&host.options(PORT), |_| true).unwrap();

    assert!(installer.system().state.serve.contains_key(&format!("{FQDN}:443")));
}

#[test]
fn install_warns_that_host_name_enters_certificate_transparency_and_stops_when_declined() {
    let host = TestHost::new(InstallPlatform::Linux);
    let system = FakeSystem::ready(&host.home.0);
    let system_before = system.state.clone();
    let mut installer = Installer::new(host.environment(), system);
    let mut notice = String::new();

    let error = installer
        .install(&host.options(PORT), |question| {
            notice = question.to_string();
            false
        })
        .unwrap_err();

    assert_eq!(error, InstallError::Declined);
    assert!(notice.contains(FQDN), "{notice}");
    assert!(notice.contains("Certificate Transparency"), "{notice}");
    assert!(snapshot(&host.home.0).is_empty());
    assert_eq!(installer.system().state, system_before);
}

#[test]
fn taken_443_asks_to_use_8443_and_declining_changes_nothing() {
    for platform in PLATFORMS {
        let host = TestHost::new(platform);
        let mut system = FakeSystem::ready(&host.home.0);
        occupy_https_port(&mut system, 443, "http://127.0.0.1:8765");
        let system_before = system.state.clone();
        let mut installer = Installer::new(host.environment(), system);
        let mut questions = Vec::new();

        let error = installer
            .install(&host.options(PORT), |question| {
                questions.push(question.clone());
                false
            })
            .unwrap_err();

        assert_eq!(
            questions,
            [InstallQuestion::UseAnotherHttpsPort {
                taken_port: 443,
                handlers: "/ -> http://127.0.0.1:8765".into(),
                alternative: 8443
            }],
            "{platform:?}"
        );
        assert_eq!(
            error,
            InstallError::ServePortTaken {
                https_port: 443,
                handlers: "/ -> http://127.0.0.1:8765".into(),
                available: Some(8443)
            }
        );
        assert!(snapshot(&host.home.0).is_empty(), "{platform:?}");
        assert_eq!(installer.system().state, system_before);
    }
}

#[test]
fn taken_443_moves_to_the_first_free_https_port_when_accepted() {
    for platform in PLATFORMS {
        let host = TestHost::new(platform);
        let mut system = FakeSystem::ready(&host.home.0);
        occupy_https_port(&mut system, 443, "http://127.0.0.1:8765");
        occupy_https_port(&mut system, 8443, "http://127.0.0.1:3000");
        let mut installer = Installer::new(host.environment(), system);

        let installed = installer.install(&host.options(PORT), |_| true).unwrap();

        assert_eq!(installed.https_address, format!("https://{FQDN}:10000"), "{platform:?}");
        let serve = &installer.system().state.serve;
        assert_eq!(serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:8765");
        assert_eq!(serve[&format!("{FQDN}:8443")]["/"], "http://127.0.0.1:3000");
        assert_eq!(serve[&format!("{FQDN}:10000")]["/"], "http://127.0.0.1:47820");
    }
}

#[test]
fn no_free_https_port_fails_without_asking_or_changing_anything() {
    let host = TestHost::new(InstallPlatform::Windows);
    let mut system = FakeSystem::ready(&host.home.0);
    for https_port in [443, 8443, 10_000] {
        occupy_https_port(&mut system, https_port, "http://127.0.0.1:3000");
    }
    let system_before = system.state.clone();
    let mut installer = Installer::new(host.environment(), system);
    let mut asked_to_move = false;

    let error = installer
        .install(&host.options(PORT), |question| {
            asked_to_move |= matches!(question, InstallQuestion::UseAnotherHttpsPort { .. });
            true
        })
        .unwrap_err();

    assert!(!asked_to_move);
    assert!(
        matches!(
            error,
            InstallError::ServePortTaken {
                https_port: 443,
                available: None,
                ..
            }
        ),
        "{error:?}"
    );
    assert!(snapshot(&host.home.0).is_empty());
    assert_eq!(installer.system().state, system_before);
}

#[test]
fn taken_https_port_given_explicitly_is_not_replaced_by_another_port() {
    let host = TestHost::new(InstallPlatform::MacOs);
    let mut system = FakeSystem::ready(&host.home.0);
    occupy_https_port(&mut system, 8443, "http://127.0.0.1:3000");
    let system_before = system.state.clone();
    let mut installer = Installer::new(host.environment(), system);

    let error = installer.install(&host.options_on_https_port(PORT, 8443), |_| true).unwrap_err();

    assert_eq!(
        error,
        InstallError::ServePortTaken {
            https_port: 8443,
            handlers: "/ -> http://127.0.0.1:3000".into(),
            available: Some(443)
        }
    );
    assert_eq!(installer.system().state, system_before);
}

#[test]
fn failure_after_changes_rolls_everything_back() {
    type Breaks = fn(&mut FakeSystem);
    let cases: [Breaks; 2] = [|system| system.serve_denied = true, |system| system.autostart_fails = true];
    for platform in PLATFORMS {
        for breaks in cases {
            let host = TestHost::new(platform);
            let mut system = FakeSystem::ready(&host.home.0);
            existing_files_and_settings(&host, &mut system);
            breaks(&mut system);
            let home_before = snapshot(&host.home.0);
            let system_before = system.state.clone();
            let mut installer = Installer::new(host.environment(), system);

            let result = installer.install(&host.options(PORT), |_| true);

            let error = result.unwrap_err();
            if platform == InstallPlatform::Linux && matches!(error, InstallError::ServeFailed { .. }) {
                assert!(error.to_string().contains("sudo tailscale set --operator=$USER"), "{error}");
            }
            assert_eq!(snapshot(&host.home.0), home_before, "{platform:?}: {error:?}");
            assert_eq!(installer.system().state, system_before, "{platform:?}: {error:?}");
        }
    }
}

#[test]
fn installing_again_updates_in_place_and_keeps_paired_devices() {
    for platform in PLATFORMS {
        let host = TestHost::new(platform);
        let home_before = snapshot(&host.home.0);
        let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
        installer.install(&host.options(PORT), |_| true).unwrap();
        let devices = host.service_directory().join("devices.json");
        std::fs::write(&devices, "{}").unwrap();
        std::fs::write(host.downloads.0.join(executable_names(platform)[0]), "binary v2").unwrap();

        installer.install(&host.options(47_821), |_| true).unwrap();

        assert_eq!(std::fs::read_to_string(&devices).unwrap(), "{}", "{platform:?}");
        let installed = host.service_directory().join("bin").join(executable_names(platform)[0]);
        assert_eq!(std::fs::read_to_string(installed).unwrap(), "binary v2");
        let state = &installer.system().state;
        assert_eq!(state.serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:47821");
        assert!(state.background_processes.len() <= 1, "{platform:?}: {:?}", state.background_processes);
        installer.uninstall().unwrap();
        assert_eq!(snapshot(&host.home.0), home_before, "{platform:?}");
        assert!(installer.system().state.serve.is_empty(), "{platform:?}");
    }
}

#[test]
fn installing_again_from_the_installed_copy_keeps_the_executables() {
    for platform in PLATFORMS {
        let host = TestHost::new(platform);
        let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
        installer.install(&host.options(PORT), |_| true).unwrap();
        let mut options = host.options(PORT);
        options.source_directory = host.service_directory().join("bin");

        installer.install(&options, |_| true).unwrap();

        for name in executable_names(platform) {
            let installed = host.service_directory().join("bin").join(name);
            assert_eq!(std::fs::read_to_string(installed).unwrap(), format!("binary {name}"), "{platform:?}");
        }
    }
}

#[test]
fn pairing_uses_installed_address_and_uninstall_removes_paired_devices() {
    let host = TestHost::new(InstallPlatform::current());
    let home_before = snapshot(&host.home.0);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
    installer.install(&host.options(PORT), |_| true).unwrap();
    let pair = ["pair", "--state-dir"]
        .map(str::to_owned)
        .into_iter()
        .chain([host.service_directory().display().to_string()]);

    let output = management::run(&pair.collect::<Vec<_>>(), Platform::current(), &SocketEnvironment::default(), SystemTime::now()).unwrap();

    assert_eq!(default_state_directory(&host.home.0), host.service_directory());
    assert!(output.contains(&format!("https://{FQDN}")), "{output}");
    installer.uninstall().unwrap();
    assert_eq!(snapshot(&host.home.0), home_before);
}

/// 安裝前就有的東西：其他 Purrdr 功能的檔案、別的自動啟動項目、其他埠的 `tailscale serve`。
fn existing_files_and_settings(host: &TestHost, system: &mut FakeSystem) {
    let push = host.home.0.join(".purrdr/push-device/pairing");
    std::fs::create_dir_all(push.parent().unwrap()).unwrap();
    std::fs::write(push, "secret").unwrap();
    std::fs::create_dir_all(host.home.0.join("Library/LaunchAgents")).unwrap();
    std::fs::write(host.home.0.join("Library/LaunchAgents/other.plist"), "other").unwrap();
    std::fs::create_dir_all(host.home.0.join(".config/systemd/user/default.target.wants")).unwrap();
    std::fs::write(host.home.0.join(".config/systemd/user/default.target.wants/other.service"), "other").unwrap();
    system.state.systemd_enabled.insert("other.service".into());
    system.state.run_values.insert("OtherApp".into(), "other.exe".into());
    system
        .state
        .serve
        .insert(format!("{FQDN}:8443"), [("/".to_owned(), "http://127.0.0.1:3000".to_owned())].into());
}

#[test]
fn uninstall_restores_home_and_system_settings_exactly() {
    for platform in PLATFORMS {
        for prepare in [false, true] {
            let host = TestHost::new(platform);
            let mut system = FakeSystem::ready(&host.home.0);
            if prepare {
                existing_files_and_settings(&host, &mut system);
            }
            let home_before = snapshot(&host.home.0);
            let system_before = system.state.clone();
            let mut installer = Installer::new(host.environment(), system);
            installer.install(&host.options(PORT), |_| true).unwrap();

            let uninstalled = installer.uninstall().unwrap();

            assert_eq!(snapshot(&host.home.0), home_before, "家目錄({platform:?}, prepare = {prepare})");
            assert_eq!(installer.system().state, system_before, "系統設定({platform:?}, prepare = {prepare})");
            assert!(uninstalled.warnings.is_empty(), "{:?}", uninstalled.warnings);
        }
    }
}

#[test]
fn https_port_option_serves_beside_another_tool_and_uninstall_closes_only_that_port() {
    for platform in PLATFORMS {
        let host = TestHost::new(platform);
        let mut system = FakeSystem::ready(&host.home.0);
        occupy_https_port(&mut system, 443, "http://127.0.0.1:8765");
        let system_before = system.state.clone();
        let mut installer = Installer::new(host.environment(), system);

        let installed = installer.install(&host.options_on_https_port(PORT, 8443), |_| true).unwrap();

        assert_eq!(installed.https_address, format!("https://{FQDN}:8443"), "{platform:?}");
        let serve = &installer.system().state.serve;
        assert_eq!(serve[&format!("{FQDN}:443")]["/"], "http://127.0.0.1:8765", "{platform:?}");
        assert_eq!(serve[&format!("{FQDN}:8443")]["/"], "http://127.0.0.1:47820", "{platform:?}");
        let config: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(host.service_directory().join("config.json")).unwrap()).unwrap();
        assert_eq!(config["https_address"], format!("https://{FQDN}:8443"));

        installer.uninstall().unwrap();

        assert_eq!(installer.system().state.serve, system_before.serve, "{platform:?}");
    }
}

#[test]
fn installing_again_keeps_the_saved_https_port() {
    for platform in PLATFORMS {
        let host = TestHost::new(platform);
        let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
        installer.install(&host.options_on_https_port(PORT, 8443), |_| true).unwrap();

        let updated = installer.install(&host.options(PORT), |_| true).unwrap();

        assert_eq!(updated.https_address, format!("https://{FQDN}:8443"), "{platform:?}");
        let serve = &installer.system().state.serve;
        assert_eq!(serve.keys().collect::<Vec<_>>(), [&format!("{FQDN}:8443")], "{platform:?}");
    }
}

#[test]
fn moving_to_another_https_port_closes_the_old_one() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
    installer.install(&host.options(PORT), |_| true).unwrap();

    installer.install(&host.options_on_https_port(PORT, 10_000), |_| true).unwrap();

    let serve = &installer.system().state.serve;
    assert_eq!(serve.keys().collect::<Vec<_>>(), [&format!("{FQDN}:10000")]);
    installer.uninstall().unwrap();
    assert!(installer.system().state.serve.is_empty());
}

#[test]
fn record_from_0_2_0_without_https_port_means_443() {
    let host = TestHost::new(InstallPlatform::Linux);
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
    installer.install(&host.options(PORT), |_| true).unwrap();
    let record_file = host.service_directory().join("install.json");
    let mut record: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&record_file).unwrap()).unwrap();
    record.as_object_mut().unwrap().remove("https_port");
    std::fs::write(&record_file, record.to_string()).unwrap();

    installer.uninstall().unwrap();

    assert!(installer.system().state.serve.is_empty());
}

#[test]
fn pairing_link_keeps_the_https_port() {
    let host = TestHost::new(InstallPlatform::current());
    let mut installer = Installer::new(host.environment(), FakeSystem::ready(&host.home.0));
    installer.install(&host.options_on_https_port(PORT, 8443), |_| true).unwrap();
    let pair = ["pair", "--state-dir"]
        .map(str::to_owned)
        .into_iter()
        .chain([host.service_directory().display().to_string()]);

    let output = management::run(&pair.collect::<Vec<_>>(), Platform::current(), &SocketEnvironment::default(), SystemTime::now()).unwrap();

    assert!(output.contains(&format!("Address:      https://{FQDN}:8443")), "{output}");
    assert!(
        output.contains("purrdr://pair?address=https%3A%2F%2Fstudio.tail1234.ts.net%3A8443&code="),
        "{output}"
    );
}
