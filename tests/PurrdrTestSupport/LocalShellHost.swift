import Foundation
import PurrdrCore

// 用 `Process` 在本機跑 shell,只在 macOS(`swift test`)提供。
#if os(macOS)

/// 在這台 Mac 上用 `/bin/sh -c` 真的執行指令的主機通道(只給測試用)。
///
/// 對話紀錄的讀取靠主機上的 POSIX 腳本(`TranscriptCommand`):用假主機只能比對字串，驗不出腳本本身對不對。
/// 這裡以暫存資料夾當家目錄，對真實檔案跑同一份腳本，量 byte 位置、剝圖片、權限錯誤等行為。
public struct LocalShellHost: HostChannel {
    public let home: URL

    /// - Parameter home: 腳本看到的 `$HOME`。
    public init(home: URL) {
        self.home = home
    }

    /// 建一個暫存的家目錄。
    public static func temporary() throws -> LocalShellHost {
        let home = FileManager.default.temporaryDirectory.appending(path: "purrdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return LocalShellHost(home: home)
    }

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
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if !out.isEmpty { continuation.yield(.stdout(out)) }
            if !err.isEmpty { continuation.yield(.stderr(err)) }
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

#endif
