import Foundation
import Observation
import PurrdrCore

/// 終端機畫面的連線狀態(Pane 終端機與登入 Shell 共用)。
public enum TerminalStatus: Equatable, Sendable {
    /// 畫面還沒回報格數，還不能開連線(開連線要帶格數)。
    case waitingForSize
    case connecting
    case connected
    /// 連線斷了或已掛斷，可以重新連線。
    case disconnected
    /// 已經有別的 client 在操作這個 Pane,要「接管」才能接上(只有 Pane 終端機)。
    case inUse
    /// 別的 client 接管走了(只有 Pane 終端機)。
    case takenOver
    /// 程式(Pane 裡的程式或登入 shell)結束了。
    case ended
    /// 開不起來，重試也不會成功;附上原因。
    case unavailable(String)
}

/// 終端機畫面(`TerminalSessionView`)需要的 model:Pane 終端機(`PaneTerminalModel`,herdr 的
/// `terminal session control`)與登入 Shell(`LoginShellModel`,SSH PTY)各自實作連線，畫面、按鍵列、字級共用。
@MainActor
public protocol TerminalSessionModel: AnyObject, Observable {
    var title: String { get }
    var status: TerminalStatus { get }
    var statusText: String { get }
    /// 橫幅說明。已連線時沒有。
    var bannerText: String? { get }
    var canReconnect: Bool { get }
    var canTakeOver: Bool { get }
    /// 按鍵列與貼上是否可用(唯讀裝置的 Pane 終端機只能看)。
    var isInteractive: Bool { get }
    /// 鎖定中的黏著修飾鍵。
    var modifiers: TerminalModifiers { get }
    var fontSize: Double { get }
    /// 一次性的提示(例如貼上太大)。
    var notice: String? { get set }
    /// 單指垂直滑動交給遠端(`scroll`);`false` 時終端機模擬器自己捲 scrollback。
    var usesRemoteScroll: Bool { get }
    /// 終端機模擬器看得到遠端程式的模式(登入 Shell 的 PTY);Pane 終端機經 herdr,看不到。
    var seesProgramModes: Bool { get }

    /// 接上終端機模擬器。之前暫存的輸出依序補畫。
    func attach(_ renderer: @escaping (Data) -> Void)
    /// 畫面依字級與邊界算出的格數。
    func viewDidResize(columns: Int, rows: Int)
    func reconnect()
    func takeOver()
    /// 掛斷(離開畫面、App 進背景)。不會自動重連。
    func hangUp()
    /// 終端機模擬器送出的鍵盤輸入。
    func type(_ data: Data)
    /// 一顆鍵(按鍵列或實體鍵盤);`modifiers` 是實體鍵盤按著的修飾鍵，與黏著修飾鍵合併。
    func press(_ key: TerminalKey, adding modifiers: TerminalModifiers, applicationCursor: Bool)
    func toggle(_ modifier: TerminalModifiers)
    /// 貼上;`bracketed` 是模擬器目前的 bracketed paste 模式(Pane 終端機一律包標記，由 herdr 決定)。
    func paste(_ text: String, bracketed: Bool)
    func scroll(_ direction: TerminalInput.ScrollDirection, rows: Int, column: Int, row: Int)
    /// 實體鍵盤的 Page Up／Down 交給遠端決定(Pane 終端機);登入 Shell 在本機捲，不經 model。
    func scrollPage(_ direction: TerminalInput.ScrollDirection, rows: Int)
    func setFontSize(_ size: Double)

    /// 大小模式(#357):只有 Pane 終端機有;登入 Shell 一律配合手機。
    var supportsSizeMode: Bool { get }
    var sizeMode: TerminalSizeMode { get }
    /// 保留電腦版面卻讀不到電腦上的格數,這次以手機的格數接上(#357)。
    var keepDesktopFallback: Bool { get }
    func setSizeMode(_ mode: TerminalSizeMode)
    /// 保留電腦版面時，電腦上 Pane 目前的格數(來自 full frame);還沒收到是 `nil`。
    var displaySize: TerminalGridSize? { get }
    /// 畫面照電腦的格數顯示(整寬縮放)，而不是照手機的大小排版。
    var keepsDesktopLayout: Bool { get }
}

extension TerminalSessionModel {
    public var supportsSizeMode: Bool { false }
    public var sizeMode: TerminalSizeMode { .fitPhone }
    public var keepDesktopFallback: Bool { false }
    public func setSizeMode(_ mode: TerminalSizeMode) {}
    public var displaySize: TerminalGridSize? { nil }
    public var keepsDesktopLayout: Bool { false }
}

extension TerminalSessionModel {
    /// 按鍵列與貼上是否可用。
    public var isInteractive: Bool { status == .connected }

    /// 按鍵列的一顆鍵。
    public func press(_ key: TerminalKey) {
        press(key, adding: [])
    }

    /// 一顆鍵，方向鍵用 CSI 形式。
    public func press(_ key: TerminalKey, adding modifiers: TerminalModifiers) {
        press(key, adding: modifiers, applicationCursor: false)
    }

    public func adjustFontSize(by delta: Double) {
        setFontSize(fontSize + delta)
    }
}

/// 字級範圍與預設(行為規格 §6.4):小於 8pt 讀不了;大於 28pt 直立 iPad 放不下 80 欄。
public enum TerminalFontSize {
    public static let range: ClosedRange<Double> = 8...28
    public static let `default`: Double = 13

    package static func clamped(_ size: Double) -> Double {
        min(max(size, range.lowerBound), range.upperBound)
    }
}

/// 只開 http／https 連結;其他 scheme 一律忽略。
public enum TerminalLinks {
    public static func openableURL(_ link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
