import PurrdrAgentFeatures
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

/// Pane 終端機。
public typealias PaneTerminalView = TerminalSessionView

/// 終端機畫面(DESIGN.md「終端機」):全螢幕深色、標題下有狀態點與文字、底部是單一玻璃容器的按鍵列。
/// Pane 終端機(`PaneTerminalModel`)與登入 Shell(`LoginShellModel`)共用。
///
/// 終端機模擬器(SwiftTerm)只負責畫面;鍵盤輸入由 Purrdr 的輸入元件接管(#136),
/// 輸入、按鍵列、貼上、滑動都經過 model(Pane 終端機變成 herdr 的訊息，登入 Shell 直接寫進 PTY)。
public struct TerminalSessionView: View {
    let model: any TerminalSessionModel
    /// 登入 Shell 的主機挑選鈕(#245);Pane 終端機沒有。
    let hostPicker: HostPickerModel?
    @Environment(\.scenePhase) private var scenePhase
    @State private var screen = TerminalScreenHandle()
    /// 主機主題的終端機配色(#23);`nil` 時用預設深色。
    @Environment(\.hostTheme) private var hostTheme

    public init(model: any TerminalSessionModel, hostPicker: HostPickerModel? = nil) {
        self.model = model
        self.hostPicker = hostPicker
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let banner = model.bannerText {
                TerminalBanner(text: banner, model: model)
            }
            TerminalScreen(model: model, handle: screen, theme: hostTheme?.terminal)
                .padding(.horizontal, 4)
            TerminalKeyBar(model: model, screen: screen)
        }
        .background(hostTheme?.terminal.map { SwiftUI.Color($0.background) } ?? SwiftUI.Color.black)
        .environment(\.colorScheme, .dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TerminalTitle(title: model.title, status: model.status, statusText: model.statusText, hostPicker: hostPicker)
            }
            ToolbarItem(placement: .topBarTrailing) {
                FontSizeMenu(model: model)
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .alert("Can’t Paste", isPresented: Binding(get: { model.notice != nil }, set: { [model] in if !$0 { model.notice = nil } })) {
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
    let status: TerminalStatus
    let statusText: String
    var hostPicker: HostPickerModel?

    var body: some View {
        if let hostPicker {
            // 主機挑選鈕是自己的按鈕;狀態另成一個元素，念出主機與狀態。
            VStack(spacing: 2) {
                HostPickerButton(model: hostPicker, identifier: "loginShell.host")
                statusRow
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(title), \(statusText)"))
                    .accessibilityIdentifier("terminal.status")
            }
        } else {
            VStack(spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                statusRow
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("terminal.status")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondaryText)
        }
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
    let model: any TerminalSessionModel

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
        .background(.background.secondary)
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
                .filledProminentButtonStyle()
                .frame(minHeight: 44)
                .accessibilityIdentifier("terminal.takeOver")
        } else if model.canReconnect {
            Button("Reconnect") { model.reconnect() }
                .filledProminentButtonStyle()
                .frame(minHeight: 44)
                .accessibilityIdentifier("terminal.reconnect")
        }
    }
}

struct FontSizeMenu: View {
    let model: any TerminalSessionModel

    var body: some View {
        Menu {
            Button("Larger Text", systemImage: "textformat.size.larger") { model.adjustFontSize(by: 1) }
                .disabled(model.fontSize >= TerminalFontSize.range.upperBound)
            Button("Smaller Text", systemImage: "textformat.size.smaller") { model.adjustFontSize(by: -1) }
                .disabled(model.fontSize <= TerminalFontSize.range.lowerBound)
            Button("Default Size", systemImage: "arrow.counterclockwise") { model.setFontSize(TerminalFontSize.default) }
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
    let model: any TerminalSessionModel
    let screen: TerminalScreenHandle

    static let keys: [BarKey] = [
        BarKey(id: "esc", title: "esc", label: String(localized: "Escape"), key: .escape),
        BarKey(id: "tab", title: "tab", label: String(localized: "Tab"), key: .tab),
        BarKey(id: "ctrl", title: "ctrl", label: String(localized: "Control"), modifier: .control),
        BarKey(id: "alt", title: "alt", label: String(localized: "Alt"), modifier: .alt),
        BarKey(id: "left", symbol: "arrow.left", label: String(localized: "Left Arrow"), key: .left),
        BarKey(id: "down", symbol: "arrow.down", label: String(localized: "Down Arrow"), key: .down),
        BarKey(id: "up", symbol: "arrow.up", label: String(localized: "Up Arrow"), key: .up),
        BarKey(id: "right", symbol: "arrow.right", label: String(localized: "Right Arrow"), key: .right),
        BarKey(id: "slash", title: "/", label: String(localized: "Slash"), key: .character("/")),
        BarKey(id: "hyphen", title: "-", label: String(localized: "Hyphen"), key: .character("-")),
        BarKey(id: "pipe", title: "|", label: String(localized: "Vertical Bar"), key: .character("|")),
        BarKey(id: "tilde", title: "~", label: String(localized: "Tilde"), key: .character("~")),
        BarKey(id: "home", title: "home", label: String(localized: "Home"), key: .home),
        BarKey(id: "end", title: "end", label: String(localized: "End"), key: .end),
    ]

    /// iPhone Duo 直向折疊穿過按鍵列時的切分(#69);其他裝置與全開時是 `nil`。
    @State private var foldSplit: TerminalKeyBarFoldSplit?

    var body: some View {
        GlassEffectContainer {
            if let foldSplit {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        keyScroller
                    }
                    .padding(.horizontal, 6)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .padding(.leading, 8)
                    .frame(width: foldSplit.leadingWidth)
                    SwiftUI.Color.clear
                        .frame(width: foldSplit.gapWidth)
                        .accessibilityHidden(true)
                    HStack(spacing: 0) {
                        actionKeys
                    }
                    .padding(.horizontal, 6)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 0) {
                    keyScroller
                    Divider().frame(height: 28)
                    actionKeys
                }
                .padding(.horizontal, 6)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 6)
        .background {
            // iOS 27.0 SDK(SwiftUI 8.0.84)沒有 `reservedRegions`,同一版編譯器分不出 SDK,所以以 SwiftUI 模組版本判斷。
            #if !os(iOS) || canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *) {
                // 只取作用中的折疊區：全開時不留空，折疊時才小幅移開按鍵(HIG Designing for iPhone Duo)。
                GeometryReader { proxy in
                    let measuredSplit = TerminalKeyBarFoldSplit(
                        barWidth: proxy.size.width,
                        divisionFrames: proxy.reservedRegions(kind: .division).map(\.frame)
                    )
                    SwiftUI.Color.clear.onChange(of: measuredSplit, initial: true) { _, newSplit in
                        foldSplit = newSplit
                    }
                }
            }
            #endif
        }
    }

    private var keyScroller: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Self.keys) { key in
                    BarKeyButton(key: key, model: model, screen: screen)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var actionKeys: some View {
        PasteKey(model: model, screen: screen)
        KeyboardToggle(screen: screen)
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
    let model: any TerminalSessionModel
    let screen: TerminalScreenHandle

    private var isLocked: Bool { key.modifier.map(model.modifiers.contains) ?? false }

    var body: some View {
        Button {
            if let modifier = key.modifier {
                model.toggle(modifier)
            } else if let terminalKey = key.key {
                screen.pressKeyBarKey(terminalKey)
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
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(TerminalKeyButtonStyle(isLocked: isLocked))
        .disabled(!model.isInteractive)
        .accessibilityLabel(key.label)
        .accessibilityValue(key.modifier == nil ? "" : (isLocked ? "Locked" : "Off"))
        .accessibilityAddTraits(isLocked ? .isSelected : [])
        .accessibilityIdentifier("terminal.key.\(key.id)")
    }
}

/// 貼上剪貼簿文字(可能觸發系統的「允許貼上」)。不用 `PasteButton`:它的點擊範圍撐不到 44×44 pt。
struct PasteKey: View {
    let model: any TerminalSessionModel
    let screen: TerminalScreenHandle

    var body: some View {
        Button {
            if let text = UIPasteboard.general.string { screen.paste(text) }
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(TerminalKeyButtonStyle(isLocked: false))
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
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(TerminalKeyButtonStyle(isLocked: false))
        .accessibilityLabel(screen.isKeyboardVisible ? "Hide Keyboard" : "Show Keyboard")
        .accessibilityIdentifier("terminal.key.keyboard")
    }
}

/// 按鍵列的鍵：停用變暗、按下有底、鎖定用中性填色(`TerminalKeyAppearance`)。終端機強制深色，主要色即白字。
struct TerminalKeyButtonStyle: ButtonStyle {
    let isLocked: Bool

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, isLocked: isLocked)
    }

    private struct KeyBody: View {
        let configuration: ButtonStyleConfiguration
        let isLocked: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let appearance = TerminalKeyAppearance(isLocked: isLocked, isEnabled: isEnabled, isPressed: configuration.isPressed)
            configuration.label
                .foregroundStyle(appearance.text == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondaryText))
                .background(fillStyle(appearance.fill), in: .capsule)
        }

        private func fillStyle(_ fill: TerminalKeyAppearance.Fill) -> AnyShapeStyle {
            switch fill {
            case .none: AnyShapeStyle(SwiftUI.Color.clear)
            case .pressed: AnyShapeStyle(.fill.tertiary)
            case .locked: AnyShapeStyle(.fill.secondary)
            case .lockedPressed: AnyShapeStyle(.fill)
            }
        }
    }
}

// MARK: - 終端機畫面

/// 讓按鍵列操作終端機畫面的焦點與鍵盤。
@MainActor
@Observable
final class TerminalScreenHandle {
    fileprivate weak var screen: TerminalScreenContainer?
    private(set) var isKeyboardVisible = false

    func focus() {
        guard let input = screen?.textInput, !input.isFirstResponder else { return }
        _ = input.becomeFirstResponder()
    }

    func toggleKeyboard() {
        guard let input = screen?.textInput else { return }
        if input.isFirstResponder {
            _ = input.resignFirstResponder()
        } else {
            _ = input.becomeFirstResponder()
        }
    }

    /// 按鍵列的鍵經輸入元件送出(組字中先放棄組字)。
    func pressKeyBarKey(_ key: TerminalKey) {
        screen?.textInput.pressKeyBarKey(key)
    }

    /// 貼上經輸入元件送出(組字中先放棄組字)。
    func paste(_ text: String) {
        screen?.textInput.paste(text: text)
    }

    fileprivate func focusChanged(_ focused: Bool) {
        isKeyboardVisible = focused
    }
}

struct TerminalScreen: UIViewRepresentable {
    let model: any TerminalSessionModel
    let handle: TerminalScreenHandle
    /// 主機主題的配色;`nil` = 預設(黑底、淺灰字、SwiftTerm 的 ANSI 色)。
    var theme: TerminalTheme?
    /// 系統「粗體文字」:終端機字型是固定大小的等寬系統字(使用者用 `Aa` 調整),不會自動變粗，要自己跟著換(#35)。
    @Environment(\.legibilityWeight) private var legibilityWeight

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> TerminalScreenContainer {
        let screen = TerminalScreenContainer(
            terminalView: PurrdrTerminalView(frame: .zero, font: Self.font(model.fontSize, bold: legibilityWeight == .bold))
        )
        let view = screen.terminalView
        view.terminalDelegate = context.coordinator
        // 按鍵列由 SwiftUI 畫(玻璃容器);SwiftTerm 自帶的 accessory 關掉。
        view.inputAccessoryView = nil
        Self.apply(theme, to: view)
        context.coordinator.appliedTheme = theme
        // Pane 終端機的本機 scrollback 是空的(herdr 每次都重畫整個 viewport):滑動改送 terminal.scroll。
        // 登入 Shell 的 scrollback 在本機，由模擬器自己捲。
        view.isScrollEnabled = !model.usesRemoteScroll
        view.accessibilityIdentifier = "terminal.screen"
        screen.textInput.onFocusChange = { [weak handle, weak view] focused in
            view?.getTerminal().setTerminalFocus(focused)
            view?.setNeedsDisplay()
            handle?.focusChanged(focused)
        }
        screen.textInput.onSend = { [model, weak view] input in
            switch input {
            case .bytes(let bytes): model.type(bytes)
            case .key(let key, let modifiers, let applicationCursor): model.press(key, adding: modifiers, applicationCursor: applicationCursor)
            case .paste(let text): model.paste(text, bracketed: view?.bracketedPasteMode ?? false)
            }
        }
        // herdr 的串流不轉送終端機模式：Pane 終端機看不到，只有登入 Shell 讀模擬器。
        screen.textInput.programModes = { [model, weak view] in
            guard model.seesProgramModes, let view else { return .hiddenByHerdr }
            return view.visibleProgramModes
        }
        screen.textInput.onScrollPageLocally = { [weak view] direction in
            guard let view else { return }
            let rows = view.getTerminal().rows
            if direction == .up {
                view.scrollUp(lines: rows)
            } else {
                view.scrollDown(lines: rows)
            }
        }
        screen.textInput.onSendPageKeyToHerdr = { [model, weak view] direction in
            model.scrollPage(direction, rows: view?.getTerminal().rows ?? 1)
        }
        context.coordinator.install(on: view)
        handle.screen = screen
        // 畫面更新(含游標移動)後由 `rangeChanged` 通知，把輸入元件移到游標格子。
        view.notifyUpdateChanges = true
        model.attach { [weak view] bytes in view?.feed(byteArray: ArraySlice(bytes)) }
        return screen
    }

    func updateUIView(_ screen: TerminalScreenContainer, context: Context) {
        let view = screen.terminalView
        if context.coordinator.appliedTheme != theme {
            Self.apply(theme, to: view)
            context.coordinator.appliedTheme = theme
        }
        let font = Self.font(model.fontSize, bold: legibilityWeight == .bold)
        if view.font.pointSize != font.pointSize || view.font.fontName != font.fontName {
            view.font = font
            screen.cursorMayHaveMoved()
        }
    }

    /// 套用終端機配色;主題的文字與背景對比已在 `HostTheme` 檢查過(不足 4.5:1 時 `theme` 是 `nil`)。
    static func apply(_ theme: TerminalTheme?, to view: PurrdrTerminalView) {
        if let theme {
            view.installColors(theme.swiftTermColors)
            view.installedPalette = theme.swiftTermColors
            view.nativeBackgroundColor = UIColor(theme.background)
            view.nativeForegroundColor = UIColor(theme.foreground)
            view.caretColor = theme.cursor.map(UIColor.init) ?? .systemGray
        } else {
            view.installColors(SwiftTerm.Color.defaultInstalledColors)
            view.installedPalette = SwiftTerm.Color.defaultInstalledColors
            view.nativeBackgroundColor = .black
            view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
            view.caretColor = .systemGray
        }
    }

    static func font(_ size: Double, bold: Bool = false) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let model: any TerminalSessionModel
        var appliedTheme: TerminalTheme?
        private var pinchStartSize: Double = TerminalFontSize.default
        private var scrolledRows = 0

        init(model: any TerminalSessionModel) {
            self.model = model
        }

        func install(on view: PurrdrTerminalView) {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)
            guard model.usesRemoteScroll else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
            // 捏合(兩指)與滑動(一指)預設就不會同時辨識。不能用 `require(toFail: pinch)`:
            // 一指時捏合要等手指離開才失敗，滑動被壓到放開才開始，一列都沒送出(#94)。
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
                guard let url = TerminalLinks.openableURL(link) else { return }
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
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            MainActor.assumeIsolated { (source.superview as? TerminalScreenContainer)?.terminalDisplayDidUpdate() }
        }
    }
}

/// 終端機畫面與疊在游標格子上的輸入元件、組字浮層。
final class TerminalScreenContainer: UIView {
    let terminalView: PurrdrTerminalView
    let textInput = TerminalTextInputView(frame: .zero)
    let compositionOverlay = TerminalCompositionOverlay(frame: .zero)
    private var isCursorUpdateQueued = false

    init(terminalView: PurrdrTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        terminalView.frame = bounds
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(terminalView)
        addSubview(compositionOverlay)
        addSubview(textInput)
        textInput.editActionTarget = terminalView
        textInput.onCompositionChange = { [weak self] in self?.updateCompositionOverlay() }
        terminalView.textInput = textInput
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeTextInput()
    }

    /// SwiftTerm 更新畫面(游標已移到新位置)後呼叫。
    func terminalDisplayDidUpdate() {
        placeTextInput()
    }

    /// 字級改變後，等 SwiftTerm 重新排版再把輸入元件移到游標格子。
    func cursorMayHaveMoved() {
        guard !isCursorUpdateQueued else { return }
        isCursorUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.isCursorUpdateQueued = false
            self?.placeTextInput()
        }
    }

    private func placeTextInput() {
        let caret = terminalView.caretFrame
        guard caret.width > 0, caret.height > 0 else { return }
        // 游標在寬字元上時 caret 是兩格寬;輸入元件只佔一格。
        let cellWidth = caret.width / CGFloat(terminalView.cursorCellColumns)
        var cell = terminalView.convert(caret, to: self)
        cell.size.width = cellWidth
        textInput.frame = cell
        textInput.cellWidth = cellWidth
        textInput.screenWidth = terminalView.frame.maxX
        updateCompositionOverlay()
    }

    private func updateCompositionOverlay() {
        let box = textInput.compositionLayout.overlay
        let colors = terminalView.cursorCellColors
        compositionOverlay.show(
            textInput.composition.markedText,
            selectedRange: textInput.markedSelection,
            frame: CGRect(x: box.x, y: box.y, width: box.width, height: box.height),
            font: terminalView.font,
            cellWidth: textInput.cellWidth,
            textColor: colors.foreground,
            backgroundColor: colors.background
        )
    }
}

/// SwiftTerm 的終端機視圖，加上給 VoiceOver(與 UI 測試)讀的畫面文字。
/// 鍵盤焦點在 `TerminalTextInputView`;它自己不當 first responder,但點畫面、游標樣式照「聚焦」處理。
final class PurrdrTerminalView: TerminalView {
    weak var textInput: TerminalTextInputView?
    /// 目前套用的 16 色(組字浮層取游標格子的顏色用)。
    var installedPalette = SwiftTerm.Color.defaultInstalledColors

    /// 程式是否開了 bracketed paste 模式(登入 Shell 用;Pane 終端機看不到 Pane 的模式)。
    var bracketedPasteMode: Bool { getTerminal().bracketedPasteMode }

    /// 模擬器看到的遠端程式模式(登入 Shell 直接接 PTY 才準)。
    var visibleProgramModes: TerminalProgramModes {
        let terminal = getTerminal()
        return .visible(applicationCursor: terminal.applicationCursor, alternateScreen: terminal.isCurrentBufferAlternate)
    }

    /// 游標所在字元佔的格數(寬字元 2)。
    var cursorCellColumns: Int {
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        return max(1, Int(terminal.getCharData(col: cursor.x, row: cursor.y)?.width ?? 1))
    }

    /// 游標格子的文字色與背景色(反白時對調)。
    var cursorCellColors: (foreground: UIColor, background: UIColor) {
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        guard let attribute = terminal.getCharData(col: cursor.x, row: cursor.y)?.attribute else {
            return (nativeForegroundColor, nativeBackgroundColor)
        }
        let foreground = color(attribute.fg, isForeground: true)
        let background = color(attribute.bg, isForeground: false)
        return attribute.style.contains(.inverse) ? (background, foreground) : (foreground, background)
    }

    private func color(_ color: SwiftTerm.Attribute.Color, isForeground: Bool) -> UIColor {
        switch color {
        case .defaultColor:
            return isForeground ? nativeForegroundColor : nativeBackgroundColor
        case .defaultInvertedColor:
            return isForeground ? nativeBackgroundColor : nativeForegroundColor
        case .trueColor(let red, let green, let blue):
            return UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .ansi256(let code):
            if Int(code) < installedPalette.count {
                let entry = installedPalette[Int(code)]
                return UIColor(red: CGFloat(entry.red) / 65535, green: CGFloat(entry.green) / 65535, blue: CGFloat(entry.blue) / 65535, alpha: 1)
            }
            guard let rgb = XtermPalette.color(code) else { return nativeForegroundColor }
            return UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        }
    }

    override var canBecomeFirstResponder: Bool { false }

    /// SwiftTerm 點畫面時要焦點：交給輸入元件。
    override func becomeFirstResponder() -> Bool {
        textInput?.becomeFirstResponder() ?? false
    }

    /// SwiftTerm 依這個決定點畫面的行為(連結、滑鼠回報)與游標樣式。
    override var isFirstResponder: Bool {
        textInput?.isFirstResponder ?? false
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

// MARK: - 主機主題的終端機配色(#23)

extension TerminalTheme {
    /// SwiftTerm 的 16 色;主題丟掉的格子用 SwiftTerm 預設。
    var swiftTermColors: [SwiftTerm.Color] {
        let defaults = SwiftTerm.Color.defaultInstalledColors
        return ansi.enumerated().map { index, color in
            color.map(SwiftTerm.Color.init) ?? defaults[index]
        }
    }
}

extension SwiftTerm.Color {
    convenience init(_ color: ThemeColor) {
        self.init(red: UInt16(color.red) * 257, green: UInt16(color.green) * 257, blue: UInt16(color.blue) * 257)
    }
}

extension UIColor {
    convenience init(_ color: ThemeColor) {
        self.init(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }
}
#endif
