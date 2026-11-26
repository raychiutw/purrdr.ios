import Foundation
import PurrdrCore
import Synchronization

/// 顯示給使用者的錯誤,記進診斷記錄的樣子(操作記錄):只有類別、錯誤碼、功能區與時間,**不含訊息原文**
/// (原文可能有主機名稱、路徑或權杖)。
public struct ErrorRecord: Equatable, Sendable {
    /// 錯誤類別:型別名(例如 `HostServiceError`);只有字串時是 `Message`。
    public var category: String
    /// 錯誤碼:case 名稱、herdr 的 code 或 NSError 的 code;不知道時是 `unspecified`。
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
public struct ErrorDescriptor: Equatable, Sendable {
    public var category: String
    public var code: String

    public init(category: String, code: String) {
        self.category = category
        self.code = code
    }

    /// 只有顯示字串、沒有錯誤值的呼叫端。
    public static let message = ErrorDescriptor(category: "Message", code: "unspecified")

    public init(_ error: any Error) {
        let mirror = Mirror(reflecting: error)
        let type = String(describing: Swift.type(of: error))
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

/// 「顯示字串 → 產生它的錯誤的類別與錯誤碼」對照(#637)。
///
/// 畫面只拿得到說明文字,但說明文字都是 `HostErrorText` 從錯誤值轉出來的;轉換當下把錯誤的類別與錯誤碼
/// 記在這裡(只在記憶體、最近 64 筆),`ErrorLabel` 沒有帶錯誤值時以顯示字串查回來。
/// 查不到(畫面自己寫的固定文字)才是 `ErrorDescriptor.message`。對照只存描述,不存也不外洩訊息原文。
package enum ErrorMessageRegistry {
    private struct State { var entries: [(message: String, descriptor: ErrorDescriptor)] = [] }
    private static let state = Mutex(State())
    private static let capacity = 64

    package static func note(_ message: String, _ descriptor: ErrorDescriptor) {
        state.withLock { state in
            state.entries.removeAll { $0.message == message }
            state.entries.append((message, descriptor))
            if state.entries.count > capacity { state.entries.removeFirst(state.entries.count - capacity) }
        }
    }

    package static func descriptor(for message: String) -> ErrorDescriptor? {
        state.withLock { $0.entries.last { $0.message == message }?.descriptor }
    }

    package static func reset() { state.withLock { $0.entries = [] } }
}
