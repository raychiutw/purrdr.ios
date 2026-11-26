#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PurrdrFeatures

/// 外觀設定即時套用(#322):根畫面掛 `appAppearance()`,改外觀後整個視窗(根畫面，以及同一個視窗裡的 sheet、alert)
/// 立刻改成對應的深淺色;切回「自動」回到系統值;多個視窗(含 App 鎖的鎖定視窗)都跟著變。
///
/// 這裡沒有 window scene,SwiftUI 的 sheet 不會真的放進視窗(presented controller 的 view 沒有 window),
/// 所以「開著的 sheet 跟著變」由 UI 測試 `SettingsUITests.testAppearanceChoiceRecolorsOpenSettingsSheet` 以截圖亮度驗證;
/// 這裡驗視窗層級：sheet 與 alert 放在同一個視窗裡，繼承視窗的深淺色。
@Suite(.serialized)
@MainActor
struct AppAppearanceTests {
    private let defaults = UserDefaults.standard

    private func mountWindow() async throws -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Color.clear.appAppearance())
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(50))
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func choose(_ preference: AppearancePreference, expecting style: UIUserInterfaceStyle, in windows: [UIWindow]) async throws {
        preference.store(in: defaults)
        try await waitUntil { windows.allSatisfy { $0.traitCollection.userInterfaceStyle == style } }
        for (index, window) in windows.enumerated() {
            let actual = window.traitCollection.userInterfaceStyle
            #expect(actual == style, "選 \(preference) 後第 \(index + 1) 個視窗是 \(actual.rawValue),應為 \(style.rawValue)")
            #expect(window.rootViewController?.view.traitCollection.userInterfaceStyle == style, "選 \(preference) 後根畫面沒跟著變")
        }
    }

    private static func preference(for style: UIUserInterfaceStyle) -> AppearancePreference {
        style == .dark ? .dark : .light
    }

    @Test("淺色→深色→淺色,視窗與根畫面立刻改變")
    func lightToDarkToLight() async throws {
        defaults.removeObject(forKey: AppearancePreference.storageKey)
        let window = try await mountWindow()
        defer { window.isHidden = true; defaults.removeObject(forKey: AppearancePreference.storageKey) }
        try await choose(.light, expecting: .light, in: [window])
        try await choose(.dark, expecting: .dark, in: [window])
        try await choose(.light, expecting: .light, in: [window])
    }

    @Test("深色或淺色切回自動，回到系統的深淺色")
    func backToAutomatic() async throws {
        defaults.removeObject(forKey: AppearancePreference.storageKey)
        let window = try await mountWindow()
        defer { window.isHidden = true; defaults.removeObject(forKey: AppearancePreference.storageKey) }
        // 還沒選過外觀(自動)時視窗的深淺色就是系統值。
        let system = window.traitCollection.userInterfaceStyle
        let opposite: UIUserInterfaceStyle = system == .dark ? .light : .dark
        try await choose(Self.preference(for: opposite), expecting: opposite, in: [window])
        try await choose(.automatic, expecting: system, in: [window])
        try await choose(Self.preference(for: system), expecting: system, in: [window])
        try await choose(Self.preference(for: opposite), expecting: opposite, in: [window])
        try await choose(.automatic, expecting: system, in: [window])
    }

    @Test("多個視窗(含鎖定視窗)都套用同一個外觀")
    func everyWindowFollows() async throws {
        defaults.removeObject(forKey: AppearancePreference.storageKey)
        let first = try await mountWindow()
        let second = try await mountWindow()
        defer {
            first.isHidden = true
            second.isHidden = true
            defaults.removeObject(forKey: AppearancePreference.storageKey)
        }
        try await choose(.dark, expecting: .dark, in: [first, second])
        try await choose(.light, expecting: .light, in: [first, second])
    }

    // MARK: - 底色回到系統語意色(#646,取代 #379)

    private static func hex(_ color: Color, traits: UITraitCollection) -> String {
        var (red, green, blue, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func h(_ value: CGFloat) -> String { String(format: "%02X", Int((value * 255).rounded())) }
        return "#" + h(red) + h(green) + h(blue)
    }

    private static func traits(_ style: UIUserInterfaceStyle, highContrast: Bool = false, elevated: Bool = false) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(accessibilityContrast: highContrast ? .high : .normal),
            UITraitCollection(userInterfaceLevel: elevated ? .elevated : .base),
        ])
    }

    /// 每個底色用途 → (系統語意色, 預期值:深色 base、深色 elevated、深色 base 增加對比、深色 elevated 增加對比、淺色、淺色增加對比;
    /// 值是 iOS 27.0 模擬器實測,見 docs/research/ios27-dark-mode-colors.md §1.2)。
    private static let surfaces: [(name: String, color: Color, system: UIColor, expected: [String])] = [
        ("page", AppSurface.page, .systemBackground,
         ["#000000", "#1C1C1E", "#000000", "#242426", "#FFFFFF", "#FFFFFF"]),
        ("groupedPage", AppSurface.groupedPage, .systemGroupedBackground,
         ["#000000", "#1C1C1E", "#000000", "#242426", "#F2F2F7", "#EBEBF0"]),
        ("card", AppSurface.card, .secondarySystemBackground,
         ["#1C1C1E", "#2C2C2E", "#242426", "#363638", "#F2F2F7", "#EBEBF0"]),
        ("groupedRow", AppSurface.groupedRow, .secondarySystemGroupedBackground,
         ["#1C1C1E", "#2C2C2E", "#242426", "#363638", "#FFFFFF", "#FFFFFF"]),
        ("inner", AppSurface.inner, .tertiarySystemBackground,
         ["#2C2C2E", "#3A3A3C", "#363638", "#444446", "#FFFFFF", "#FFFFFF"]),
    ]

    @Test("底色各用途在深色 base／elevated、淺色、增加對比下,等於對應的系統語意色(深色頁面是純黑)")
    func surfacesAreSystemColors() {
        let appearances: [(String, UITraitCollection)] = [
            ("深色 base", Self.traits(.dark)), ("深色 elevated", Self.traits(.dark, elevated: true)),
            ("深色 base 增加對比", Self.traits(.dark, highContrast: true)),
            ("深色 elevated 增加對比", Self.traits(.dark, highContrast: true, elevated: true)),
            ("淺色", Self.traits(.light)), ("淺色增加對比", Self.traits(.light, highContrast: true)),
        ]
        for surface in Self.surfaces {
            for (index, (label, traits)) in appearances.enumerated() {
                let actual = Self.hex(surface.color, traits: traits)
                let system = Self.hex(Color(uiColor: surface.system), traits: traits)
                #expect(actual == system, "\(surface.name) \(label):\(actual) 不等於系統色 \(system)")
                #expect(actual == surface.expected[index], "\(surface.name) \(label):\(actual),預期 \(surface.expected[index])")
            }
        }
    }

    @Test("次要文字:深色(含增加對比)是系統 secondaryLabel,淺色是自訂灰")
    func secondaryTextIsSystemInDark() {
        for highContrast in [false, true] {
            let dark = Self.traits(.dark, highContrast: highContrast)
            let actual = UIColor(Color.secondaryText).resolvedColor(with: dark)
            let system = UIColor.secondaryLabel.resolvedColor(with: dark)
            #expect(actual == system, "深色\(highContrast ? "增加對比" : "") 次要文字不是系統 secondaryLabel")
        }
        #expect(Self.hex(Color.secondaryText, traits: Self.traits(.light)) == "#636366")
        #expect(Self.hex(Color.secondaryText, traits: Self.traits(.light, highContrast: true)) == "#48484A")
    }
}
#endif

