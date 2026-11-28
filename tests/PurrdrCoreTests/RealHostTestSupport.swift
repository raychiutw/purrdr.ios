import Foundation
import PurrdrCore

/// 真主機整合測試共用的小工具(#694):寫入只在主機暫存資料夾、清理一定執行、指紋必填、配對來的權杖測完撤銷。
/// 真主機測試預設略過,這裡的邏輯由 `RealHostTestSupportTests` 在 `swift test` 驗證。

/// 主機上的暫存資料夾 `<TMPDIR 或 /tmp>/purrdr-test-<8 碼亂數>`:測試只寫在這裡,不碰家目錄。
enum RealHostScratch {
    static let prefix = "purrdr-test-"

    static func makeName() -> String {
        prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    /// 名稱是 `purrdr-test-` 加至少 1 個小寫英數字。
    static func isTestFolderName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 建立資料夾並印出它的絕對路徑。
    static func createCommand(name: String) -> String {
        precondition(isTestFolderName(name))
        return "d=\"${TMPDIR:-/tmp}\"; d=\"${d%/}/\(name)\"; mkdir -p \"$d\" && printf '%s' \"$d\""
    }

    /// 刪除指令;只接受絕對路徑、最後一段是測試資料夾、沒有 `..` 與任何引號或空白,否則 `nil`。
    static func removeCommand(path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("//"),
              !path.contains(where: { $0.isWhitespace || "'\"`$;&|<>\\*?~".contains($0) }),
              let last = path.split(separator: "/").last, isTestFolderName(String(last)),
              path.split(separator: "/").count >= 2
        else { return nil }
        return "rm -rf '\(path)'"
    }
}

/// 收集清理動作,主體結束(成功、丟錯或被取消)後以後進先出執行,長駐腳本的通道也在這裡關。
actor RealHostCleanup {
    private var actions: [@Sendable () async -> Void] = []

    func add(_ action: @escaping @Sendable () async -> Void) { actions.append(action) }

    private func runAll() async {
        while let action = actions.popLast() { await action() }
    }

    static func run<T>(_ body: (RealHostCleanup) async throws -> T) async throws -> T {
        let cleanup = RealHostCleanup()
        do {
            let value = try await body(cleanup)
            await cleanup.runAll()
            return value
        } catch {
            // 取消時清理也要完整跑完,所以放進不繼承取消的 task。
            await Task.detached { await cleanup.runAll() }.value
            throw error
        }
    }
}

/// 真主機測試的開關:指紋必填。
enum RealHostGate {
    static let fingerprintKey = "PURRDR_REAL_HOST_FINGERPRINT"

    static func fingerprint(from environment: [String: String]) -> HostKeyFingerprint? {
        guard let text = environment[fingerprintKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return HostKeyFingerprint(stored: text)
    }

    /// 要有主機也要有指紋;沒有指紋就略過,不連線、不信任第一次看到的金鑰。
    static func sshEnabled(from environment: [String: String]) -> Bool {
        environment["PURRDR_REAL_HOST"] != nil && fingerprint(from: environment) != nil
    }
}

/// HTTPS 測試的權杖:配對碼換來的在結束時撤銷(包含失敗),既有權杖不動。
enum RealHostToken {
    struct Missing: Error {}

    static func with<T>(
        environment: [String: String], pair: () async throws -> String, revoke: @escaping @Sendable (String) async -> Void,
        _ body: (String) async throws -> T
    ) async throws -> T {
        if environment["PURRDR_HTTPS_PAIRING_CODE"] != nil {
            let token = try await pair()
            do {
                let value = try await body(token)
                await revoke(token)
                return value
            } catch {
                await Task.detached { await revoke(token) }.value
                throw error
            }
        }
        guard let token = environment["PURRDR_HTTPS_TOKEN"] else { throw Missing() }
        return try await body(token)
    }
}
