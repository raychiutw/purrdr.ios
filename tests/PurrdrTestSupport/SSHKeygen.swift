#if os(macOS)
import Foundation

/// 以本機 `ssh-keygen` 在暫存資料夾產生測試用金鑰(不碰 `~/.ssh`)。
public struct SSHKeygen {
    public let directory: URL
    public let privateText: String
    /// `ssh-keygen -y` 的輸出，去掉註解。
    public let publicKeyWithoutComment: String

    public static func generate(
        type: String, bits: Int? = nil, passphrase: String = "", cipher: String? = nil, format: String? = nil
    ) throws -> SSHKeygen {
        let directory = FileManager.default.temporaryDirectory.appending(path: "purrdr-keygen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "key")
        var arguments = ["-q", "-t", type, "-N", passphrase, "-C", "purrdr-test", "-f", file.path]
        if let bits { arguments += ["-b", String(bits)] }
        if let cipher { arguments += ["-Z", cipher] }
        if let format { arguments += ["-m", format] }
        try run(arguments)
        let derived = try run(["-y", "-P", passphrase, "-f", file.path])
        let fields = derived.split(separator: " ")
        return SSHKeygen(
            directory: directory, privateText: try String(contentsOf: file, encoding: .utf8),
            publicKeyWithoutComment: fields.prefix(2).joined(separator: " "))
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SSHKeygenError.failed(arguments) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SSHKeygenError: Error {
    case failed([String])
}
#endif
