import SwiftUI

#if os(iOS)
import UIKit
#endif

/// 目前開著的主視窗(#539):Pane 視窗的「需要你」橫幅被點時，要把聊天開在主視窗並帶到前面;沒有主視窗時改開新的 Pane 視窗。
///
/// 主視窗的根畫面以 `registersAsMainWindow()` 登記自己所在的視窗場景;全 app 共用一份。
@MainActor
final class MainWindowRegistry {
    static let shared = MainWindowRegistry()

    #if os(iOS)
    private struct Entry { weak var scene: UIWindowScene? }
    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ scene: UIWindowScene) { entries[ObjectIdentifier(scene)] = Entry(scene: scene) }
    func unregister(_ scene: UIWindowScene) { entries[ObjectIdentifier(scene)] = nil }

    private var scenes: [UIWindowScene] { entries.values.compactMap(\.scene) }
    #endif

    /// 有沒有主視窗可以開聊天。
    var hasMainWindow: Bool {
        #if os(iOS)
        !scenes.isEmpty
        #else
        false
        #endif
    }

    /// 把主視窗帶到前面(優先已在前景的那個);沒有主視窗時什麼都不做。
    func bringToFront() {
        #if os(iOS)
        let target = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let session = target?.session else { return }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil, errorHandler: nil)
        #endif
    }
}

extension View {
    /// 主視窗的根畫面登記自己(見 `MainWindowRegistry`)。
    func registersAsMainWindow() -> some View {
        #if os(iOS)
        background { MainWindowAnchor().frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true) }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct MainWindowAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {}

    final class Anchor: UIView {
        private weak var registered: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let registered { MainWindowRegistry.shared.unregister(registered) }
            registered = window?.windowScene
            if let registered { MainWindowRegistry.shared.register(registered) }
        }
    }
}
#endif
