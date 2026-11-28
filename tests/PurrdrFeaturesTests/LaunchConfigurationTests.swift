import Testing

@testable import PurrdrFeatures

/// 啟動旗標先解析成型別化的值(#565):互斥規則、優先順序與各旗標的對應都在這裡守住。
@Suite("啟動旗標解析")
struct LaunchConfigurationTests {
    private func parse(_ flags: LaunchFlag...) -> LaunchConfiguration {
        LaunchConfiguration(arguments: ["Purrdr"] + flags.map(\.rawValue))
    }

    @Test("沒有旗標時是正式啟動、情境為標準")
    func plainLaunch() {
        let config = parse()
        #expect(!config.isUITesting)
        #expect(config.demoScenario == .standard)
        #expect(config.seededHosts.isEmpty)
        #expect(config.member == .none)
        #expect(config.pairingScan == .camera)
        #expect(config.recentPhotos == .denied)
    }

    @Test("-uiTesting 開啟 UI 測試;動畫預設關,帶 -uiTestingAnimations 才保留")
    func uiTestingAndAnimations() {
        #expect(parse(.uiTesting).isUITesting)
        #expect(parse(.uiTesting).disablesAnimations)
        #expect(!parse(.uiTesting, .uiTestingAnimations).disablesAnimations)
        #expect(!parse(.uiTestingAnimations).disablesAnimations)
    }

    @Test("-uiTestingPlusOff 模擬上架版(Plus 關閉),與會員情境互不影響;沒帶 -uiTesting 不生效")
    func plusOffFlag() {
        #expect(parse(.uiTesting, .uiTestingPlusOff).disablesPlus)
        #expect(!parse(.uiTesting).disablesPlus)
        #expect(!parse(.uiTestingPlusOff).disablesPlus)
        let config = parse(.uiTesting, .uiTestingPlusOff, .uiTestingMember)
        #expect(config.disablesPlus)
        #expect(config.member == .member)
    }

    @Test("Demo 情境每個旗標單獨出現時各自對應")
    func eachDemoScenario() {
        let table: [(LaunchFlag, LaunchConfiguration.DemoScenario)] = [
            (.demoTailscaleCheck, .tailscaleCheck), (.demoTranscriptPending, .transcriptPending),
            (.demoLargeOutputOnPrompt, .largeOutputOnPrompt), (.demoToolBurst, .toolBurst),
            (.demoAgentFiles, .agentFiles), (.demoSentImages, .sentImages), (.demoAntigravity, .antigravity),
            (.demoNeedsYouWithStatusBanner, .needsYouWithStatusBanner), (.demoNeedsYouLater, .needsYouLater),
            (.demoGoesOffline, .goesOffline), (.demoUsageReadDelayed, .usageReadDelayed),
        ]
        #expect(table.count == LaunchConfiguration.DemoScenario.priorityOrder.count)
        for (flag, expected) in table { #expect(parse(flag).demoScenario == expected, "\(flag)") }
        // 每個情境都有對應的旗標(單一來源:旗標一定是 LaunchFlag 的案例)。
        #expect(Set(table.map(\.0)) == Set(LaunchConfiguration.DemoScenario.priorityOrder.compactMap(\.flag)))
    }

    @Test("Demo 情境互斥:同時帶多個只採用優先順序中的第一個,與出現順序無關")
    func demoScenariosAreExclusive() {
        #expect(parse(.demoToolBurst, .demoTailscaleCheck).demoScenario == .tailscaleCheck)
        #expect(parse(.demoGoesOffline, .demoAgentFiles, .demoLargeOutputOnPrompt).demoScenario == .largeOutputOnPrompt)
        // 順序表裡每個情境都贏過排在它後面的所有情境(旗標反向給,確認與出現順序無關)。
        let order = LaunchConfiguration.DemoScenario.priorityOrder
        for (index, scenario) in order.enumerated() {
            let flags = order[index...].compactMap(\.flag).map(\.rawValue).reversed()
            let config = LaunchConfiguration(arguments: ["Purrdr"] + flags)
            #expect(config.demoScenario == scenario, "\(scenario)")
        }
    }

    @Test("已存主機旗標可以並存")
    func seededHostsCombine() {
        let config = parse(.seedHost, .seedUnpairedHTTPSHost, .seedPairedHTTPSHost)
        #expect(config.seededHosts == [.studioMac, .unpairedHTTPS, .pairedHTTPS])
        #expect(!config.seededHosts.contains(.buildBox))
    }

    @Test("會員情境互斥:載入中最優先,其餘依優先順序")
    func memberScenarioPriority() {
        #expect(parse(.uiTestingMember).member == .member)
        #expect(parse(.uiTestingPlusMember, .uiTestingMember).member == .plus)
        #expect(parse(.uiTestingMember, .uiTestingNoMember).member == .member)
        #expect(parse(.uiTestingNoMember).member == .noMember)
        #expect(parse(.uiTestingMemberLoading, .uiTestingPlusMember).member == .loading)
        #expect(parse(.uiTestingLinkMerge).member == .linkMerge)
        #expect(parse(.uiTestingUpgradedMember, .uiTestingMember).member == .upgraded)
    }

    @Test("只有假後台的會員情境算「有假後台」")
    func usesFakeBackend() {
        #expect(parse(.uiTestingMember).member.usesFakeBackend)
        #expect(!parse(.uiTestingMemberLoading).member.usesFakeBackend)
        #expect(!parse().member.usesFakeBackend)
    }

    @Test("測試登入只看原始旗標,不受會員情境優先順序影響")
    func testingSignInIgnoresPriority() {
        #expect(parse(.uiTesting, .uiTestingPlusMember, .uiTestingNoMember).usesTestingSignIn)
        #expect(parse(.uiTesting, .uiTestingUpgradedMember).usesTestingSignIn)
        #expect(!parse(.uiTesting, .uiTestingMember).usesTestingSignIn)
        #expect(!parse(.uiTestingNoMember).usesTestingSignIn)
    }

    @Test("配對碼掃描:相機被拒優先於模擬掃描")
    func pairingScan() {
        #expect(parse(.uiTestingPairingScan).pairingScan == .simulated)
        #expect(parse(.uiTestingCameraDenied, .uiTestingPairingScan).pairingScan == .cameraDenied)
    }

    @Test("最近照片:沒帶旗標是沒有權限,帶了是幾張")
    func recentPhotos() {
        #expect(parse().recentPhotos == .denied)
        #expect(parse(.uiTestingRecentPhotos).recentPhotos == .few)
    }

    @Test("其餘布林旗標")
    func booleanFlags() {
        let config = parse(
            .uiTesting, .demoCompanions, .selectDemo, .demoOutdatedHostService, .uiTestingNoHosts, .seedDataUsage,
            .uiTestingUndoSend, .showWelcome, .uiTestingSimulatedVideo,
            .uiTestingAppLock, .uiTestingPushTestFails, .uiTestingOwnedByOtherMember,
            .seedPairedHTTPSHost, .uiTestingSimulatedFileUpload, .uiTestingOversizedClipboard, .uiTestingLargeImageClipboard, .uiTestingHostKeyPrompt)
        #expect(config.promptsHostKey)
        #expect(config.showsDemoCompanions && config.selectsDemo && config.hostServiceIsOutdated && config.hasNoHosts)
        #expect(config.seedsDataUsage && config.undoSendCountdown && config.showsWelcome)
        #expect(config.simulatesVideo && config.appLockEnabled && config.pushTestFails)
        #expect(config.storeOwnedByOtherMember)
        #expect(config.simulatesFileUpload && config.seedsOversizedClipboard && config.seedsLargeImageClipboard)
        #expect(config.seededHosts.contains(.pairedHTTPS))
        let none = parse(.uiTesting)
        #expect(!none.showsDemoCompanions && !none.selectsDemo && !none.hasNoHosts && !none.showsWelcome)
        #expect(!none.simulatesFileUpload && !none.seedsOversizedClipboard && !none.seedsLargeImageClipboard && !none.promptsHostKey)
    }

    @Test("閱讀位移量測只在 UI 測試開啟")
    func readingDrift() {
        #expect(parse(.uiTesting).tracksReadingDrift)
        #expect(!parse().tracksReadingDrift)
    }
}
