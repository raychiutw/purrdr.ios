import Foundation

/// Pane 終端機的大小模式(#357)。
public enum TerminalSizeMode: String, Sendable, CaseIterable {
    /// 預設:handshake 帶 Pane 在電腦上目前的欄列數(herdr 接上就把 Pane 改成 handshake 的尺寸，所以帶原尺寸才不動版面),
    /// 不送 `terminal.resize`,以那個欄列數顯示(整寬縮放)。讀不到(電腦沒開 herdr)時退回手機的格數(`keepDesktopFallback`)。
    case keepDesktop
    /// 照手機的格數送 `terminal.resize`:字比較大、比較好打字，但電腦上的版面會跟著變(離開後恢復)。
    case fitPhone
}

/// 終端機畫面的格數。
public struct TerminalGridSize: Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// 大小模式的本機偏好(只存在這支裝置、不同步)。
public enum TerminalSizeSettings {
    public static let modeKey = "terminal.sizeMode"

    /// 存著的模式;沒存過是保留電腦版面。
    public static func mode(in defaults: UserDefaults) -> TerminalSizeMode {
        defaults.string(forKey: modeKey).flatMap(TerminalSizeMode.init(rawValue:)) ?? .keepDesktop
    }

    public static func setMode(_ mode: TerminalSizeMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}
