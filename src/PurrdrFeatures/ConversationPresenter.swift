import QuickLook
import SwiftUI

/// 對話列表的列嵌在 `UIHostingConfiguration` 裡，列內的 sheet、全螢幕與導覽沒有可靠的呈現者(#487):
/// `ConversationView` 注入這組能力，列改由對話畫面本身呈現。沒有注入時(其他畫面裡的同一批卡片)維持原本的修飾詞。
struct ConversationPresenter {
    var previewFile: @MainActor (URL) -> Void
    var viewImage: @MainActor (ImageViewerItem) -> Void
    var showSheet: @MainActor (AnyView) -> Void
    var open: @MainActor (DelegationRoute) -> Void
}

/// 列的展開狀態(工具串、思考、呼叫結果、折疊區塊):存在對話時間軸，列被重用或捲出畫面再回來也維持。
/// 參數是列 id 與列內子項 id(整列為 `nil`)。
struct RowExpansion {
    var isExpanded: @MainActor (String, String?) -> Bool
    var setExpanded: @MainActor (Bool, String, String?) -> Void
}

/// 列內某個可展開區塊的狀態來源:有注入列展開狀態與列 id 時存時間軸，否則(其他畫面)用本地 `@State`。
struct ExpansionState: DynamicProperty {
    let partID: String?
    var rowIDOverride: String?
    @State private var localExpanded = false
    @Environment(\.rowExpansion) private var expansion
    @Environment(\.expansionRowID) private var environmentRowID

    init(partID: String?, rowID: String? = nil) {
        self.partID = partID
        self.rowIDOverride = rowID
    }

    var binding: Binding<Bool> {
        guard let expansion, let rowID = rowIDOverride ?? environmentRowID else { return $localExpanded }
        let partID = partID
        return Binding(
            get: { expansion.isExpanded(rowID, partID) },
            set: { expansion.setExpanded($0, rowID, partID) })
    }

}

extension EnvironmentValues {
    @Entry var conversationPresenter: ConversationPresenter?
    @Entry var rowExpansion: RowExpansion?
    /// 目前這一列的時間軸列 id(列內的可展開區塊以它加子項 id 找狀態)。
    @Entry var expansionRowID: String?
}

/// 對話畫面用的 sheet 內容(`sheet(item:)` 需要 Identifiable)。
struct ConversationSheetContent: Identifiable {
    let id = UUID()
    let content: AnyView
}

private struct PresentedQuickLook: ViewModifier {
    @Binding var file: URL?
    @Environment(\.conversationPresenter) private var presenter

    func body(content: Content) -> some View {
        if let presenter {
            content.onChange(of: file) { _, newFile in
                guard let newFile else { return }
                presenter.previewFile(newFile)
                file = nil
            }
        } else {
            content.quickLookPreview($file)
        }
    }
}

private struct PresentedImageViewer: ViewModifier {
    @Binding var item: ImageViewerItem?
    @Environment(\.conversationPresenter) private var presenter

    func body(content: Content) -> some View {
        if let presenter {
            content.onChange(of: item?.id) {
                guard let shown = item else { return }
                presenter.viewImage(shown)
                item = nil
            }
        } else {
            content.imageViewer(item: $item)
        }
    }
}

private struct PresentedSheet<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheet: () -> Sheet
    @Environment(\.conversationPresenter) private var presenter

    func body(content: Content) -> some View {
        if let presenter {
            content.onChange(of: isPresented) { _, shows in
                guard shows else { return }
                presenter.showSheet(AnyView(sheet()))
                isPresented = false
            }
        } else {
            content.sheet(isPresented: $isPresented, content: sheet)
        }
    }
}

extension View {
    /// 預覽檔案:有對話呈現者時交給它，否則自己呈現。
    func presentedQuickLook(_ file: Binding<URL?>) -> some View {
        modifier(PresentedQuickLook(file: file))
    }

    /// 全螢幕圖片檢視:有對話呈現者時交給它，否則自己呈現。
    func presentedImageViewer(item: Binding<ImageViewerItem?>) -> some View {
        modifier(PresentedImageViewer(item: item))
    }

    /// sheet:有對話呈現者時交給它，否則自己呈現。
    func presentedSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(PresentedSheet(isPresented: isPresented, sheet: content))
    }
}

/// 開啟 subagent 畫面:有對話呈現者時由它推入，否則用 `NavigationLink`。
struct DelegationRouteLink<Label: View>: View {
    let route: DelegationRoute
    @ViewBuilder let label: () -> Label
    @Environment(\.conversationPresenter) private var presenter

    var body: some View {
        if let presenter {
            Button { presenter.open(route) } label: { label() }
        } else {
            NavigationLink(value: route) { label() }
        }
    }
}
