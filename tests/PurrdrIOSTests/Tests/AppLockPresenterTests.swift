#if os(iOS)
import Foundation
import PurrdrCore
import SwiftUI
import Testing
import UIKit
@testable import PurrdrFeatures

/// App 鎖遮罩(#492):`updateUIView` 是 SwiftUI 更新途中，不能同步 `endEditing` 或 `makeKeyAndVisible`
/// (與 #34 的重入迴圈同型，0.49.0 實機被看門狗 0x8BADF00D 殺掉);要延後到這次更新結束後，同一狀態只做一次。
@Suite(.serialized)
@MainActor
struct AppLockPresenterTests {
    private struct NoopAuthenticator: DeviceOwnerAuthenticating {
        func availability() -> AppLockAvailability { .available(.faceID) }
        func authenticate(_ purpose: AppLockAuthenticationPurpose) async -> AppLockAuthenticationResult { .cancelled }
    }

    private final class Content: ObservableObject {
        @Published var isPresented = false
    }

    private final class Counter { var value = 0 }

    /// 內容:一個輸入框(第一響應者)加上遮罩的錨點。
    private struct Root: View {
        @ObservedObject var content: Content
        let lock: AppLock
        let field: UITextField
        let created: Counter

        var body: some View {
            FieldHost(field: field)
                .background {
                    AppLockWindowPresenter(
                        lock: lock, isPresented: content.isPresented,
                        windowFactory: { _ in
                            created.value += 1
                            return UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
                        })
                }
        }
    }

    private struct FieldHost: UIViewRepresentable {
        let field: UITextField
        func makeUIView(context: Context) -> UITextField { field }
        func updateUIView(_ uiView: UITextField, context: Context) {}
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    @Test("遮罩出現:endEditing 與顯示鎖定視窗不在 updateUIView 同步執行，之後才套用一次")
    func coverIsAppliedAfterTheUpdate() async throws {
        let lock = AppLock(authenticator: NoopAuthenticator(), defaults: UserDefaults(suiteName: "presenter-\(UUID().uuidString)")!)
        let content = Content()
        let field = UITextField()
        let created = Counter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Root(content: content, lock: lock, field: field, created: created))
        window.makeKeyAndVisible()
        try await settle()
        #expect(field.becomeFirstResponder())
        #expect(field.isFirstResponder)

        content.isPresented = true
        // 同一輪(SwiftUI 更新剛跑完):焦點與視窗都還沒被動。
        window.rootViewController?.view.layoutIfNeeded()
        #expect(field.isFirstResponder, "updateUIView 同步收起了鍵盤")

        try await settle()
        #expect(!field.isFirstResponder, "更新結束後應收起鍵盤")
        #expect(created.value == 1, "鎖定視窗只建一次")
    }
}
#endif
