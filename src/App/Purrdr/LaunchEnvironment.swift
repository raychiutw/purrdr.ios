import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import PurrdrNotificationContent
import PurrdrSSH
import SwiftUI

/// 啟動環境交出的同一組依賴(#565、spec #555)。
///
/// 正式(`ProductionEnvironment`)與 UI 測試(`UITestingEnvironment`)各一個 adapter,都回傳這個型別;
/// 欄位一律沒有預設值,adapter 漏給任何一項都會編譯失敗。`AppAssembly` 只負責把這組依賴接成畫面 model,
/// 不再有「if uiTesting」分支;app 入口(`PurrdrApp`)只做連接。
struct LaunchEnvironment {
    /// 示範主機是否在啟動時算已進入(正式沿用上次選擇並記下變更,UI 測試每次重來、不記錄)。
    struct DemoEntry {
        var initial: Bool
        var didChange: (@MainActor (Bool) -> Void)?
    }

    /// UI 測試與畫面用的開關,以環境值注入畫面。
    struct ViewFlags {
        var forcesOpaqueGlass: Bool
        var allowsTestingLinks: Bool
        var usesTestingSignIn: Bool
        var tracksReadingDrift: Bool
        var hidesDebugOverlay: Bool
    }

    /// 平台輸入來源(掃描、相簿、影片)。
    struct InputSources {
        var pairingCodeScan: PairingCodeScanSource
        var recentPhotos: RecentPhotoSource
        var video: VideoSource
        var fileUpload: FileUploadSource
    }

    /// 推播的平台與存放處。
    struct PushParts {
        var platform: any PushPlatform
        var store: any PushPairingStore
        var loadDevice: @MainActor () throws -> PushDeviceIdentity
        var hostNames: (any PushHostNameSharing)?
        /// UI 測試的全域測試通知替身;正式沒有。
        var testSender: (any PushTestNotificationSending)?
    }

    var disablesAnimations: Bool
    var memberSession: MemberSession
    var partition: MemberPartition
    var deviceOwner: any DeviceOwnerAuthenticating
    var plusStore: any PlusStore
    var push: PushParts
    /// 主機清單的依賴(要推播服務,所以是工廠)。
    var makeHosts: @MainActor (PushService) -> HostsDependencies
    var simulatesNoNetwork: Bool
    var demoEntry: DemoEntry
    var trafficStore: any TrafficStore
    /// 流量計量建好後的種子資料(UI 測試);正式沒有。
    var seedTraffic: (@MainActor (TrafficMeter) -> Void)?
    var reviewPrompt: ReviewPrompt
    /// 送出可撤回的秒數;`nil` 沿用使用者的本機偏好。
    var undoSendSeconds: (@MainActor () -> Int)?
    var hostSyncStore: any HostSyncStore
    var hitchLog: DiagnosticLogFile
    /// 啟動提示「上次 Purrdr 意外關閉」的已提示狀態(#632)。
    var crashNoticeStore: any CrashNoticeStoring
    /// UI 測試:預放一筆閃退記錄(#632)。
    var recordsUITestingCrash: Bool
    /// 是否訂閱 MetricKit 每日摘要(只在真實啟動)。
    var subscribesToMetricKit: Bool
    var welcomeStore: any WelcomeStore
    var inputSources: InputSources
    var viewFlags: ViewFlags
    var appLock: AppLock
}

/// Demo 的示範主機(#34,App Review 也看得到):「Studio Mac」(內容同 Demo 主機)與一律連不上的「Build Box」,
/// 演出多主機合併列表與連線中斷。只在 Demo 主機出現在列表時出現,不是已存主機。
@MainActor
enum DemoCompanions {
    static func make(_ demo: DemoHost) -> [DemoCompanionHost] {
        [
            DemoCompanionHost(id: UUID(uuidString: "DE300000-0000-4000-8000-000000000001")!, name: "Studio Mac", icon: .macMini, channel: demo),
            DemoCompanionHost(
                id: UUID(uuidString: "DE300000-0000-4000-8000-000000000002")!, name: "Build Box", icon: .rack,
                channel: DemoUnreachableChannel()),
        ]
    }
}

extension LaunchConfiguration.DemoScenario {
    /// 對應 Demo 主機的情境(Features 不 import Demo,所以對應留在 app)。
    var demoHostScenario: DemoHost.Scenario {
        switch self {
        case .standard: .standard
        case .paneInUse: .paneInUse
        case .tailscaleCheck: .tailscaleCheck(completesAfter: nil)
        case .tailscaleCheckCompletes: .tailscaleCheck(completesAfter: .seconds(3))
        case .transcriptPending: .transcriptPending
        case .largeOutput: .largeOutput(after: .seconds(5))
        case .largeOutputOnPrompt: .largeOutputOnPrompt
        case .toolBurst: .toolBurst(after: .seconds(10))
        case .workingAfterPrompt: .workingAfterPrompt(for: .seconds(15))
        case .agentFiles: .agentFiles
        case .sentImages: .sentImages
        case .antigravity: .antigravity
        case .needsYouWithStatusBanner: .needsYouWithStatusBanner(after: .seconds(3))
        case .needsYouLater: .needsYouLater(after: .seconds(3))
        case .goesOffline: .goesOffline(after: .seconds(1), hangs: false)
        case .goesOfflineHanging: .goesOffline(after: .seconds(1), hangs: true)
        case .noNetwork: .goesOffline(after: .zero, hangs: true)
        }
    }
}
