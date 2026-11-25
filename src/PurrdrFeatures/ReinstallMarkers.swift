import Foundation
import PurrdrCore
import Security

/// UserDefaults 的「裝過新版」標記(刪 App 時一起消失)。
public struct UserDefaultsInstallMarker: InstallMarker, @unchecked Sendable {
    public static let key = "purrdr.installMarker"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isMarked: Bool { defaults.bool(forKey: Self.key) }
    public func mark() { defaults.set(true, forKey: Self.key) }
}

/// Keychain 的「裝過新版」標記(僅此裝置、不同步;刪 App 後仍在)。
public struct KeychainInstallMarker: InstallMarker {
    public static let service = "com.raychiu.purrdr.install-marker"
    private let keychain: any KeychainAPI

    public init(keychain: any KeychainAPI = SystemKeychain()) {
        self.keychain = keychain
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "marker",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public var isMarked: Bool {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        return keychain.copyMatching(request).0 == errSecSuccess
    }

    public func mark() {
        var attributes = query
        attributes[kSecValueData as String] = Data([1])
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = keychain.add(attributes)
    }
}

/// 重裝時要清掉的 App Keychain 項目(以 service 為單位;不含標記本身)。
public enum AppKeychainPurge {
    public static let services = [
        "com.raychiu.purrdr.host",
        "com.raychiu.purrdr.host-secret",
        "com.raychiu.purrdr.device-key",
        "com.raychiu.purrdr.device-token",
        "com.raychiu.purrdr",
        "purrdr.offlineQueue",
    ]

    public static func purge(keychain: any KeychainAPI) {
        for service in services {
            _ = keychain.delete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecUseDataProtectionKeychain as String: true,
            ])
        }
    }
}

extension ReinstallGuard {
    /// 正式用:UserDefaults 與 Keychain 各一個標記,重裝時清掉 `AppKeychainPurge.services`。
    public static func system(defaults: UserDefaults = .standard, keychain: any KeychainAPI = SystemKeychain()) -> ReinstallGuard {
        ReinstallGuard(
            defaults: UserDefaultsInstallMarker(defaults: defaults), keychain: KeychainInstallMarker(keychain: keychain),
            purge: { AppKeychainPurge.purge(keychain: keychain) })
    }
}
