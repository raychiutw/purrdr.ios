import Foundation

/// 主機檔案指令的「主機端」:把 app 送出的指令還原成要做的事，並產生主機腳本格式的輸出。
///
/// 只給 Demo 主機用(它不執行 shell,而是對真正 client 送出的精確指令回應，行為規格 F21)。
public enum HostFileRequest: Equatable, Sendable {
    case read([HostPath])
    case apply([HostFileChange])

    /// 主機腳本的 exit code。
    public enum ExitCode {
        public static let changedSinceRead: Int32 = 3
        public static let missingDirectory: Int32 = 4
    }

    /// 認得的指令才回傳;其他指令(例如 herdr bridge)是 `nil`。
    public init?(command: String) {
        if let arguments = Self.arguments(of: command, script: HostFileScript.read) {
            self = .read(arguments.map { HostPath($0) })
            return
        }
        guard let arguments = Self.arguments(of: command, script: HostFileScript.apply), arguments.count % 5 == 0 else { return nil }
        var changes: [HostFileChange] = []
        for start in stride(from: 0, to: arguments.count, by: 5) {
            let group = Array(arguments[start..<start + 5])
            let path = HostPath(group[1])
            let expectation: HostFileExpectation = switch group[2] {
            case "any": .anything
            case "missing": .missing
            default: .version(HostFileVersion(checksum: group[2]))
            }
            switch group[0] {
            case "put":
                guard let data = Data(base64Encoded: group[3]) else { return nil }
                changes.append(.write(path, data, executable: group[4] == "1", expecting: expectation))
            case "del":
                changes.append(.delete(path, expecting: expectation))
            case "rmtree":
                changes.append(.removeDirectory(path))
            case "mkdir":
                changes.append(.makeDirectory(path))
            case "rmdir":
                changes.append(.removeEmptyDirectory(path))
            default:
                return nil
            }
        }
        self = .apply(changes)
    }

    private static func arguments(of command: String, script: String) -> [String]? {
        let prefix = HostFileScript.command(script, arguments: [])
        guard command == prefix || command.hasPrefix(prefix + " ") else { return nil }
        return PosixShell.unquote(String(command.dropFirst(prefix.count)))
    }

    /// 讀取指令的輸出(與主機腳本相同的格式),`files` 依請求的順序。
    public static func readOutput(user: String, files: [HostFileState]) -> Data {
        var output = Data("purrdr-files 1\nuser \(user)\n".utf8)
        for (index, state) in files.enumerated() {
            switch state {
            case .missing: output += Data("missing \(index)\n".utf8)
            case .missingDirectory: output += Data("nodir \(index)\n".utf8)
            case .notRegularFile: output += Data("other \(index)\n".utf8)
            case .unreadable: output += Data("unreadable \(index)\n".utf8)
            case .tooLarge: output += Data("toolarge \(index)\n".utf8)
            case .file(let data, let version):
                output += Data("file \(index) \(version.checksum) \(data.count)\n".utf8) + data + Data("\n".utf8)
            }
        }
        return output
    }

    /// 寫入因檔案被改過而拒絕時的輸出(exit code `ExitCode.changedSinceRead`)。
    public static func changedSinceReadOutput(_ path: HostPath) -> Data { Data("changed \(path.relative)\n".utf8) }
    /// 寫入因資料夾不存在而拒絕時的輸出(exit code `ExitCode.missingDirectory`)。
    public static func missingDirectoryOutput(_ path: HostPath) -> Data { Data("nodir \(path.relative)\n".utf8) }
}

extension PosixShell {
    /// `quote` 的反向：把以空白分隔、每個都用單引號包住(內部單引號寫成 `'"'"'`)的參數還原。
    static func unquote(_ text: String) -> [String]? {
        var arguments: [String] = []
        var current: String?
        var rest = text[...]
        while let character = rest.first {
            rest = rest.dropFirst()
            switch character {
            case " ":
                if let argument = current { arguments.append(argument) }
                current = nil
            case "'", "\"":
                guard let end = rest.firstIndex(of: character) else { return nil }
                current = (current ?? "") + rest[..<end]
                rest = rest[rest.index(after: end)...]
            default:
                return nil
            }
        }
        if let argument = current { arguments.append(argument) }
        return arguments
    }
}
