import Testing

@testable import PurrdrFeatures

/// 逐旗標與原 `PurrdrApp` 行為的自動比對(#565):下面的表是 #565 之前 `PurrdrApp.swift`(commit 08373587 的前一版)
/// 的旗標清單與判斷順序逐字抄成資料,**刻意不引用 `LaunchConfiguration` 的順序表**,
/// 改了解析或順序而沒改這裡就會紅。`-uiTestingInspectorShown` 隨 Inspector 一起移除,現在沒有任何讀取者,所以不在表內。
@Suite("啟動旗標與原行為逐旗標比對")
struct LaunchConfigurationLegacyParityTests {
    private func parse(_ flags: [String]) -> LaunchConfiguration {
        LaunchConfiguration(arguments: ["Purrdr"] + flags)
    }

    /// 原 `demoScenario(_:)` 的 if 鏈順序。
    private static let legacyDemoOrder: [(String, LaunchConfiguration.DemoScenario)] = [
        ("-demoPaneInUse", .paneInUse), ("-demoTailscaleCheck", .tailscaleCheck),
        ("-demoTailscaleCheckCompletes", .tailscaleCheckCompletes), ("-demoTranscriptPending", .transcriptPending),
        ("-demoLargeOutput", .largeOutput), ("-demoLargeOutputOnPrompt", .largeOutputOnPrompt), ("-demoToolBurst", .toolBurst),
        ("-demoWorkingAfterPrompt", .workingAfterPrompt), ("-demoAgentFiles", .agentFiles), ("-demoSentImages", .sentImages),
        ("-demoAntigravity", .antigravity), ("-demoNeedsYouWithStatusBanner", .needsYouWithStatusBanner),
        ("-demoNeedsYouLater", .needsYouLater), ("-demoGoesOffline", .goesOffline),
        ("-demoGoesOfflineHanging", .goesOfflineHanging), ("-demoNoNetwork", .noNetwork),
    ]

    /// 原 `makeMemberSession`／`uiTestingMemberBackend` 的判斷順序。
    private static let legacyMemberOrder: [(String, LaunchConfiguration.MemberScenario)] = [
        ("-uiTestingMemberLoading", .loading), ("-uiTestingMemberOffline", .offline), ("-uiTestingPlusMember", .plus),
        ("-uiTestingGooglePlayMember", .googlePlay), ("-uiTestingGraceMember", .grace), ("-uiTestingExpiredMember", .expired),
        ("-uiTestingOwnedByOtherMember", .ownedByOtherMember), ("-uiTestingPendingReviewMember", .pendingReview),
        ("-uiTestingLinkMergeBlocked", .linkMerge(blocked: true)), ("-uiTestingLinkMerge", .linkMerge(blocked: false)),
        ("-uiTestingUpgradedMember", .upgraded), ("-uiTestingMember", .member), ("-uiTestingNoMember", .noMember),
        ("-uiTestingSignUp", .signUp),
    ]

    @Test("Demo 情境:逐旗標單獨對應,兩兩同時出現時取原順序在前的")
    func demoScenarios() {
        let order = Self.legacyDemoOrder
        for (flag, scenario) in order { #expect(parse([flag]).demoScenario == scenario, "\(flag)") }
        for i in order.indices {
            for j in order.indices where j > i {
                #expect(parse([order[j].0, order[i].0]).demoScenario == order[i].1, "\(order[i].0) vs \(order[j].0)")
            }
        }
        #expect(parse([]).demoScenario == .standard)
    }

    @Test("會員情境:逐旗標單獨對應,兩兩同時出現時取原順序在前的")
    func memberScenarios() {
        let order = Self.legacyMemberOrder
        for (flag, scenario) in order { #expect(parse([flag]).member == scenario, "\(flag)") }
        for i in order.indices {
            for j in order.indices where j > i {
                // LinkMerge 與 LinkMergeBlocked 同屬一個情境(blocked 由後者決定),不比先後。
                if order[i].0.hasPrefix("-uiTestingLinkMerge"), order[j].0.hasPrefix("-uiTestingLinkMerge") { continue }
                #expect(parse([order[j].0, order[i].0]).member == order[i].1, "\(order[i].0) vs \(order[j].0)")
            }
        }
        #expect(parse([]).member == .none)
    }

    /// `prerequisite` 是需要一起帶的前提旗標(原行為只在 `-uiTesting` 下才讀的欄位)。
    private static let booleans: [(flag: String, prerequisite: [String], read: @Sendable (LaunchConfiguration) -> Bool)] = [
        ("-uiTesting", [], { $0.isUITesting }),
        ("-demoCompanions", [], { $0.showsDemoCompanions }),
        ("-selectDemo", [], { $0.selectsDemo }),
        ("-demoOutdatedHostService", [], { $0.hostServiceIsOutdated }),
        ("-uiTestingNoHosts", [], { $0.hasNoHosts }),
        ("-demoNoNetwork", [], { $0.simulatesNoNetwork }),
        ("-seedDataUsage", [], { $0.seedsDataUsage }),
        ("-uiTestingUndoSend", [], { $0.undoSendCountdown }),
        ("-showWelcome", [], { $0.showsWelcome }),
        ("-uiTestingSimulatedVideo", [], { $0.simulatesVideo }),
        ("-uiTestingSimulatedFileUpload", [], { $0.simulatesFileUpload }),
        ("-uiTestingOversizedClipboard", ["-uiTesting"], { $0.seedsOversizedClipboard }),
        ("-uiTestingNoPasscode", [], { $0.hasNoPasscode }),
        ("-uiTestingAppLock", [], { $0.appLockEnabled }),
        ("-uiTestingPushTestFails", [], { $0.pushTestFails }),
        ("-uiTestingHidesDebugOverlay", [], { $0.hidesDebugOverlay }),
        ("-uiTestingCrashRecord", ["-uiTesting"], { $0.recordsUITestingCrash }),
        ("-uiTestingKeepCrashNotice", [], { $0.keepsCrashNotice }),
        ("-uiTestingOwnedByOtherMember", [], { $0.storeOwnedByOtherMember }),
        ("-uiTestingSignUp", ["-uiTesting"], { $0.usesTestingSignIn }),
        ("-uiTestingNoMember", ["-uiTesting"], { $0.usesTestingSignIn }),
        ("-uiTestingLinkMerge", ["-uiTesting"], { $0.usesTestingSignIn }),
        ("-uiTestingLinkMergeBlocked", ["-uiTesting"], { $0.usesTestingSignIn }),
        ("-uiTestingUpgradedMember", ["-uiTesting"], { $0.usesTestingSignIn }),
    ]

    @Test("布林旗標:每個旗標帶前提後為真,沒帶旗標時為假,需要 -uiTesting 的沒帶前提不生效")
    func booleanFlags() {
        for entry in Self.booleans {
            #expect(entry.read(parse(entry.prerequisite + [entry.flag])), "\(entry.flag) 應為真")
            if !entry.prerequisite.isEmpty {
                #expect(!entry.read(parse([entry.flag])), "\(entry.flag) 沒有 -uiTesting 時不生效")
                #expect(!entry.read(parse(entry.prerequisite)), "\(entry.flag) 沒帶旗標時為假")
            } else if entry.flag != "-uiTesting" {
                #expect(!entry.read(parse([])), "\(entry.flag) 沒帶旗標時為假")
            }
        }
    }

    @Test("已存主機、配對掃描、最近照片、動畫:逐旗標對應")
    func remainingFlags() {
        let seeds: [(String, LaunchConfiguration.SeededHosts)] = [
            ("-seedHost", .studioMac), ("-seedUnreachableHost", .buildBox), ("-seedUnpairedHTTPSHost", .unpairedHTTPS),
            ("-seedReadOnlyHTTPSHost", .readOnlyHTTPS), ("-seedPairedHTTPSHost", .pairedHTTPS), ("-seedSlowHost", .slowBox),
        ]
        for (flag, option) in seeds { #expect(parse([flag]).seededHosts == option, "\(flag)") }
        #expect(parse(seeds.map(\.0)).seededHosts == seeds.reduce(into: LaunchConfiguration.SeededHosts()) { $0.formUnion($1.1) })
        #expect(parse(["-uiTestingPairingScan"]).pairingScan == .simulated)
        #expect(parse(["-uiTestingCameraDenied"]).pairingScan == .cameraDenied)
        #expect(parse(["-uiTestingPairingScan", "-uiTestingCameraDenied"]).pairingScan == .cameraDenied)
        #expect(parse(["-uiTestingRecentPhotos"]).recentPhotos == .few)
        #expect(parse(["-uiTestingManyRecentPhotos"]).recentPhotos == .many)
        #expect(parse(["-uiTestingRecentPhotos", "-uiTestingManyRecentPhotos"]).recentPhotos == .many)
        #expect(parse(["-uiTesting"]).disablesAnimations)
        #expect(!parse(["-uiTesting", "-uiTestingAnimations"]).disablesAnimations)
    }

    @Test("原 PurrdrApp 讀過的每個旗標都有表格涵蓋")
    func everyLegacyFlagIsCovered() {
        let covered = Set(Self.legacyDemoOrder.map(\.0)).union(Self.legacyMemberOrder.map(\.0))
            .union(Self.booleans.map(\.flag))
            .union([
                "-seedHost", "-seedUnreachableHost", "-seedUnpairedHTTPSHost", "-seedReadOnlyHTTPSHost", "-seedPairedHTTPSHost",
                "-seedSlowHost", "-uiTestingPairingScan", "-uiTestingCameraDenied", "-uiTestingRecentPhotos",
                "-uiTestingManyRecentPhotos", "-uiTestingAnimations",
            ])
        let legacyAll: Set<String> = [
            "-demoAgentFiles", "-demoAntigravity", "-demoCompanions", "-demoGoesOffline", "-demoGoesOfflineHanging",
            "-demoLargeOutput", "-demoLargeOutputOnPrompt", "-demoNeedsYouLater", "-demoNeedsYouWithStatusBanner", "-demoNoNetwork",
            "-demoOutdatedHostService", "-demoPaneInUse", "-demoSentImages", "-demoTailscaleCheck", "-demoTailscaleCheckCompletes",
            "-demoToolBurst", "-demoTranscriptPending", "-demoWorkingAfterPrompt", "-seedDataUsage", "-seedHost",
            "-seedPairedHTTPSHost", "-seedReadOnlyHTTPSHost", "-seedSlowHost", "-seedUnpairedHTTPSHost", "-seedUnreachableHost",
            "-selectDemo", "-showWelcome", "-uiTesting", "-uiTestingAnimations", "-uiTestingAppLock", "-uiTestingCameraDenied",
            "-uiTestingExpiredMember", "-uiTestingGooglePlayMember", "-uiTestingGraceMember", "-uiTestingLinkMerge",
            "-uiTestingLinkMergeBlocked", "-uiTestingManyRecentPhotos", "-uiTestingMember", "-uiTestingMemberLoading",
            "-uiTestingMemberOffline", "-uiTestingNoHosts", "-uiTestingNoMember", "-uiTestingNoPasscode",
            "-uiTestingOwnedByOtherMember", "-uiTestingPairingScan", "-uiTestingPendingReviewMember", "-uiTestingPlusMember",
            "-uiTestingPushTestFails", "-uiTestingRecentPhotos", "-uiTestingSignUp", "-uiTestingSimulatedVideo",
            "-uiTestingUndoSend", "-uiTestingUpgradedMember",
        ]
        #expect(legacyAll.subtracting(covered).isEmpty, "\(legacyAll.subtracting(covered).sorted())")
    }
}
