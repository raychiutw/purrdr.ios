import PurrdrCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension AppLockPhase {
    public init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
        }
    }
}

extension View {
    /// App 鎖(#284):鎖定中或視窗不在前景時，以鎖定畫面蓋住整個視窗(含 sheet)。每個視窗的根畫面都要掛。
    public func appLockCover(_ lock: AppLock?) -> some View {
        modifier(AppLockCoverModifier(lock: lock))
    }
}

private struct AppLockCoverModifier: ViewModifier {
    let lock: AppLock?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let isCovered = lock?.covers(windowIsActive: scenePhase == .active) ?? false
        #if os(iOS)
        content
            .accessibilityHidden(isCovered)
            .background {
                if let lock { AppLockWindowPresenter(lock: lock, isPresented: isCovered) }
            }
        #else
        content
            .accessibilityHidden(isCovered)
            .overlay {
                if isCovered, let lock { AppLockScreen(lock: lock) }
            }
        #endif
    }
}

/// 鎖定畫面。只遮蔽(視窗不在前景、還沒鎖)時只有圖示。
struct AppLockScreen: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            if lock.isLocked {
                Text("Purrdr Is Locked")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("appLock.title")
                Button("Unlock") {
                    Task { await lock.unlock() }
                }
                .filledProminentButtonStyle()
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
                .accessibilityIdentifier("appLock.unlock")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appLock.screen")
    }
}

#if os(iOS)
/// 鎖定畫面放在視窗場景上層的獨立 UIWindow:sheet 是另一層 presentation,一般 overlay 蓋不住。
private struct AppLockWindowPresenter: UIViewRepresentable {
    let lock: AppLock
    let isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let anchor = AnchorView()
        anchor.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        anchor.onWindowChange = { [weak coordinator] in coordinator?.apply() }
        coordinator.anchor = anchor
        return anchor
    }

    func updateUIView(_ anchor: AnchorView, context: Context) {
        context.coordinator.lock = lock
        context.coordinator.isPresented = isPresented
        context.coordinator.apply()
    }

    static func dismantleUIView(_ anchor: AnchorView, coordinator: Coordinator) {
        coordinator.lockWindow?.isHidden = true
        coordinator.lockWindow = nil
    }

    final class AnchorView: UIView {
        var onWindowChange: (@MainActor () -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?()
        }
    }

    @MainActor
    final class Coordinator {
        weak var anchor: UIView?
        var lock: AppLock?
        var isPresented = false
        var lockWindow: UIWindow?

        func apply() {
            guard let lock, let contentWindow = anchor?.window, let scene = contentWindow.windowScene else { return }
            if lockWindow?.windowScene !== scene {
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                let host = UIHostingController(rootView: AppLockScreen(lock: lock).appAppearance())
                host.view.accessibilityViewIsModal = true
                window.rootViewController = host
                window.isHidden = true
                lockWindow = window
            }
            guard let lockWindow else { return }
            if isPresented, lockWindow.isHidden {
                // 收起鍵盤：鍵盤在更上層，會露在鎖定畫面上。
                contentWindow.endEditing(true)
                lockWindow.makeKeyAndVisible()
            } else if !isPresented, !lockWindow.isHidden {
                lockWindow.isHidden = true
                contentWindow.makeKey()
            }
        }
    }
}
#endif

/// 設定頁的 App 鎖區段。
struct AppLockSettingsSection: View {
    let lock: AppLock

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { lock.isEnabled }, set: { enabled in Task { await lock.setEnabled(enabled) } })) {
                toggleTitle
            }
            .disabled(!lock.availability.canAuthenticate || lock.isAuthenticating)
            .accessibilityIdentifier("settings.appLock")
        } header: {
            Text("App Lock")
                .foregroundStyle(.secondaryText)
        } footer: {
            // 只說明不能用的原因(狀態訊息);功能說明依 #276 不放。
            if let unavailableReason {
                unavailableReason
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("settings.appLock.footer")
            }
        }
    }

    private var toggleTitle: Text {
        switch lock.availability {
        case .available(.faceID): Text("Require Face ID")
        case .available(.touchID): Text("Require Touch ID")
        case .available(.opticID): Text("Require Optic ID")
        case .available(.passcodeOnly), .passcodeNotSet, .unavailable: Text("Require Passcode")
        }
    }

    private var unavailableReason: Text? {
        switch lock.availability {
        case .available:
            nil
        case .passcodeNotSet:
            Text("Set a device passcode in the Settings app to use App Lock.")
        case .unavailable:
            Text("App Lock isn’t available on this device.")
        }
    }
}
