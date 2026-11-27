import Foundation

/// 啟動旗標解析後的型別化值(#565、spec #555)。
///
/// 所有 `-uiTesting`、`-demo*`、`-seed*` 旗標只在 app 入口解析一次,往後只傳這個值;Features 不讀 process arguments。
/// 互斥規則(Demo 情境、會員情境)集中在這裡,`LaunchConfigurationTests` 守門。
/// 解析不看 `-uiTesting`(`-demo*` 情境在正式啟動也有效,與先前行為相同);哪些欄位只在 UI 測試生效由環境 adapter 決定。
public struct LaunchConfiguration: Equatable, Sendable {
    /// Demo 主機的情境。旗標互斥:同時帶多個只採用 `priorityOrder` 中的第一個。
    public enum DemoScenario: Equatable, Sendable, CaseIterable {
        case standard
        case paneInUse, tailscaleCheck, tailscaleCheckCompletes, transcriptPending
        case largeOutput, largeOutputOnPrompt, toolBurst, workingAfterPrompt
        case agentFiles, sentImages, antigravity
        case needsYouWithStatusBanner, needsYouLater
        case goesOffline, goesOfflineHanging, noNetwork
        /// 聊天用量讀取延遲幾秒才回應(#644):用量環先轉圈、之後換成結果。
        case usageReadDelayed

        /// 優先順序(前面的贏);`standard` 不在內。
        public static let priorityOrder: [DemoScenario] = [
            .paneInUse, .tailscaleCheck, .tailscaleCheckCompletes, .transcriptPending, .largeOutput, .largeOutputOnPrompt,
            .toolBurst, .workingAfterPrompt, .agentFiles, .sentImages, .antigravity, .needsYouWithStatusBanner, .needsYouLater,
            .goesOffline, .goesOfflineHanging, .noNetwork, .usageReadDelayed,
        ]

        /// 對應的啟動旗標;`standard` 沒有。
        public var flag: String? {
            switch self {
            case .standard: nil
            case .paneInUse: "-demoPaneInUse"
            case .tailscaleCheck: "-demoTailscaleCheck"
            case .tailscaleCheckCompletes: "-demoTailscaleCheckCompletes"
            case .transcriptPending: "-demoTranscriptPending"
            case .largeOutput: "-demoLargeOutput"
            case .largeOutputOnPrompt: "-demoLargeOutputOnPrompt"
            case .toolBurst: "-demoToolBurst"
            case .workingAfterPrompt: "-demoWorkingAfterPrompt"
            case .agentFiles: "-demoAgentFiles"
            case .sentImages: "-demoSentImages"
            case .antigravity: "-demoAntigravity"
            case .needsYouWithStatusBanner: "-demoNeedsYouWithStatusBanner"
            case .needsYouLater: "-demoNeedsYouLater"
            case .goesOffline: "-demoGoesOffline"
            case .goesOfflineHanging: "-demoGoesOfflineHanging"
            case .noNetwork: "-demoNoNetwork"
            case .usageReadDelayed: "-demoUsageReadDelayed"
            }
        }
    }

    /// UI 測試的會員情境(假後台)。`loading`、`offline` 最優先,其餘照 `init(arguments:)` 的順序。
    public enum MemberScenario: Equatable, Sendable {
        case none
        /// 後台一直沒回應(#496)。
        case loading
        /// 已登入過但後台一律連不上。
        case offline
        case plus, googlePlay, grace, expired, ownedByOtherMember, pendingReview
        case linkMerge(blocked: Bool)
        case upgraded
        case member
        /// 沒登入,且這個帳號沒有會員(#453)。
        case noMember
        /// 沒登入,登入或註冊直接成功(#408)。
        case signUp

        /// 這個情境改用 app 的假後台(`UITestingBackendTransport`)而不是 `loading`／`offline` 的專用替身。
        public var usesFakeBackend: Bool {
            switch self {
            case .none, .loading, .offline: false
            default: true
            }
        }
    }

    /// 已存主機旗標(可並存)。
    public struct SeededHosts: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// `-seedHost`:Studio Mac。
        public static let studioMac = SeededHosts(rawValue: 1 << 0)
        /// `-seedUnreachableHost`:連不上的 Build Box。
        public static let buildBox = SeededHosts(rawValue: 1 << 1)
        /// `-seedUnpairedHTTPSHost`
        public static let unpairedHTTPS = SeededHosts(rawValue: 1 << 2)
        /// `-seedReadOnlyHTTPSHost`
        public static let readOnlyHTTPS = SeededHosts(rawValue: 1 << 3)
        /// `-seedPairedHTTPSHost`
        public static let pairedHTTPS = SeededHosts(rawValue: 1 << 4)
        /// `-seedSlowHost`:連線卡住的 Slow Box。
        public static let slowBox = SeededHosts(rawValue: 1 << 5)
    }

    public enum PairingScan: Equatable, Sendable { case camera, simulated, cameraDenied }
    public enum RecentPhotos: Equatable, Sendable { case denied, few, many }

    /// `-uiTesting`:只用 Demo 主機、記憶體存放、不連網路。
    public let isUITesting: Bool
    /// UI 測試時關掉動畫(帶 `-uiTestingAnimations` 保留)。
    public let disablesAnimations: Bool
    public let demoScenario: DemoScenario
    public let seededHosts: SeededHosts
    public let member: MemberScenario
    public let pairingScan: PairingScan
    public let recentPhotos: RecentPhotos
    public let showsDemoCompanions: Bool
    public let selectsDemo: Bool
    public let hostServiceIsOutdated: Bool
    public let hasNoHosts: Bool
    /// `-demoNoNetwork`:裝置一直沒有網路(#221)。只看原始旗標,與情境優先順序獨立。
    public let simulatesNoNetwork: Bool
    public let seedsDataUsage: Bool
    public let undoSendCountdown: Bool
    public let showsWelcome: Bool
    public let simulatesVideo: Bool
    /// `-uiTestingSimulatedFileUpload`:檔案 tab 的「上傳檔案」不開文件挑選器,直接上傳一個與家目錄已有項目同名的檔案(#626)。
    public let simulatesFileUpload: Bool
    /// `-uiTestingOversizedClipboard`:剪貼簿先放一段超過終端機貼上上限的文字(#626)。
    public let seedsOversizedClipboard: Bool
    public let hasNoPasscode: Bool
    /// `-uiTestingHostKeyPrompt`:還沒有 host key pin 的 SSH 主機第一次連線時出示未信任的 host key,走到「信任這台主機?」(#613)。
    public let promptsHostKey: Bool
    public let appLockEnabled: Bool
    public let pushTestFails: Bool
    /// 預放一筆「上次異常結束」的閃退記錄(#632)。
    public let recordsUITestingCrash: Bool
    /// 沿用上一次啟動留下的閃退提示狀態(測重啟後不再出現)。
    public let keepsCrashNotice: Bool
    /// `-uiTestingOwnedByOtherMember`:StoreKit 替身的目前交易屬於另一個會員(與會員情境優先順序獨立)。
    public let storeOwnedByOtherMember: Bool
    /// `-uiTestingPlusOff`:模擬上架版(Purrdr Plus 編譯開關關閉,#676)。與會員情境互不影響;預設(沒帶)是 Debug 的開啟。
    public let disablesPlus: Bool
    /// 登入頁用測試登入(只看原始旗標,不受會員情境優先順序影響)。
    public let usesTestingSignIn: Bool

    /// UI 測試時聊天列表量測閱讀位移(驗收用;Release 沒有這個量測)。
    public var tracksReadingDrift: Bool { isUITesting }

    public init(arguments: [String]) {
        let set = Set(arguments)
        func has(_ flag: String) -> Bool { set.contains(flag) }
        isUITesting = has("-uiTesting")
        disablesAnimations = isUITesting && !has("-uiTestingAnimations")
        demoScenario = DemoScenario.priorityOrder.first { $0.flag.map(has) ?? false } ?? .standard

        var seeded: SeededHosts = []
        if has("-seedHost") { seeded.insert(.studioMac) }
        if has("-seedUnreachableHost") { seeded.insert(.buildBox) }
        if has("-seedUnpairedHTTPSHost") { seeded.insert(.unpairedHTTPS) }
        if has("-seedReadOnlyHTTPSHost") { seeded.insert(.readOnlyHTTPS) }
        if has("-seedPairedHTTPSHost") { seeded.insert(.pairedHTTPS) }
        if has("-seedSlowHost") { seeded.insert(.slowBox) }
        seededHosts = seeded

        // 優先順序與先前 `makeMemberSession`／`uiTestingMemberBackend` 的判斷順序相同。
        if has("-uiTestingMemberLoading") { member = .loading }
        else if has("-uiTestingMemberOffline") { member = .offline }
        else if has("-uiTestingPlusMember") { member = .plus }
        else if has("-uiTestingGooglePlayMember") { member = .googlePlay }
        else if has("-uiTestingGraceMember") { member = .grace }
        else if has("-uiTestingExpiredMember") { member = .expired }
        else if has("-uiTestingOwnedByOtherMember") { member = .ownedByOtherMember }
        else if has("-uiTestingPendingReviewMember") { member = .pendingReview }
        else if has("-uiTestingLinkMerge") || has("-uiTestingLinkMergeBlocked") {
            member = .linkMerge(blocked: has("-uiTestingLinkMergeBlocked"))
        }
        else if has("-uiTestingUpgradedMember") { member = .upgraded }
        else if has("-uiTestingMember") { member = .member }
        else if has("-uiTestingNoMember") { member = .noMember }
        else if has("-uiTestingSignUp") { member = .signUp }
        else { member = .none }

        pairingScan = has("-uiTestingCameraDenied") ? .cameraDenied : has("-uiTestingPairingScan") ? .simulated : .camera
        recentPhotos = has("-uiTestingManyRecentPhotos") ? .many : has("-uiTestingRecentPhotos") ? .few : .denied
        showsDemoCompanions = has("-demoCompanions")
        selectsDemo = has("-selectDemo")
        hostServiceIsOutdated = has("-demoOutdatedHostService")
        hasNoHosts = has("-uiTestingNoHosts")
        simulatesNoNetwork = has("-demoNoNetwork")
        seedsDataUsage = has("-seedDataUsage")
        undoSendCountdown = has("-uiTestingUndoSend")
        showsWelcome = has("-showWelcome")
        simulatesVideo = has("-uiTestingSimulatedVideo")
        simulatesFileUpload = has("-uiTestingSimulatedFileUpload")
        seedsOversizedClipboard = isUITesting && has("-uiTestingOversizedClipboard")
        hasNoPasscode = has("-uiTestingNoPasscode")
        promptsHostKey = has("-uiTestingHostKeyPrompt")
        appLockEnabled = has("-uiTestingAppLock")
        pushTestFails = has("-uiTestingPushTestFails")
        recordsUITestingCrash = isUITesting && has("-uiTestingCrashRecord")
        keepsCrashNotice = has("-uiTestingKeepCrashNotice")
        storeOwnedByOtherMember = has("-uiTestingOwnedByOtherMember")
        disablesPlus = isUITesting && has("-uiTestingPlusOff")
        usesTestingSignIn = isUITesting
            && (has("-uiTestingSignUp") || has("-uiTestingNoMember") || has("-uiTestingLinkMerge")
                || has("-uiTestingLinkMergeBlocked") || has("-uiTestingUpgradedMember"))
    }
}
