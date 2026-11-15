#if os(macOS)
import Foundation
import PurrdrCore

/// 假主機的檔案系統版：在本機用真的 `/bin/sh` 執行 app 送出的指令，但 `HOME` 換成一個暫存資料夾。
///
/// 會寫入主機的功能(ADR-0002)要驗證的是「主機上的檔案真的被改成什麼、還原後是否完全相同」,
/// 只比對指令字串的 `FakeHost` 驗不到;這裡讓主機腳本真的跑，再直接檢查暫存家目錄裡的檔案。
///
/// 安全：指令只拿到暫存家目錄當 `HOME`,而且只接受 `NSTemporaryDirectory()` 底下的資料夾，
/// 絕不碰執行測試的人真正的家目錄。只在 macOS 提供(iOS 沒有 `Process`)。
public final class LocalShellHost: HostChannel {
    /// 暫存家目錄(主機上的 `~`)。
    public let home: URL
    public private(set) var commands: [String] {
        get { lock.withLock { _commands } }
        set { lock.withLock { _commands = newValue } }
    }
    private let lock = NSLock()
    nonisolated(unsafe) private var _commands: [String] = []

    /// 建立一個空的暫存家目錄。
    public init() throws {
        let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "purrdr-host-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // macOS 的暫存資料夾在 /var → /private/var,先解析，路徑比較才不會因 symlink 不同。
        home = base.resolvingSymlinksInPath()
        let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        precondition(home.path != realHome && home.lastPathComponent.hasPrefix("purrdr-host-"), "暫存家目錄不能是真正的家目錄")
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    /// 暫存家目錄裡的路徑。
    public func url(_ relative: String) -> URL { home.appending(path: relative) }

    public func execute(_ command: String) async throws -> any ExecSession {
        lock.withLock { _commands.append(command) }
        return try LocalExecSession(command: command, home: home)
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw FakeHostError.unexpectedPTY(request)
    }
}

extension LocalShellHost: @unchecked Sendable {}

/// 一次本機 `/bin/sh -c <指令>`。輸出在程序結束後一次送出(主機寫入的腳本不需要串流)。
private final class LocalExecSession: ExecSession, @unchecked Sendable {
    let output: AsyncThrowingStream<ExecOutput, any Error>
    private let process = Process()
    private let stdin = Pipe()

    init(command: String, home: URL) throws {
        let (stream, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        output = stream
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        // 只給最小的環境：家目錄是暫存資料夾，PATH 是系統預設。
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = home
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let process = self.process
        Thread.detachNewThread {
            let group = DispatchGroup()
            nonisolated(unsafe) var out = Data()
            nonisolated(unsafe) var err = Data()
            group.enter()
            DispatchQueue.global().async {
                out = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                err = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.wait()
            process.waitUntilExit()
            if !out.isEmpty { continuation.yield(.stdout(out)) }
            if !err.isEmpty { continuation.yield(.stderr(err)) }
            continuation.yield(.exit(code: process.terminationStatus))
            continuation.finish()
        }
    }

    func write(_ data: Data) async throws { try stdin.fileHandleForWriting.write(contentsOf: data) }
    func closeStdin() async { try? stdin.fileHandleForWriting.close() }
    func close() async {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
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
        let paths = try manager.subpathsOfDirectory(atPath: root.path)
        for path in paths {
            let full = root.appending(path: path).path
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
