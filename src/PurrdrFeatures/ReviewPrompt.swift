import Foundation

/// 請求評分的紀錄：成功送出的 prompt 數、已經請求過評分的 app 版本。
@MainActor
public protocol ReviewPromptStore: AnyObject {
    var deliveredPrompts: Int { get set }
    var requestedVersion: String? { get set }
}

@MainActor
public final class InMemoryReviewPromptStore: ReviewPromptStore {
    public var deliveredPrompts = 0
    public var requestedVersion: String?

    public init() {}
}

@MainActor
public final class UserDefaultsReviewPromptStore: ReviewPromptStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let deliveredKey = "reviewPrompt.deliveredPrompts"
    static let versionKey = "reviewPrompt.requestedVersion"

    public var deliveredPrompts: Int {
        get { defaults.integer(forKey: Self.deliveredKey) }
        set { defaults.set(newValue, forKey: Self.deliveredKey) }
    }

    public var requestedVersion: String? {
        get { defaults.string(forKey: Self.versionKey) }
        set { defaults.set(newValue, forKey: Self.versionKey) }
    }
}

/// 成功送出幾次 prompt 後請求評分(#34;HIG Onboarding:「先讓人體驗，再請求評分」)。
///
/// 系統的 `requestReview` 自己決定要不要真的跳出(一年最多三次),app 只決定時機：
/// 主機收下第 `threshold` 個 prompt 時請求，同一個 app 版本只請求一次;換版本後重新計數。
@MainActor
public final class ReviewPrompt {
    public static let threshold = 3

    private let store: any ReviewPromptStore
    private let appVersion: String
    private let request: @MainActor () -> Void

    /// - Parameter request: 真正請求評分(app 以 StoreKit 的 `AppStore.requestReview(in:)` 實作)。
    public init(store: any ReviewPromptStore, appVersion: String, request: @escaping @MainActor () -> Void) {
        self.store = store
        self.appVersion = appVersion
        self.request = request
    }

    /// 主機收下了一個 prompt。
    public func promptDelivered() {
        guard store.requestedVersion != appVersion else { return }
        store.deliveredPrompts += 1
        guard store.deliveredPrompts >= Self.threshold else { return }
        store.deliveredPrompts = 0
        store.requestedVersion = appVersion
        request()
    }
}
