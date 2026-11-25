import Foundation
import PurrdrCore
import UIKit

/// `BackgroundTaskScheduling` 的 iOS 實作(#551):`beginBackgroundTask` 與計時。
/// 同時追蹤裝置是否鎖定:鎖屏時系統先送 `protectedDataWillBecomeUnavailable`(早於 scenePhase 變 background)。
@MainActor
final class SystemBackgroundTaskScheduler: BackgroundTaskScheduling {
    private var lockedByNotification = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockedByNotification = true }
            },
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockedByNotification = false }
            },
        ]
    }

    var isDeviceLocked: Bool {
        lockedByNotification || !UIApplication.shared.isProtectedDataAvailable
    }

    func begin(expiration: @escaping @MainActor () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: "connections.retain") {
            MainActor.assumeIsolated { expiration() }
        }
        return id == .invalid ? nil : id.rawValue
    }

    func end(_ task: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: task))
    }

    func remainingTime() -> TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }

    func schedule(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) -> () -> Void {
        let work = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            fire()
        }
        return { work.cancel() }
    }
}
