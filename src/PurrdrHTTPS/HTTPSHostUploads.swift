import Foundation
import PurrdrCore

/// HTTPS 主機上傳圖片與檔案(#288):主機服務的 `file.upload.start`／`file.upload.chunk` 分塊上傳。
/// 檔名由主機服務產生，app 只送副檔名;主機服務沒有這兩個訊息時丟 `HostServiceError.hostServiceUpdateRequired`。
extension HTTPSHostConnection: HostUploading {
    /// 期限是 `HostCommandDeadline.upload`(以 base64 後的大小估算);連線中斷是 `interrupted`。
    public func upload(_ data: Data, named name: HostUploadName) async throws -> String {
        guard data.count <= HostUploadLimit.maximumFileSize else { throw HostUploadError.tooLarge }
        try await requireHostService(.fileUpload)
        let path: String
        do {
            path = try await withDeadline(HostCommandDeadline.upload(bytes: data.count * 4 / 3)) {
                try await self.transfer(data, extension: Self.fileExtension(of: name))
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
    private func transfer(_ data: Data, extension fileExtension: String?) async throws -> String {
        let size = data.count
        let started = try await send { .fileUploadStart(.init(requestId: $0, size: size, extension: fileExtension)) }
        guard case .fileUploadStartResult(let start) = started else { throw HostServiceError.unexpectedResponse }
        var offset = 0
        while true {
            let end = min(offset + HostServiceProtocol.maximumFileChunk, size)
            let bytes = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)).base64EncodedString()
            let chunkOffset = offset
            let reply = try await send {
                .fileUploadChunk(.init(requestId: $0, uploadId: start.uploadId, offset: chunkOffset, bytes: bytes))
            }
            guard case .fileUploadChunkResult(let result) = reply, result.received == end else {
                throw HostServiceError.unexpectedResponse
            }
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
