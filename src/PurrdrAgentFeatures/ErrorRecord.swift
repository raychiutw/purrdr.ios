import Foundation
import PurrdrCore

/// 顯示給使用者的錯誤,記進診斷記錄的樣子(操作記錄):只有類別、錯誤碼、功能區與時間,**不含訊息原文**
/// (原文可能有主機名稱、路徑或權杖)。
public struct ErrorRecord: Equatable, Sendable {
    /// 錯誤類別:型別名(例如 `HostServiceError`);不是 Swift 錯誤的情境用領域名稱(例如 `HostKeyChanged`)。
    public var category: String
    /// 錯誤碼:case 名稱、herdr 的 code 或 NSError 的 code;
    public var code: String
    /// 功能區:顯示錯誤的畫面識別(例如 `NewChat`)。
    public var area: String
    public var at: Date

    public init(category: String, code: String, area: String, at: Date) {
        self.category = category
        self.code = code
        self.area = area
        self.at = at
    }
}

/// 從錯誤值取出可以記錄的類別與錯誤碼(不取關聯值裡的文字,herdr 的 code 除外)。
public struct ErrorDescriptor: Hashable, Sendable {
    public var category: String
    public var code: String

    public init(category: String, code: String) {
        self.category = category
        self.code = code
    }

    /// 型別名,巢狀型別帶外層(例如 `QueuedPrompt.Problem`),不帶 module 名稱。
    static func typeName(of error: any Error) -> String {
        let parts = String(reflecting: Swift.type(of: error)).split(separator: ".")
        return parts.count > 1 ? parts.dropFirst().joined(separator: ".") : parts.joined(separator: ".")
    }

    public init(_ error: any Error) {
        let mirror = Mirror(reflecting: error)
        let type = Self.typeName(of: error)
        if mirror.displayStyle == .enum {
            if case .herdr(let code, _)? = error as? HerdrError {
                // herdr 的錯誤碼是短識別字,可以留;訊息原文不留。
                self.init(category: type, code: code)
            } else if let payload = mirror.children.first {
                // 其他有關聯值的 case:只取 case 名稱。
                self.init(category: type, code: payload.label ?? "unspecified")
            } else {
                self.init(category: type, code: String(describing: error))
            }
        } else {
            let ns = error as NSError
            self.init(category: type, code: "\(ns.domain):\(ns.code)")
        }
    }
}

/// 同一個錯誤在畫面上持續顯示只記一次:以「顯示實例」記住目前顯示的內容指紋,
/// 指紋沒變(畫面重繪)不重複記,內容換了或消失後再出現才再記。指紋只在記憶體,不寫進記錄。
@MainActor
final class ErrorDisplayTracker {
    private var shown: [UUID: Int] = [:]

    /// 回傳這次顯示是否要記。
    func shouldRecord(instance: UUID, fingerprint: Int) -> Bool {
        if shown[instance] == fingerprint { return false }
        shown[instance] = fingerprint
        return true
    }

    func hidden(instance: UUID) { shown[instance] = nil }
}

/// 畫面上顯示的錯誤(#637):說明文字與記錄用的描述出自同一個值,畫面 model 保留它,
/// 顯示(`ErrorLabel`)與操作記錄都讀它,不必由文字反查。
public struct DisplayedError: Hashable, Sendable {
    /// 給使用者看的說明(不進記錄)。
    public let text: String
    /// 記錄用的類別與錯誤碼(不含訊息原文)。
    public let descriptor: ErrorDescriptor

    /// 由錯誤值產生說明與描述。
    public init(_ text: String, error: any Error) {
        self.text = text
        descriptor = ErrorDescriptor(error)
    }

    /// 不是 Swift 錯誤、但有明確領域類別的情境(例如主機身分變了、Agent 在對話紀錄回報的失敗)。
    public init(_ text: String, category: String, code: String) {
        self.text = text
        descriptor = ErrorDescriptor(category: category, code: code)
    }

    /// 以 `HostErrorText` 把錯誤值轉成白話說明。
    public init(
        error: any Error, connection: HostConfiguration.ConnectionMethod? = nil,
        authentication: HostConfiguration.OpenSSHAuthentication? = nil
    ) {
        self.init(HostErrorText.message(for: error, connection: connection, authentication: authentication), error: error)
    }
}
