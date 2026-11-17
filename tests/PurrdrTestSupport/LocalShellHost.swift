import Foundation
import PurrdrCore
import PurrdrSSH

// 用 `Process` 在本機跑 shell,只在 macOS(`swift test`)提供。
#if os(macOS)

/// 在這台 Mac 上用 `/bin/sh -c` 真的執行指令的主機通道(只給測試用)。
///
/// 對話紀錄的讀取、主機寫入(ADR-0002)都靠主機上的 POSIX 腳本：用假主機只能比對字串，驗不出腳本本身對不對。
/// 這裡以暫存資料夾當家目錄，對真實檔案跑同一份腳本——量 byte 位置、剝圖片、權限錯誤，
/// 或檢查「主機上的檔案真的被改成什麼、還原後是否與安裝前完全相同」(`DirectorySnapshot`)。
///
/// 安全：指令只拿到這個家目錄當 `HOME`;主機寫入的測試一律用 `temporary()`,絕不碰執行測試的人真正的家目錄。
/// stdin 預設是空的(`/dev/null`);`feedsStdin: true` 時 `write` 的 bytes 會進到指令的 stdin
/// (圖片上傳走 exec 的 stdin,ADR-0003),`closeStdin()` 送 EOF,`close()` 模擬連線中斷(stdin 結束、不再讀輸出)。
public struct LocalShellHost: HostChannel {
    public let home: URL
    public let feedsStdin: Bool
    private let log = CommandLog()

    /// - Parameter home: 腳本看到的 `$HOME`。
    public init(home: URL, feedsStdin: Bool = false) {
        self.home = home
        self.feedsStdin = feedsStdin
    }

    /// 建一個暫存的家目錄。
    public static func temporary(feedsStdin: Bool = false) throws -> LocalShellHost {
        let home = FileManager.default.temporaryDirectory.appending(path: "purrdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        precondition(home.resolvingSymlinksInPath().path != realHome, "暫存家目錄不能是真正的家目錄")
        return LocalShellHost(home: home, feedsStdin: feedsStdin)
    }

    /// 等到所有執行過的指令都結束(例如連線中斷後，主機上的腳本自己收尾)。
    public func waitUntilFinished(timeout: Duration = asyncWaitLimit) async {
        let deadline = ContinuousClock.now + timeout
        while log.hasRunningProcess, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        let input = feedsStdin ? Pipe() : nil
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()
        log.started(process)
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
        return LocalExecSession(output: stream, stdin: input.map { StdinBox(handle: $0.fileHandleForWriting) })
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw FakeHostError.unexpectedPTY(request)
    }
}

private struct LocalExecSession: ExecSession {
    let output: AsyncThrowingStream<ExecOutput, any Error>
    let stdin: StdinBox?

    func write(_ data: Data) async throws { try stdin?.write(data) }
    func closeStdin() async { stdin?.close() }
    func close() async { stdin?.close() }
}

/// 指令的 stdin 寫入端;關過就不再寫(模擬 SSH 通道關閉後寫入失敗)。
private final class StdinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(handle: FileHandle) {
        // 腳本提早結束後再寫會收到 SIGPIPE:忽略它，讓寫入丟錯誤而不是結束整個測試程序。
        signal(SIGPIPE, SIG_IGN)
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard let handle else { throw FakeHostError.writeAfterClose }
            try handle.write(contentsOf: data)
        }
    }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}

private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var processes: [Process] = []

    var commands: [String] { lock.withLock { entries } }
    var hasRunningProcess: Bool { lock.withLock { processes.contains { $0.isRunning } } }
    func append(_ command: String) { lock.withLock { entries.append(command) } }
    func started(_ process: Process) { lock.withLock { processes.append(process) } }
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
