import PurrdrAgentFeatures
import SwiftUI

/// 主機名稱前的主機圖示(#239):主色線條符號放在淡主色圓形底上;「無」留同尺寸的空位，讓名稱對齊。
///
/// 裝飾用，VoiceOver 不念;主機名稱或圖示名稱由旁邊的文字提供。
public struct HostIconBadge: View {
    let icon: HostIcon
    let showsNoIconSymbol: Bool
    @ScaledMetric private var diameter: CGFloat

    /// - Parameters:
    ///   - diameter: 標準字級下的圓直徑(主機清單 32pt、Agents 列副標 18pt、編輯器格子 40pt),跟著動態字級縮放。
    ///   - showsNoIconSymbol: 「無」也畫符號(圖示選擇器用);否則留空位。
    public init(_ icon: HostIcon, diameter: CGFloat = 32, showsNoIconSymbol: Bool = false) {
        self.icon = icon
        self.showsNoIconSymbol = showsNoIconSymbol
        _diameter = ScaledMetric(wrappedValue: diameter, relativeTo: .body)
    }

    public var body: some View {
        Group {
            if let symbol = showsNoIconSymbol ? icon.pickerSymbol : icon.symbol {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.5))
                    .foregroundStyle(.tint)
                    .frame(width: diameter, height: diameter)
                    .background(.softAccentFill, in: Circle())
            } else {
                Color.clear
                    .frame(width: diameter, height: diameter)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 主機名稱加主機圖示的選單項目(主機選單、方案用量的主機挑選);「無」只顯示名稱。需要重新確認的主機(#572)名稱後加「請再確認這台主機」。
public struct HostMenuLabel: View {
    let title: String
    let icon: HostIcon
    let needsReconfirmation: Bool

    public init(_ title: String, icon: HostIcon, needsReconfirmation: Bool = false) {
        self.title = title
        self.icon = icon
        self.needsReconfirmation = needsReconfirmation
    }

    public init(_ option: HostOption) {
        self.init(option.name, icon: option.icon, needsReconfirmation: option.needsReconfirmation)
    }

    public var body: some View {
        if needsReconfirmation {
            Label {
                Text(verbatim: "\(title) · \(String(localized: "Check This Host Again"))")
            } icon: {
                Image(systemName: icon.symbol ?? "exclamationmark.triangle")
            }
        } else if let symbol = icon.symbol {
            Label(title, systemImage: symbol)
        } else {
            Text(verbatim: title)
        }
    }
}

/// 主機編輯器的圖示欄位(#239):11 種加「無」的格狀選擇，選中的格子加主色外框。
struct HostIconGrid: View {
    @Binding var selection: HostIcon
    @ScaledMetric(relativeTo: .body) private var cellWidth: CGFloat = 72

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 8)], spacing: 8) {
            ForEach(HostIcon.allCases, id: \.self) { icon in
                cell(icon)
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ icon: HostIcon) -> some View {
        let isSelected = icon == selection
        return Button {
            selection = icon
        } label: {
            VStack(spacing: 4) {
                HostIconBadge(icon, diameter: 40, showsNoIconSymbol: true)
                Text(icon.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 8)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 1.5)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.pressableRow(cornerRadius: 12))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("hostEditor.icon.\(icon.rawValue)")
    }
}
