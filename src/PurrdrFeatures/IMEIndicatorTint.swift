#if canImport(UIKit)
import PurrdrCore
import UIKit

extension UIColor {
    /// 輸入法指示膠囊(聽寫、「國」)的底色(#396):系統以輸入元件的 tint 為底、白字繪製。
    /// 深色模式的主色是亮翡翠綠,白字對比不足,所以深色時換成讓白字對比 ≥ 4.5:1 的同色相;淺色模式原樣。
    func indicatorTint(for style: UIUserInterfaceStyle) -> UIColor {
        guard style == .dark else { return self }
        var (red, green, blue, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }
        func byte(_ value: CGFloat) -> UInt8 { UInt8((max(0, min(1, value)) * 255).rounded()) }
        let adjusted = ThemeColor(red: byte(red), green: byte(green), blue: byte(blue)).darkenedForWhiteText()
        return UIColor(red: CGFloat(adjusted.red) / 255, green: CGFloat(adjusted.green) / 255,
                       blue: CGFloat(adjusted.blue) / 255, alpha: alpha)
    }
}
#endif
