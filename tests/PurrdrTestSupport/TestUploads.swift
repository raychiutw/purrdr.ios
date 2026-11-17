import Foundation
import PurrdrCore

/// 讀完一次 exec 收齊的輸出。
public struct CollectedOutput: Sendable {
    public var stdout = Data()
    public var stderr = Data()
    /// 沒收到結束狀態時是 `nil`。
    public var exitCode: Int32?

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

extension ExecSession {
    /// 讀到輸出結束，收齊 stdout、stderr 與 exit code。
    public func collectOutput() async throws -> CollectedOutput {
        var collected = CollectedOutput()
        for try await event in output {
            switch event {
            case .stdout(let chunk): collected.stdout.append(chunk)
            case .stderr(let chunk): collected.stderr.append(chunk)
            case .exit(let code, _): collected.exitCode = code
            }
        }
        return collected
    }
}

/// 上傳測試用的樣本資料。
public enum TestUploadData {
    /// 像文字檔的 bytes(`a`…`z` 每個字母連續 5 次再循環):gzip 壓得很小。
    public static func letters(count: Int) -> Data {
        Data((0..<count).map { UInt8(97 + ($0 / 5) % 26) })
    }
}
