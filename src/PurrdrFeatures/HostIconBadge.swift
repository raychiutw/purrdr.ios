import PurrdrAgentFeatures
import SwiftUI

/// 主機名稱前的主機圖示(#239):主色線條符號放在淡主色圓形底上;「無」留同尺寸的空位，讓名稱對齊。
///
/// 裝飾用，VoiceOver 不念;主機名稱或圖示名稱由旁邊的文字提供。
public struct HostIconBadge: View {
    let icon: HostIcon
    let showsNoIconSymbol: Bool
    @ScaledMetric private var diameter: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - diameter: 標準字級下的圓直徑(列表 32pt、編輯器格子 40pt),跟著動態字級縮放。
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
                    .foregroundStyle(Color.accentColor)
                    .frame(width: diameter, height: diameter)
                    .background(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.12), in: Circle())
            } else {
                Color.clear
                    .frame(width: diameter, height: diameter)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 主機名稱加主機圖示的選單項目(主機選單、方案用量的主機挑選);「無」只顯示名稱。
public struct HostMenuLabel: View {
    let title: String
    let icon: HostIcon

    public init(_ title: String, icon: HostIcon) {
        self.title = title
        self.icon = icon
    }

    public var body: some View {
        if let symbol = icon.symbol {
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
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.pressableRow(cornerRadius: 12))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("hostEditor.icon.\(icon.rawValue)")
    }
}
