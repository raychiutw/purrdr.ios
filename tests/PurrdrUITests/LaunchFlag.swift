import Foundation

/// 所有啟動旗標的單一清單(#698):app 端的 `LaunchConfiguration` 與 UI 測試的 `launchUITesting(flags:)` 共用這個列舉,
/// 拼錯旗標在編譯時就會被抓到。UI 測試以符號連結(`tests/PurrdrUITests/LaunchFlag.swift`)編進同一份檔案,
/// 所以這個檔案只能依賴 Foundation。
///
/// 新增旗標一定要有 UI 測試使用(`LaunchFlagUsageTests` 守門);沒有測試使用的旗標就不該存在。
public enum LaunchFlag: String, CaseIterable, Sendable {
    case demoAgentFiles = .demoAgentFiles
    case demoAntigravity = .demoAntigravity
    case demoCompanions = .demoCompanions
    case demoGoesOffline = .demoGoesOffline
    case demoGoesOfflineHanging = .demoGoesOfflineHanging
    case demoLargeOutput = .demoLargeOutput
    case demoLargeOutputOnPrompt = .demoLargeOutputOnPrompt
    case demoNeedsYouLater = .demoNeedsYouLater
    case demoNeedsYouWithStatusBanner = .demoNeedsYouWithStatusBanner
    case demoNoNetwork = .demoNoNetwork
    case demoOutdatedHostService = .demoOutdatedHostService
    case demoPaneInUse = .demoPaneInUse
    case demoSentImages = .demoSentImages
    case demoTailscaleCheck = .demoTailscaleCheck
    case demoTailscaleCheckCompletes = .demoTailscaleCheckCompletes
    case demoToolBurst = .demoToolBurst
    case demoTranscriptPending = .demoTranscriptPending
    case demoUsageReadDelayed = .demoUsageReadDelayed
    case demoWorkingAfterPrompt = .demoWorkingAfterPrompt
    case seedDataUsage = .seedDataUsage
    case seedHost = .seedHost
    case seedPairedHTTPSHost = .seedPairedHTTPSHost
    case seedReadOnlyHTTPSHost = .seedReadOnlyHTTPSHost
    case seedSlowHost = .seedSlowHost
    case seedUnpairedHTTPSHost = .seedUnpairedHTTPSHost
    case seedUnreachableHost = .seedUnreachableHost
    case selectDemo = .selectDemo
    case showWelcome = .showWelcome
    case uiTesting = .uiTesting
    case uiTestingAnimations = .uiTestingAnimations
    case uiTestingAppLock = .uiTestingAppLock
    case uiTestingCameraDenied = .uiTestingCameraDenied
    case uiTestingCrashRecord = .uiTestingCrashRecord
    case uiTestingExpiredMember = .uiTestingExpiredMember
    case uiTestingGooglePlayMember = .uiTestingGooglePlayMember
    case uiTestingGraceMember = .uiTestingGraceMember
    case uiTestingHostKeyPrompt = .uiTestingHostKeyPrompt
    case uiTestingKeepCrashNotice = .uiTestingKeepCrashNotice
    case uiTestingLargeImageClipboard = .uiTestingLargeImageClipboard
    case uiTestingLinkMerge = .uiTestingLinkMerge
    case uiTestingLinkMergeBlocked = .uiTestingLinkMergeBlocked
    case uiTestingManyRecentPhotos = .uiTestingManyRecentPhotos
    case uiTestingMember = .uiTestingMember
    case uiTestingMemberLoading = .uiTestingMemberLoading
    case uiTestingMemberOffline = .uiTestingMemberOffline
    case uiTestingNoHosts = .uiTestingNoHosts
    case uiTestingNoMember = .uiTestingNoMember
    case uiTestingNoPasscode = .uiTestingNoPasscode
    case uiTestingOversizedClipboard = .uiTestingOversizedClipboard
    case uiTestingOwnedByOtherMember = .uiTestingOwnedByOtherMember
    case uiTestingPairingScan = .uiTestingPairingScan
    case uiTestingPendingReviewMember = .uiTestingPendingReviewMember
    case uiTestingPlusMember = .uiTestingPlusMember
    case uiTestingPlusOff = .uiTestingPlusOff
    case uiTestingPushTestFails = .uiTestingPushTestFails
    case uiTestingRecentPhotos = .uiTestingRecentPhotos
    case uiTestingSignUp = .uiTestingSignUp
    case uiTestingSimulatedFileUpload = .uiTestingSimulatedFileUpload
    case uiTestingSimulatedVideo = .uiTestingSimulatedVideo
    case uiTestingUndoSend = .uiTestingUndoSend
    case uiTestingUpgradedMember = .uiTestingUpgradedMember
}
