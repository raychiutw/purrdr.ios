import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

// 主機清單 model 的依賴,收成有名字的四個群組(#565、spec #555)。
// app 入口只用 `HostsModel.init(_: HostsDependencies)`:每個欄位都必須給(沒有預設值),
// 正式與 UI 測試兩個環境 adapter 都要交齊,漏給會編譯失敗。測試用的有預設值的建構式是 `package` 層級。

/// 存放處:主機清單、各種本機偏好與快取。
public struct HostsStores {
    public var hosts: any HostStore
    public var selection: any HostSelectionStore
    public var currentHost: any CurrentHostStore
    public var planUsageSelection: any PlanUsageSelectionStore
    public var usageDisplay: UsageDisplaySetting
    public var hostPicker: any HostPickerStore
    public var chatPreferences: any HostChatPreferencesStore
    public var hostIcons: any HostIconStore
    public var conversationCache: any ConversationCache
    public var skeletonRowCounts: any SkeletonRowCountStore
    public var offlineQueues: any OfflineQueueStore
    /// 真主機的主機寫入同意。
    public var hostConsent: any HostWriteConsentStore
    /// Demo 主機的主機寫入同意(Demo 不持久化)。
    public var demoConsent: any HostWriteConsentStore

    public init(
        hosts: any HostStore, selection: any HostSelectionStore, currentHost: any CurrentHostStore,
        planUsageSelection: any PlanUsageSelectionStore, usageDisplay: UsageDisplaySetting, hostPicker: any HostPickerStore,
        chatPreferences: any HostChatPreferencesStore, hostIcons: any HostIconStore, conversationCache: any ConversationCache,
        skeletonRowCounts: any SkeletonRowCountStore, offlineQueues: any OfflineQueueStore,
        hostConsent: any HostWriteConsentStore, demoConsent: any HostWriteConsentStore
    ) {
        self.hosts = hosts
        self.selection = selection
        self.currentHost = currentHost
        self.planUsageSelection = planUsageSelection
        self.usageDisplay = usageDisplay
        self.hostPicker = hostPicker
        self.chatPreferences = chatPreferences
        self.hostIcons = hostIcons
        self.conversationCache = conversationCache
        self.skeletonRowCounts = skeletonRowCounts
        self.offlineQueues = offlineQueues
        self.hostConsent = hostConsent
        self.demoConsent = demoConsent
    }
}

/// Demo 主機與它的示範主機(Features 不 import Demo,由 composition root 交進來)。
public struct HostsDemo {
    public var channel: any HostChannel
    public var files: any HostFileFetching
    public var companions: [DemoCompanionHost]

    public init(channel: any HostChannel, files: any HostFileFetching, companions: [DemoCompanionHost]) {
        self.channel = channel
        self.files = files
        self.companions = companions
    }
}

/// 連線:通道工廠、憑證、HTTPS 主機服務與更新提示、Tailscale check 提示。
public struct HostsConnectivity {
    public var credentials: HostCredentials
    public var hostService: HostServiceAccess
    public var hostServiceUpdates: HostServiceUpdates
    public var tailscaleCheck: TailscaleCheckModel
    public var makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel

    public init(
        credentials: HostCredentials, hostService: HostServiceAccess, hostServiceUpdates: HostServiceUpdates,
        tailscaleCheck: TailscaleCheckModel,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.credentials = credentials
        self.hostService = hostService
        self.hostServiceUpdates = hostServiceUpdates
        self.tailscaleCheck = tailscaleCheck
        self.makeChannel = makeChannel
    }
}

/// 周邊服務:推播、附圖副本、模型目錄、診斷紀錄與等待。
public struct HostsServices {
    public var push: PushService?
    public var attachmentStore: any AttachmentStore
    /// 模型目錄的公開來源;`nil` 不連網路。
    public var publicModelCatalog: (any PublicModelCatalogFetching)?
    public var diagnostics: DiagnosticLog
    public var sleep: Sleep

    public init(
        push: PushService?, attachmentStore: any AttachmentStore, publicModelCatalog: (any PublicModelCatalogFetching)?,
        diagnostics: DiagnosticLog, sleep: @escaping Sleep
    ) {
        self.push = push
        self.attachmentStore = attachmentStore
        self.publicModelCatalog = publicModelCatalog
        self.diagnostics = diagnostics
        self.sleep = sleep
    }
}

/// `HostsModel` 的全部依賴。
public struct HostsDependencies {
    public var stores: HostsStores
    public var demo: HostsDemo
    public var connectivity: HostsConnectivity
    public var services: HostsServices

    public init(stores: HostsStores, demo: HostsDemo, connectivity: HostsConnectivity, services: HostsServices) {
        self.stores = stores
        self.demo = demo
        self.connectivity = connectivity
        self.services = services
    }
}

extension HostsModel {
    /// app 入口用的建構式:依賴一次給齊、沒有預設值。
    public convenience init(_ dependencies: HostsDependencies) {
        let stores = dependencies.stores
        let connectivity = dependencies.connectivity
        let services = dependencies.services
        self.init(
            store: stores.hosts, demoChannel: dependencies.demo.channel, demoFiles: dependencies.demo.files,
            demoCompanions: dependencies.demo.companions, conversationCache: stores.conversationCache,
            preferences: stores.chatPreferences, hostIcons: stores.hostIcons, selectionStore: stores.selection,
            currentHost: stores.currentHost, planUsageSelection: stores.planUsageSelection, usageDisplay: stores.usageDisplay,
            hostPicker: stores.hostPicker, demoConsent: stores.demoConsent, hostConsent: stores.hostConsent,
            credentials: connectivity.credentials, hostService: connectivity.hostService,
            hostServiceUpdates: connectivity.hostServiceUpdates, push: services.push, tailscaleCheck: connectivity.tailscaleCheck,
            attachmentStore: services.attachmentStore, skeletonRowCounts: stores.skeletonRowCounts,
            offlineQueues: stores.offlineQueues, diagnostics: services.diagnostics,
            publicModelCatalog: services.publicModelCatalog, sleep: services.sleep, makeChannel: connectivity.makeChannel)
    }
}
