import Testing

@testable import PurrdrFeatures

/// 逐旗標與原 `PurrdrApp` 行為的自動比對(#565):下面的表是 #565 之前 `PurrdrApp.swift`(commit 08373587 的前一版)
/// 的旗標清單與判斷順序抄成資料,**刻意不引用 `LaunchConfiguration` 的順序表**,
/// 改了解析或順序而沒改這裡就會紅。`-uiTestingInspectorShown` 隨 Inspector 一起移除,現在沒有任何讀取者,所以不在表內。
/// 沒有 UI 測試使用而已刪除的旗標(#698)也從表裡拿掉;剩下的旗標行為不變。
@Suite("啟動旗標與原行為逐旗標比對")
struct LaunchConfigurationLegacyParityTests {
    private func parse(_ flags: [String]) -> LaunchConfiguration {
        LaunchConfiguration(arguments: ["Purrdr"] + flags)
    }

    /// 原 `demoScenario(_:)` 的 if 鏈順序。
    private static let legacyDemoOrder: [(String, LaunchConfiguration.DemoScenario)] = [
        ("-demoTailscaleCheck", .tailscaleCheck), ("-demoTranscriptPending", .transcriptPending),
        ("-demoLargeOutputOnPrompt", .largeOutputOnPrompt), ("-demoToolBurst", .toolBurst),
        ("-demoAgentFiles", .agentFiles), ("-demoSentImages", .sentImages),
        ("-demoAntigravity", .antigravity), ("-demoNeedsYouWithStatusBanner", .needsYouWithStatusBanner),
        ("-demoNeedsYouLater", .needsYouLater), ("-demoGoesOffline", .goesOffline), ("-demoUsageReadDelayed", .usageReadDelayed),
    ]

    /// 原 `makeMemberSession`／`uiTestingMemberBackend` 的判斷順序。
    private static let legacyMemberOrder: [(String, LaunchConfiguration.MemberScenario)] = [
        ("-uiTestingMemberLoading", .loading), ("-uiTestingPlusMember", .plus),
        ("-uiTestingLinkMerge", .linkMerge),
        ("-uiTestingMember", .member), ("-uiTestingNoMember", .noMember),
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
        ("-seedDataUsage", [], { $0.seedsDataUsage }),
        ("-uiTestingUndoSend", [], { $0.undoSendCountdown }),
        ("-showWelcome", [], { $0.showsWelcome }),
        ("-uiTestingSimulatedVideo", [], { $0.simulatesVideo }),
        ("-uiTestingSimulatedFileUpload", [], { $0.simulatesFileUpload }),
        ("-uiTestingOversizedClipboard", ["-uiTesting"], { $0.seedsOversizedClipboard }),
        ("-uiTestingLargeImageClipboard", ["-uiTesting"], { $0.seedsLargeImageClipboard }),
        ("-uiTestingAppLock", [], { $0.appLockEnabled }),
        ("-uiTestingHostKeyPrompt", [], { $0.promptsHostKey }),
        ("-uiTestingPushTestFails", [], { $0.pushTestFails }),
        ("-uiTestingCrashRecord", ["-uiTesting"], { $0.recordsUITestingCrash }),
        ("-uiTestingPlusOff", ["-uiTesting"], { $0.disablesPlus }),
        ("-uiTestingNoMember", ["-uiTesting"], { $0.usesTestingSignIn }),
        ("-uiTestingLinkMerge", ["-uiTesting"], { $0.usesTestingSignIn }),
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
            ("-seedPairedHTTPSHost", .pairedHTTPS),
        ]
        for (flag, option) in seeds { #expect(parse([flag]).seededHosts == option, "\(flag)") }
        #expect(parse(seeds.map(\.0)).seededHosts == seeds.reduce(into: LaunchConfiguration.SeededHosts()) { $0.formUnion($1.1) })
        #expect(parse(["-uiTestingPairingScan"]).pairingScan == .simulated)
        #expect(parse(["-uiTestingCameraDenied"]).pairingScan == .cameraDenied)
        #expect(parse(["-uiTestingPairingScan", "-uiTestingCameraDenied"]).pairingScan == .cameraDenied)
        #expect(parse(["-uiTestingRecentPhotos"]).recentPhotos == .few)
        #expect(parse(["-uiTesting"]).disablesAnimations)
        #expect(!parse(["-uiTesting", "-uiTestingAnimations"]).disablesAnimations)
    }

    @Test("每個 LaunchFlag 都有表格涵蓋")
    func everyLegacyFlagIsCovered() {
        let covered = Set(Self.legacyDemoOrder.map(\.0)).union(Self.legacyMemberOrder.map(\.0))
            .union(Self.booleans.map(\.flag))
            .union([
                "-seedHost", "-seedUnreachableHost", "-seedUnpairedHTTPSHost", "-seedPairedHTTPSHost",
                "-uiTestingPairingScan", "-uiTestingCameraDenied", "-uiTestingRecentPhotos", "-uiTestingAnimations",
            ])
        let legacyAll = Set(LaunchFlag.allCases.map(\.rawValue))
        #expect(legacyAll.subtracting(covered).isEmpty, "\(legacyAll.subtracting(covered).sorted())")
    }
}
