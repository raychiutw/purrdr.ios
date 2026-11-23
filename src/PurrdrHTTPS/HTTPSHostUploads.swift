import Foundation
import PurrdrCore

/// HTTPS 主機上傳圖片與檔案(#288):主機服務的 `file.upload.start`／`file.upload.chunk` 分塊上傳。
/// 檔名由主機服務產生，app 只送副檔名;主機服務沒有這兩個訊息時丟 `HostServiceError.hostServiceUpdateRequired`。
extension HTTPSHostConnection: HostUploading {
    /// 期限是 `HostCommandDeadline.upload`(以 base64 後的大小估算);連線中斷是 `interrupted`。
    public func upload(_ data: Data, named name: HostUploadName) async throws -> String {
        try await upload(.data(data), named: name, progress: { _ in })
    }

    /// 分塊讀來源送出(不整份進記憶體)。主機服務沒有取消上傳的訊息:取消後主機上未完成的暫存檔在這條連線結束或主機的定期清理時刪除。
    public func upload(_ source: HostUploadSource, named name: HostUploadName, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard source.size <= HostUploadLimit.maximumFileSize else { throw HostUploadError.tooLarge }
        try await requireHostService(.fileUpload)
        let path: String
        do {
            path = try await withDeadline(HostCommandDeadline.upload(bytes: source.size * 4 / 3)) {
                try await self.transfer(source, extension: Self.fileExtension(of: name), progress: progress)
            }
        } catch HerdrError.deadlineExceeded {
            throw HostUploadError.deadlineExceeded
        } catch HostServiceError.connectionLost {
            throw HostUploadError.interrupted
        }
        guard HostPathSyntax.isAbsolute(path) else { throw HostUploadError.unexpectedPath(path) }
        return path
    }

    /// 開始上傳後依序送分塊(空檔案也送一塊空的，主機收滿才存檔);回傳最後一塊帶回的主機路徑。
    private func transfer(_ source: HostUploadSource, extension fileExtension: String?, progress: @Sendable (Double) -> Void) async throws -> String {
        let size = source.size
        let started = try await send { .fileUploadStart(.init(requestId: $0, size: size, extension: fileExtension)) }
        guard case .fileUploadStartResult(let start) = started else { throw HostServiceError.unexpectedResponse }
        var offset = 0
        while true {
            let end = min(offset + HostServiceProtocol.maximumFileChunk, size)
            try Task.checkCancellation()
            let bytes = try source.read(offset..<end).base64EncodedString()
            let chunkOffset = offset
            let reply = try await send {
                .fileUploadChunk(.init(requestId: $0, uploadId: start.uploadId, offset: chunkOffset, bytes: bytes))
            }
            guard case .fileUploadChunkResult(let result) = reply, result.received == end else {
                throw HostServiceError.unexpectedResponse
            }
            progress(size == 0 ? 1 : Double(end) / Double(size))
            if end == size {
                guard let path = result.path else { throw HostServiceError.unexpectedResponse }
                return path
            }
            offset = end
        }
    }

    /// `HostUploadName` 的副檔名(英數，1–16 字元);沒有時是 `nil`。
    private static func fileExtension(of name: HostUploadName) -> String? {
        let parts = name.value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : nil
    }
}
