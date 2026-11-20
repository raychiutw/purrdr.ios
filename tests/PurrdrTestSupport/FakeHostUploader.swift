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

    public func upload(_ data: Data, named name: HostUploadName) async throws -> String {
        if let failure { throw failure }
        uploads.append((name, data))
        return "\(Self.folder)/\(name.value)"
    }
}
