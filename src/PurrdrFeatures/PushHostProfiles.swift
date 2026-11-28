import Foundation
import PurrdrAgentFeatures
import PurrdrCore

/// 主機圖示在後台的顏色:app 的主色(`AccentColor` 亮色值);後台只存不解讀,其他裝置畫圖示時用它。
enum PushHostIconColor {
    static let accent = "#0B7A5C"
}

extension HostIcon {
    /// 推播配對帶給後台的圖示:系統圖示代號加顏色;「無」沒有圖示(後台清掉)。
    var pushIcon: PushHostIcon? {
        symbol.flatMap { PushHostIcon(symbol: $0, color: PushHostIconColor.accent) }
    }
}

extension PushHostProfile {
    /// 一台主機的顯示名稱與圖示。
    init(name: String, icon: HostIcon) {
        self.init(name: name, icon: icon.pushIcon)
    }
}
