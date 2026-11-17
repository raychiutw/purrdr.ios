import Foundation
import PurrdrCore
import PurrdrSSH

// 用 `Process` 跑系統的 `/usr/bin/gzip`,只在 macOS(`swift test`)提供。
#if os(macOS)

/// 系統的 `gzip`:檢查 gzip 封裝標準工具解得開，也當測試用的原始 DEFLATE 來源(不依賴 app 的實作)。
public enum StandardGzip {
    public struct Failure: Error {
        public var exitCode: Int32
    }

    /// `gzip -dc`。
    public static func decompress(_ data: Data) throws -> Data {
        try run(["-dc"], input: data)
    }

    /// `gzip -nc`(標頭不含檔名與時間)。
    public static func compress(_ data: Data) throws -> Data {
        try run(["-nc"], input: data)
    }

    /// stdin／stdout 經暫存檔(不用 pipe,大資料不會互等)。
    private static func run(_ arguments: [String], input: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appending(path: "purrdr-gzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appending(path: "input")
        let outputURL = directory.appending(path: "output")
        try input.write(to: inputURL)
        try Data().write(to: outputURL)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = arguments
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(exitCode: process.terminationStatus) }
        return try Data(contentsOf: outputURL)
    }
}

/// 從 `gzip -nc` 的輸出去掉 10 bytes 標頭與 8 bytes 結尾，得到原始 DEFLATE。
public struct StandardRawDeflate: RawDeflate {
    public init() {}

    public func deflate(_ data: Data) -> Data? {
        guard let gzip = try? StandardGzip.compress(data), gzip.count >= 18 else { return nil }
        return Data(gzip.dropFirst(10).dropLast(8))
    }
}

#endif
