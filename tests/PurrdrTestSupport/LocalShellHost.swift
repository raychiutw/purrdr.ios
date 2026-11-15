import Foundation
import PurrdrCore

// 用 `Process` 在本機跑 shell,只在 macOS(`swift test`)提供。
#if os(macOS)

/// 在這台 Mac 上用 `/bin/sh -c` 真的執行指令的主機通道(只給測試用)。
///
/// 對話紀錄的讀取、主機寫入(ADR-0002)都靠主機上的 POSIX 腳本：用假主機只能比對字串，驗不出腳本本身對不對。
/// 這裡以暫存資料夾當家目錄，對真實檔案跑同一份腳本——量 byte 位置、剝圖片、權限錯誤，
/// 或檢查「主機上的檔案真的被改成什麼、還原後是否與安裝前完全相同」(`DirectorySnapshot`)。
///
/// 安全：指令只拿到這個家目錄當 `HOME`;主機寫入的測試一律用 `temporary()`,絕不碰執行測試的人真正的家目錄。
/// stdin 是空的(`/dev/null`)。
public struct LocalShellHost: HostChannel {
    public let home: URL
    private let log = CommandLog()

    /// - Parameter home: 腳本看到的 `$HOME`。
    public init(home: URL) {
        self.home = home
    }

    /// 建一個暫存的家目錄。
    public static func temporary() throws -> LocalShellHost {
        let home = FileManager.default.temporaryDirectory.appending(path: "purrdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        precondition(home.resolvingSymlinksInPath().path != realHome, "暫存家目錄不能是真正的家目錄")
        return LocalShellHost(home: home)
    }

    /// 家目錄裡的路徑。
    public func url(_ relativePath: String) -> URL { home.appending(path: relativePath) }

    /// 執行過的指令(依序)。
    public var commands: [String] { log.commands }

    /// 在家目錄下寫一個檔案(自動建立資料夾)。
    @discardableResult
    public func write(_ data: Data, to relativePath: String) throws -> URL {
        let url = home.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// 在檔案結尾附加。
    public func append(_ data: Data, to relativePath: String) throws {
        let handle = try FileHandle(forWritingTo: home.appending(path: relativePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        log.append(command)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path(percentEncoded: false), "PATH": "/usr/bin:/bin"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let (stream, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        Thread.detachNewThread {
            // stdout、stderr 同時讀，任一邊塞滿 pipe 都不會卡住。
            let group = DispatchGroup()
            let err = DataBox()
            group.enter()
            DispatchQueue.global().async {
                err.data = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            if !out.isEmpty { continuation.yield(.stdout(out)) }
            if !err.data.isEmpty { continuation.yield(.stderr(err.data)) }
            continuation.yield(.exit(code: process.terminationStatus))
            continuation.finish()
        }
        return LocalExecSession(output: stream)
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw FakeHostError.unexpectedPTY(request)
    }
}

private struct LocalExecSession: ExecSession {
    let output: AsyncThrowingStream<ExecOutput, any Error>
    func write(_ data: Data) async throws {}
    func closeStdin() async {}
    func close() async {}
}

private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var commands: [String] { lock.withLock { entries } }
    func append(_ command: String) { lock.withLock { entries.append(command) } }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// 一個資料夾樹的完整樣子：每個項目的種類、內容、權限、symlink 目標。用來比對「還原後與安裝前完全相同」。
public struct DirectorySnapshot: Equatable, CustomStringConvertible {
    public enum Entry: Equatable {
        case directory(mode: Int)
        case file(contents: Data, mode: Int)
        case symlink(destination: String)
    }

    public var entries: [String: Entry]

    public init(of root: URL) throws {
        var entries: [String: Entry] = [:]
        let manager = FileManager.default
        for path in try manager.subpathsOfDirectory(atPath: root.path(percentEncoded: false)) {
            let full = root.appending(path: path).path(percentEncoded: false)
            let attributes = try manager.attributesOfItem(atPath: full)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                entries[path] = .symlink(destination: try manager.destinationOfSymbolicLink(atPath: full))
            case .typeDirectory?:
                entries[path] = .directory(mode: mode)
            default:
                entries[path] = .file(contents: try Data(contentsOf: URL(filePath: full)), mode: mode)
            }
        }
        self.entries = entries
    }

    public var description: String {
        entries.keys.sorted().map { path in
            switch entries[path]! {
            case .directory(let mode): "\(path)/ \(String(mode, radix: 8))"
            case .file(let contents, let mode): "\(path) \(String(mode, radix: 8)) \(String(decoding: contents, as: UTF8.self))"
            case .symlink(let destination): "\(path) -> \(destination)"
            }
        }.joined(separator: "\n")
    }
}

#endif
