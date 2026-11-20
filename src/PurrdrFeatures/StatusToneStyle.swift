import PurrdrAgentFeatures
import SwiftUI

extension StatusTone {
    /// 對照表的實際色：系統橙、主色、系統紅、系統灰;只給符號與圓點用。
    var style: AnyShapeStyle {
        switch self {
        case .attention: AnyShapeStyle(Color.orange)
        case .accent: AnyShapeStyle(.tint)
        case .error: AnyShapeStyle(Color.red)
        case .neutral: AnyShapeStyle(Color.gray)
        }
    }
}

extension StatusTextEmphasis {
    /// 狀態字的顏色。`Color.primary` 是固定色：列是按鈕時，階層式 `.primary` 會被 tint 染色。
    var style: AnyShapeStyle {
        switch self {
        case .primary: AnyShapeStyle(Color.primary)
        case .secondary: AnyShapeStyle(.secondaryText)
        }
    }
}
