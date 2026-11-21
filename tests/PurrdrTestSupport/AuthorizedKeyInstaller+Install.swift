import Foundation
import PurrdrCore
import PurrdrSSH

/// 用密碼加入公鑰的結果。
package enum AuthorizedKeyInstallOutcome: Sendable, Equatable {
    case added
    /// 同一把公鑰已在檔案裡，沒有寫入。
    case alreadyPresent
}

/// 把公鑰寫進主機的 `authorized_keys`。正式 app 已不寫入(引導給使用者可拷貝的指令),
/// 只留 `restore` 還原舊版 app 加的那一行;這裡的寫入只用來在測試裡準備「舊版 app 加過公鑰」的主機狀態。
extension AuthorizedKeyInstaller {
    @discardableResult
    package func install(_ key: SSHPublicKey) async throws -> AuthorizedKeyInstallOutcome {
        let recordPath = Self.feature.ownFile(Self.administratorRecordName)
        let inspection = try await write.inspect(also: [recordPath])
        if inspection.read.isWindows, case .administrator(let current) = try await readAdministrator() {
            if Self.contains(key, in: current) { return .alreadyPresent }
            let installed = Self.appending(key, to: current ?? Data(), lineEnding: "\r\n")
            // 重複安裝沿用第一次的備份。
            let original = Self.administratorRecord(in: inspection).map(\.original) ?? current
            let record = try JSONEncoder().encode(AdministratorRecord(original: original, installed: installed))
            try await write.install(also: [recordPath]) { _ in
                HostWritePlan(userFiles: [:], ownFiles: [Self.administratorRecordName: .init(record)])
            }
            try await writeAdministrator(expected: current, contents: installed)
            return .added
        }
        if Self.contains(key, in: inspection.read[Self.authorizedKeysPath]?.contents) { return .alreadyPresent }
        try await write.install { inspection in
            let current = inspection.read[Self.authorizedKeysPath]?.contents ?? Data()
            return HostWritePlan(userFiles: [Self.authorizedKeysPath: Self.appending(key, to: current)], ownFiles: [:])
        }
        return .added
    }

    private static func contains(_ key: SSHPublicKey, in data: Data?) -> Bool {
        guard let data else { return false }
        let wanted = key.openSSH.split(separator: " ").prefix(2).map(String.init)
        guard wanted.count == 2 else { return false }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            // 前面可能有選項(例如 `from="…"`):找相鄰的演算法與 base64。
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.indices.dropLast().contains(where: { fields[$0] == wanted[0] && fields[$0 + 1] == wanted[1] }) { return true }
        }
        return false
    }

    private static func appending(_ key: SSHPublicKey, to current: Data, lineEnding: String = "\n") -> Data {
        var updated = current
        if let last = current.last, last != 0x0A { updated.append(Data(lineEnding.utf8)) }
        updated.append(Data((key.openSSH + lineEnding).utf8))
        return updated
    }
}
