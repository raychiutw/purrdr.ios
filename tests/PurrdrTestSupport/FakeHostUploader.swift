import Foundation
import PurrdrCore

/// 測試用的上傳到主機(#286):記下收到的檔名與 bytes,回傳 `/home/me/.purrdr/uploads/<檔名>`;`failure` 設了就丟它。
public actor FakeHostUploader: HostUploading {
    public static let folder = "/home/me/.purrdr/uploads"

    public private(set) var uploads: [(name: HostUploadName, data: Data)] = []
    private var failure: (any Error)?

    public init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    public func fail(with error: (any Error)?) {
        failure = error
    }

    private var holds = false

    /// 之後的來源上傳先回報 50% 進度,然後停住直到被取消(模擬大檔上傳進行中)。
    public func hold() { holds = true }

    public func upload(_ source: HostUploadSource, named name: HostUploadName, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        if let failure { throw failure }
        progress(0.5)
        if holds {
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        let path = try await upload(source.read(0..<source.size), named: name)
        progress(1)
        return path
    }

    public func upload(_ data: Data, named name: HostUploadName) async throws -> String {
        if let failure { throw failure }
        uploads.append((name, data))
        return "\(Self.folder)/\(name.value)"
    }
}
