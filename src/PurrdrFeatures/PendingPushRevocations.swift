import Foundation
import PurrdrCore
import Security
import Synchronization

/// 待撤銷的推播配對清單(#691):撤銷後台配對失敗(離線、後台暫時連不上)的 key hash 先記在這裡,
/// 啟動與網路恢復時重送,成功才移除。key hash 本身就能撤銷配對,屬機密:不進 log、診斷與備份。
public protocol PendingPushRevocations: AnyObject, Sendable {
    var keyHashes: [String] { get }
    func add(_ keyHash: String)
    func remove(_ keyHash: String)
}

/// 記憶體實作(測試、UI 測試)。
public final class InMemoryPendingPushRevocations: PendingPushRevocations {
    private let stored = Mutex<[String]>([])
    public init() {}
    public var keyHashes: [String] { stored.withLock { $0 } }
    public func add(_ keyHash: String) {
        stored.withLock { if !$0.contains(keyHash) { $0.append(keyHash) } }
    }
    public func remove(_ keyHash: String) { stored.withLock { $0.removeAll { $0 == keyHash } } }
}

/// 存 Keychain 的單一項目(JSON 陣列),可存取等級「第一次解鎖後、僅此裝置」,不經 iCloud 同步。
/// 選「第一次解鎖後」是因為背景啟動時也可能重送;讀寫失敗當作沒有(撤銷是盡力而為,下次再試)。
public final class KeychainPendingPushRevocations: PendingPushRevocations, @unchecked Sendable {
    private let keychain: any KeychainAPI
    private let service: String
    private let lock = NSLock()
    static let account = "push.pendingRevocations"

    public init(keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr.push-revocations") {
        self.keychain = keychain
        self.service = service
    }

    public var keyHashes: [String] {
        lock.withLock { read() }
    }

    public func add(_ keyHash: String) {
        lock.withLock {
            var current = read()
            guard !current.contains(keyHash) else { return }
            current.append(keyHash)
            write(current)
        }
    }

    public func remove(_ keyHash: String) {
        lock.withLock {
            let current = read()
            guard current.contains(keyHash) else { return }
            write(current.filter { $0 != keyHash })
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func read() -> [String] {
        var lookup = query
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecReturnData as String] = true
        let (status, result) = keychain.copyMatching(lookup)
        guard status == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func write(_ hashes: [String]) {
        guard !hashes.isEmpty else {
            _ = keychain.delete(query)
            return
        }
        guard let data = try? JSONEncoder().encode(hashes) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Purrdr pending push revocations"
        let status = keychain.add(item)
        if status == errSecDuplicateItem {
            _ = keychain.update(query, [kSecValueData as String: data])
        }
    }
}
