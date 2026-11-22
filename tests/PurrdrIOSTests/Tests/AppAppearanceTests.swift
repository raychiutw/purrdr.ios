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

    // MARK: - 底色層次(#379)

    private static func rgb(_ color: UIColor, in window: UIWindow) -> String {
        var (red, green, blue, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        color.resolvedColor(with: window.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func hex(_ value: CGFloat) -> String { String(format: "%02X", Int((value * 255).rounded())) }
        return "#" + hex(red) + hex(green) + hex(blue)
    }

    @Test("深色:頁面 #1C1C1E、卡片與 grouped 列 #2C2C2E、再內一層 #3A3A3C(不再是純黑)")
    func darkSurfacesAreRaised() async throws {
        defaults.removeObject(forKey: AppearancePreference.storageKey)
        let window = try await mountWindow()
        defer { window.isHidden = true; defaults.removeObject(forKey: AppearancePreference.storageKey) }
        try await choose(.dark, expecting: .dark, in: [window])
        #expect(Self.rgb(.systemBackground, in: window) == "#1C1C1E")
        #expect(Self.rgb(.systemGroupedBackground, in: window) == "#1C1C1E")
        #expect(Self.rgb(.secondarySystemBackground, in: window) == "#2C2C2E")
        #expect(Self.rgb(.secondarySystemGroupedBackground, in: window) == "#2C2C2E")
        #expect(Self.rgb(.tertiarySystemGroupedBackground, in: window) == "#3A3A3C")
    }

    @Test("淺色底色不變:白、grouped #F2F2F7")
    func lightSurfacesUnchanged() async throws {
        defaults.removeObject(forKey: AppearancePreference.storageKey)
        let window = try await mountWindow()
        defer { window.isHidden = true; defaults.removeObject(forKey: AppearancePreference.storageKey) }
        try await choose(.light, expecting: .light, in: [window])
        #expect(Self.rgb(.systemBackground, in: window) == "#FFFFFF")
        #expect(Self.rgb(.systemGroupedBackground, in: window) == "#F2F2F7")
        #expect(Self.rgb(.secondarySystemGroupedBackground, in: window) == "#FFFFFF")
    }
}
#endif
