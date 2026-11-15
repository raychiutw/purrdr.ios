import PurrdrCore
import SwiftUI

/// 終端機的進入點按鈕(Agent 對話的標題列、Agent 列表的滑動動作共用)。
public struct PaneTerminalButton: View {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label("Terminal", systemImage: "apple.terminal")
        }
        .accessibilityIdentifier("terminal.open")
    }
}

#if canImport(UIKit)
import SwiftTerm
import UIKit

/// Pane 終端機(DESIGN.md「終端機」):全螢幕深色、標題下有狀態點與文字、底部是單一玻璃容器的按鍵列。
///
/// 終端機模擬器(SwiftTerm)只負責畫面;鍵盤輸入、按鍵列、貼上、滑動都經過 `PaneTerminalModel`
/// 變成 herdr 的訊息。
public struct PaneTerminalView: View {
    @Bindable var model: PaneTerminalModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var screen = TerminalScreenHandle()

    public init(model: PaneTerminalModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let banner = model.bannerText {
                TerminalBanner(text: banner, model: model)
            }
            TerminalScreen(model: model, handle: screen)
                .padding(.horizontal, 4)
            TerminalKeyBar(model: model, screen: screen)
        }
        .background(SwiftUI.Color.black)
        .environment(\.colorScheme, .dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TerminalTitle(title: model.title, status: model.status, statusText: model.statusText)
            }
            ToolbarItem(placement: .topBarTrailing) {
                FontSizeMenu(model: model)
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .alert("Can’t Paste", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
        // App 進背景立刻掛斷，回前景不自動重連:不能讓鎖著的手機一直佔住 Pane(行為規格 §6.5)。
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.hangUp() }
        }
        .onDisappear { model.hangUp() }
        .onChange(of: model.status) { _, status in
            // 接上後終端機取得焦點，鍵盤輸入直接送往遠端。
            if status == .connected { screen.focus() }
        }
    }
}

// MARK: - 標題與狀態

struct TerminalTitle: View {
    let title: String
    let status: PaneTerminalModel.Status
    let statusText: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.status")
    }

    /// 狀態同時有文字，顏色只是輔助。
    private var dotColor: SwiftUI.Color {
        switch status {
        case .connected: .green
        case .waitingForSize, .connecting: .yellow
        case .ended: .gray
        case .disconnected, .inUse, .takenOver, .unavailable: .red
        }
    }
}

struct TerminalBanner: View {
    let text: String
    let model: PaneTerminalModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                message
                Spacer(minLength: 8)
                action
            }
            VStack(alignment: .leading, spacing: 8) {
                message
                action
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SwiftUI.Color(white: 0.15))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.banner")
    }

    private var message: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var action: some View {
        if model.canTakeOver {
            Button("Take Over") { model.takeOver() }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("terminal.takeOver")
        } else if model.canReconnect {
            Button("Reconnect") { model.reconnect() }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("terminal.reconnect")
        }
    }
}

struct FontSizeMenu: View {
    let model: PaneTerminalModel

    var body: some View {
        Menu {
            Button("Larger Text", systemImage: "textformat.size.larger") { model.adjustFontSize(by: 1) }
                .disabled(model.fontSize >= PaneTerminalModel.fontSizes.upperBound)
            Button("Smaller Text", systemImage: "textformat.size.smaller") { model.adjustFontSize(by: -1) }
                .disabled(model.fontSize <= PaneTerminalModel.fontSizes.lowerBound)
            Button("Default Size", systemImage: "arrow.counterclockwise") { model.setFontSize(PaneTerminalModel.defaultFontSize) }
        } label: {
            Label("Text Size", systemImage: "textformat.size")
        }
        .accessibilityIdentifier("terminal.fontSize")
    }
}

// MARK: - 按鍵列

/// 按鍵列：單一玻璃容器(按鍵不各自做成玻璃)。左邊可橫捲的按鍵，Esc、Tab、Ctrl、Alt 排最前面，
/// 最窄的寬度也不用捲就看得到;列尾固定「貼上」與「收起鍵盤」兩顆鈕。
struct TerminalKeyBar: View {
    let model: PaneTerminalModel
    let screen: TerminalScreenHandle

    static let keys: [BarKey] = [
        BarKey(id: "esc", title: "esc", label: "Escape", key: .escape),
        BarKey(id: "tab", title: "tab", label: "Tab", key: .tab),
        BarKey(id: "ctrl", title: "ctrl", label: "Control", modifier: .control),
        BarKey(id: "alt", title: "alt", label: "Alt", modifier: .alt),
        BarKey(id: "left", symbol: "arrow.left", label: "Left Arrow", key: .left),
        BarKey(id: "down", symbol: "arrow.down", label: "Down Arrow", key: .down),
        BarKey(id: "up", symbol: "arrow.up", label: "Up Arrow", key: .up),
        BarKey(id: "right", symbol: "arrow.right", label: "Right Arrow", key: .right),
        BarKey(id: "slash", title: "/", label: "Slash", key: .character("/")),
        BarKey(id: "hyphen", title: "-", label: "Hyphen", key: .character("-")),
        BarKey(id: "pipe", title: "|", label: "Vertical Bar", key: .character("|")),
        BarKey(id: "tilde", title: "~", label: "Tilde", key: .character("~")),
        BarKey(id: "home", title: "home", label: "Home", key: .home),
        BarKey(id: "end", title: "end", label: "End", key: .end),
    ]

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Self.keys) { key in
                            BarKeyButton(key: key, model: model)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Divider().frame(height: 28)
                PasteKey(model: model)
                KeyboardToggle(screen: screen)
            }
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct BarKey: Identifiable {
    var id: String
    var title: String?
    var symbol: String?
    var label: String
    var key: TerminalKey?
    var modifier: TerminalModifiers?

    init(id: String, title: String? = nil, symbol: String? = nil, label: String,
         key: TerminalKey? = nil, modifier: TerminalModifiers? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.label = label
        self.key = key
        self.modifier = modifier
    }
}

struct BarKeyButton: View {
    let key: BarKey
    let model: PaneTerminalModel

    private var isLocked: Bool { key.modifier.map(model.modifiers.contains) ?? false }

    var body: some View {
        Button {
            if let modifier = key.modifier {
                model.toggle(modifier)
            } else if let terminalKey = key.key {
                model.press(terminalKey)
            }
        } label: {
            Group {
                if let symbol = key.symbol {
                    Image(systemName: symbol)
                } else {
                    // 鎖定時同時有底色與「•」標示，不只靠顏色(DESIGN.md)。
                    Text((key.title ?? "") + (isLocked ? "•" : ""))
                }
            }
            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            .foregroundStyle(isLocked ? SwiftUI.Color.black : SwiftUI.Color.white)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .background(isLocked ? SwiftUI.Color.white : SwiftUI.Color.clear, in: .capsule)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.isInteractive)
        .accessibilityLabel(key.label)
        .accessibilityValue(key.modifier == nil ? "" : (isLocked ? "Locked" : "Off"))
        .accessibilityAddTraits(isLocked ? .isSelected : [])
        .accessibilityIdentifier("terminal.key.\(key.id)")
    }
}

/// 貼上剪貼簿文字(可能觸發系統的「允許貼上」)。不用 `PasteButton`:它的點擊範圍撐不到 44×44 pt。
struct PasteKey: View {
    let model: PaneTerminalModel

    var body: some View {
        Button {
            if let text = UIPasteboard.general.string { model.paste(text) }
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.body)
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.isInteractive)
        .accessibilityLabel("Paste")
        .accessibilityIdentifier("terminal.key.paste")
    }
}

struct KeyboardToggle: View {
    let screen: TerminalScreenHandle

    var body: some View {
        Button {
            screen.toggleKeyboard()
        } label: {
            Image(systemName: screen.isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.body)
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(screen.isKeyboardVisible ? "Hide Keyboard" : "Show Keyboard")
        .accessibilityIdentifier("terminal.key.keyboard")
    }
}

// MARK: - 終端機畫面

/// 讓按鍵列操作終端機畫面的焦點與鍵盤。
@MainActor
@Observable
final class TerminalScreenHandle {
    fileprivate weak var view: PurrdrTerminalView?
    private(set) var isKeyboardVisible = false

    func focus() {
        guard let view, !view.isFirstResponder else { return }
        _ = view.becomeFirstResponder()
    }

    func toggleKeyboard() {
        guard let view else { return }
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    fileprivate func focusChanged(_ focused: Bool) {
        isKeyboardVisible = focused
    }
}

struct TerminalScreen: UIViewRepresentable {
    let model: PaneTerminalModel
    let handle: TerminalScreenHandle

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> PurrdrTerminalView {
        let view = PurrdrTerminalView(frame: .zero, font: Self.font(model.fontSize))
        view.terminalDelegate = context.coordinator
        // 按鍵列由 SwiftUI 畫(玻璃容器);SwiftTerm 自帶的 accessory 關掉。
        view.inputAccessoryView = nil
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.caretColor = .systemGray
        view.keyboardAppearance = .dark
        // 本機 scrollback 是空的(herdr 每次都重畫整個 viewport);滑動改送 terminal.scroll。
        view.isScrollEnabled = false
        view.accessibilityIdentifier = "terminal.screen"
        view.onFocusChange = { [weak handle] in handle?.focusChanged($0) }
        context.coordinator.install(on: view)
        handle.view = view
        model.attach { [weak view] bytes in view?.feed(byteArray: ArraySlice(bytes)) }
        return view
    }

    func updateUIView(_ view: PurrdrTerminalView, context: Context) {
        let font = Self.font(model.fontSize)
        if view.font.pointSize != font.pointSize {
            view.font = font
        }
    }

    static func font(_ size: Double) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let model: PaneTerminalModel
        private var pinchStartSize: Double = PaneTerminalModel.defaultFontSize
        private var scrolledRows = 0

        init(model: PaneTerminalModel) {
            self.model = model
        }

        func install(on view: PurrdrTerminalView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)
            // 捏合與滑動互斥。
            pan.require(toFail: pinch)
        }

        /// 只接手垂直滑動;水平滑動留給系統(例如返回手勢)。
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) >= abs(velocity.x)
        }

        /// 每滑過一列送一則捲動，座標是手指所在格;自然捲動(手指往下 = 往上捲)。
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? PurrdrTerminalView else { return }
            let terminal = view.getTerminal()
            let cellHeight = view.bounds.height / CGFloat(max(terminal.rows, 1))
            let cellWidth = view.bounds.width / CGFloat(max(terminal.cols, 1))
            switch gesture.state {
            case .began:
                scrolledRows = 0
            case .changed:
                let rows = Int(gesture.translation(in: view).y / max(cellHeight, 1))
                let delta = rows - scrolledRows
                guard delta != 0 else { return }
                scrolledRows = rows
                let location = gesture.location(in: view)
                model.scroll(delta > 0 ? .up : .down, rows: abs(delta),
                             column: Int(location.x / max(cellWidth, 1)), row: Int(location.y / max(cellHeight, 1)))
            default:
                break
            }
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: pinchStartSize = model.fontSize
            case .changed, .ended: model.setFontSize((pinchStartSize * gesture.scale).rounded())
            default: break
            }
        }

        // MARK: TerminalViewDelegate

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated { model.type(bytes) }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { model.viewDidResize(columns: newCols, rows: newRows) }
        }

        /// 只開 http(s) 連結。
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            MainActor.assumeIsolated {
                guard let url = PaneTerminalModel.openableURL(link) else { return }
                UIApplication.shared.open(url)
            }
        }

        /// OSC 52 只能寫、不能讀(SwiftTerm 不支援讀)。herdr 的 control 串流目前不轉送 OSC 52(#4 spike),
        /// 這裡只是保底:合法 UTF-8 才寫。
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            MainActor.assumeIsolated { UIPasteboard.general.string = text }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func bell(source: TerminalView) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// SwiftTerm 的終端機視圖，加上焦點回報與給 VoiceOver(與 UI 測試)讀的畫面文字。
final class PurrdrTerminalView: TerminalView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// 目前畫面上的文字(去掉行尾空白)。
    override var accessibilityValue: String? {
        get {
            let terminal = getTerminal()
            return (0..<terminal.rows).map { row in
                (terminal.getLine(row: row)?.translateToString(
                    skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter(for:)
                ) ?? "").replacingOccurrences(of: " +$", with: "", options: .regularExpression)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        }
        set {}
    }
}
#endif
