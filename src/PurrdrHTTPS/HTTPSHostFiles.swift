import Foundation
import PurrdrCore

/// HTTPS 主機取檔(#227):主機服務的 `file.stat`／`file.read`。只送路徑：工作目錄由主機服務自己從 herdr snapshot 取，
/// 存取規則以主機服務為準(`target.root` 不送)。主機服務沒有這兩個訊息(`HostServiceFeature.fileFetch`)時回 `unsupported` 不送出。
extension HTTPSHostConnection: HostFileFetching {
    public func status(of target: HostFileTarget) async throws -> HostFileStatus {
        try await requireFileFetch()
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .fileStat(.init(requestId: $0, path: target.path)) }
        }
        guard case .fileStatResult(let result) = reply else { throw HostFileFetchError.failed("unexpected reply to file.stat") }
        if result.status == .file {
            guard let version = result.version, let size = result.size else { throw HostFileFetchError.failed("file status without version") }
            return .file(version: HostFileVersion(checksum: version), size: size)
        }
        return Self.unavailableStatus(result.status, size: result.size)
    }

    public func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data {
        try await requireFileFetch()
        let reply = try await withDeadline(HostCommandDeadline.transfer(bytes: length * 4 / 3)) {
            try await self.send {
                .fileRead(.init(requestId: $0, path: target.path, version: version.checksum, offset: offset, length: length))
            }
        }
        guard case .fileReadResult(let result) = reply else { throw HostFileFetchError.failed("unexpected reply to file.read") }
        guard result.status == .file else { throw HostFileFetchError.unavailable(Self.unavailableStatus(result.status, size: result.size)) }
        guard result.offset == offset else { throw HostFileFetchError.failed("chunk at an unexpected offset") }
        guard let bytes = result.bytes, let data = Data(base64Encoded: bytes) else { throw HostFileFetchError.failed("malformed chunk") }
        return data
    }

    /// 版本不足仍回 `HostFileFetchError.unsupported`:檔案卡片的說明不變。
    private func requireFileFetch() async throws {
        do {
            try await requireHostService(.fileFetch)
        } catch HostServiceError.hostServiceUpdateRequired {
            throw HostFileFetchError.unsupported
        }
    }

    private static func unavailableStatus(_ status: HostServiceProtocol.FileStatus, size: Int?) -> HostFileStatus {
        switch status {
        case .file, .unreadable: .unreadable
        case .missing: .missing
        case .notRegularFile: .notRegularFile
        case .denied: .denied
        case .tooLarge: .tooLarge(size: size ?? 0)
        }
    }
}
