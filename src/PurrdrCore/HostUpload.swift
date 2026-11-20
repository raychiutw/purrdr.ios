import Foundation

/// 上傳到主機(#286):把 bytes 放到主機的 Purrdr 上傳資料夾，回傳主機上的絕對路徑。圖片與一般檔案共用。
///
/// SSH 實作是 `PurrdrSSH.SSHHostUploader`(exec 的 stdin,ADR-0003);HTTPS 實作走主機服務的分塊上傳。
public protocol HostUploading: Sendable {
    func upload(_ data: Data, named name: HostUploadName) async throws -> String
}

/// 上傳到主機的檔名：`[A-Za-z0-9-]+`,可再接一個英數副檔名。
///
/// 檔名會原樣交給主機腳本、也會出現在 prompt 裡，所以在 app 端就擋掉其他字元。
public struct HostUploadName: Hashable, Sendable {
    public let value: String

    /// 原始檔名保留的最多字元數(不含時間、亂數與副檔名)。
    static let maximumStemLength = 40
    static let maximumExtensionLength = 16

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty, parts[0].allSatisfy(Self.isStemCharacter) else { return nil }
        if parts.count == 2 {
            guard (1...Self.maximumExtensionLength).contains(parts[1].count), parts[1].allSatisfy(Self.isAlphanumeric) else { return nil }
        }
        self.value = value
    }

    /// 圖片附件的檔名(`UploadFileName` 是它的子集)。
    public init(_ image: UploadFileName) {
        value = image.value
    }

    /// 一般檔案：`<時間(毫秒)base36>-<8 個 base36 亂數>-<原始檔名的英數字>.<小寫副檔名>`。
    /// 原始檔名的其他字元換成 `-`;沒有英數字時用 `file`。
    public static func make(original: String, date: Date, random: inout some RandomNumberGenerator) -> HostUploadName {
        let image = UploadFileName.make(date: date, random: &random).value
        let prefix = String(image.dropLast(".jpg".count))
        let (stem, fileExtension) = split(original)
        let base = "\(prefix)-\(stem)"
        return HostUploadName(fileExtension.map { "\(base).\($0)" } ?? base)!
    }

    /// 原始檔名 → 檔名主體(只有英數與 `-`)與副檔名(小寫英數，不合格就省略)。
    private static func split(_ original: String) -> (stem: String, fileExtension: String?) {
        var stemPart = Substring(original)
        var fileExtension: String?
        if let dot = original.lastIndex(of: ".") {
            let candidate = original[original.index(after: dot)...].lowercased()
            if (1...maximumExtensionLength).contains(candidate.count), candidate.allSatisfy(isAlphanumeric) {
                fileExtension = candidate
                stemPart = original[..<dot]
            }
        }
        var stem = ""
        for character in stemPart {
            if isAlphanumeric(character) {
                stem.append(character)
            } else if !stem.isEmpty, stem.last != "-" {
                stem.append("-")
            }
        }
        while stem.last == "-" { stem.removeLast() }
        stem = String(stem.prefix(maximumStemLength))
        while stem.last == "-" { stem.removeLast() }
        return (stem.isEmpty ? "file" : stem, fileExtension)
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func isStemCharacter(_ character: Character) -> Bool {
        isAlphanumeric(character) || character == "-"
    }
}

public enum HostUploadError: Error, Equatable {
    /// 連線在上傳途中斷了(或主機上的程序被訊號結束):主機上不會留下這個檔案。
    case interrupted
    /// 主機腳本失敗(非零 exit;例如磁碟滿、同名檔案已存在)。
    case failed(exitCode: Int32, message: String)
    /// 主機回傳的路徑不是絕對路徑或不以 `/<檔名>` 結尾:主機把檔案存到意外的位置。
    case unexpectedPath(String)
    case deadlineExceeded
    /// 超過上限(`HostUploadLimit.maximumFileSize`)。
    case tooLarge
}

/// 上傳到主機的限制。
public enum HostUploadLimit {
    /// 一般檔案的上限，沿用主機服務協定的檔案上限。圖片另有單張上限(`ImageUploadLimit`)。
    public static let maximumFileSize = HostServiceProtocol.maximumFileSize
}
