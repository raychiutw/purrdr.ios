import Foundation
import PurrdrCore

/// 每輪的 Pane 畫面(#559):聊天輪詢裡所有要看 Pane 畫面的用途(提示、slash 面板、建議提示詞、即時預覽、
/// 背景 agents 窗格、狀態列、權限模式)都向這裡要;**同一輪最多讀一次**,後來的需求共用已讀到的畫面。
/// 指令預算(R-F01、#204)寫在這個 interface:用途只說「我要看畫面」,讀不讀、讀哪種格式由這裡決定,
/// 新增一種用途不會不小心多送一個主機指令。
///
/// - 一輪從 `begin()` 起算(聊天的 `poll()` 開頭);輪詢迴圈裡 `poll()` 之後的狀態列、權限模式探測屬於同一輪。
/// - 格式:`.suggestion` 要 ANSI(灰色建議只能從 dim 屬性認出來,#122),其他都是純文字。
///   已有 ANSI 畫面時,其他用途拿到的是去掉跳脫序列的版本;已讀過純文字就不為建議多讀,留到下一輪。
/// - 讀不到(主機離線、服務太舊…)**不快取**:同一輪下一個需求會再試一次,與原本各用途自己讀時的行為相同。
/// - 唯一的例外是 `.permissionModeVerify`:按了 Shift+Tab 之後要確認畫面真的變了,每次都重讀(讀到的畫面
///   也算這輪已讀)。
/// - 主機服務太舊讀不了畫面時,說明放在 `updateRequiredMessage`(讀得到就拿掉)。
@MainActor
package final class PaneScreenRound {
    /// 這次要用畫面做什麼。
    package enum Need: Equatable, Sendable, CaseIterable {
        /// 找「需要你」的提示。
        case prompt
        /// 找 slash 面板。
        case panel
        /// 找建議提示詞(要 ANSI)。
        case suggestion
        /// 工作中的即時預覽。
        case livePreview
        /// 背景 agents 窗格。
        case agentsPane
        /// 畫面最底下的狀態列(Antigravity)。
        case statusLine
        /// 認出目前的權限模式(不為了它重讀)。
        case permissionMode
        /// 按 Shift+Tab 之後確認權限模式:一律重讀。
        case permissionModeVerify

        fileprivate var format: PaneReadFormat { self == .suggestion ? .ansi : .text }
        fileprivate var alwaysReads: Bool { self == .permissionModeVerify }
    }

    private let readPane: @MainActor (PaneReadFormat) async throws -> String

    private var plain: String?
    private var ansi: String?
    /// 這一輪已經送出的 `pane.read` 數(給測試與診斷)。
    package private(set) var readCount = 0
    /// 主機服務太舊讀不了畫面時的說明;讀得到、或是其他原因失敗時為 `nil`。
    package private(set) var updateRequiredMessage: String?

    package init(read: @escaping @MainActor (PaneReadFormat) async throws -> String) {
        readPane = read
    }

    /// 這一輪已經有畫面可共用。
    package var hasScreen: Bool { plain != nil }

    /// 開始新的一輪:丟掉上一輪讀到的畫面。
    package func begin() {
        plain = nil
        ansi = nil
        readCount = 0
    }

    /// 已讀到的畫面作廢(例如讀取期間建議被清掉,舊畫面不適用)。
    package func invalidate() {
        plain = nil
        ansi = nil
    }

    /// 這個需求要的畫面:`.suggestion` 回含 ANSI 的原文,其他回純文字;讀不到、或建議在已讀過純文字的一輪
    /// 都是 `nil`。
    package func screen(for need: Need) async -> String? {
        if !need.alwaysReads, plain != nil {
            if need == .suggestion { return ansi }
            return plain
        }
        do {
            let screen = try await readPane(need.format)
            readCount += 1
            updateRequiredMessage = nil
            if need.format == .ansi {
                ansi = screen
                plain = Self.plainText(ansi: screen)
            } else {
                ansi = nil
                plain = screen
            }
            return need == .suggestion ? screen : plain
        } catch let error as HostServiceError {
            if case .hostServiceUpdateRequired = error { updateRequiredMessage = HostErrorText.hostServiceMessage(error) }
            return nil
        } catch {
            return nil
        }
    }

    /// 去掉跳脫序列與 `\r`:`.ansi` 畫面只差在跳脫序列與行尾,其他解析器吃的是純文字。
    package static func plainText(ansi screen: String) -> String {
        ANSIText.strip(screen).replacingOccurrences(of: "\r", with: "")
    }
}
