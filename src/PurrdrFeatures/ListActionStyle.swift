import SwiftUI

/// 清單裡的一般動作列(#638、spec #634):文字用主要標籤色、圖示用次要色。
///
/// SwiftUI 的 List 會把 Button 整個染成 app 主色,一頁動作列就整片綠。HIG 要求主色節制使用,
/// 所以主色只留給主要動作(`filledProminentButtonStyle`)、連結、勾選／選取與狀態圖示;
/// 一般動作列(顯示歡迎頁、評分、支援、拷貝、重試…)明確指定顏色,不吃 List 的 tint。
/// 破壞性動作(role: .destructive)不套這個,另有 `destructiveText` 的規則(#639)。
struct ListActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title.foregroundStyle(.primary)
        } icon: {
            configuration.icon.foregroundStyle(.secondary)
        }
    }
}

/// 清單內破壞性動作(#639):文字與圖示同一種紅 `destructiveText`。
/// 系統 `role: .destructive` 的紅(#FF453A)在深色卡片上只有約 4.1:1,文字要 4.5:1,所以改用 `destructiveText`;
/// role 保留,VoiceOver 與系統行為不變。
struct DestructiveListActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title.foregroundStyle(Color.destructiveText)
        } icon: {
            configuration.icon.foregroundStyle(Color.destructiveText)
        }
    }
}

extension View {
    /// 加在 List 內的破壞性 Button(`role: .destructive`)上。
    func destructiveListAction() -> some View {
        tint(.destructiveText).foregroundStyle(Color.destructiveText).labelStyle(DestructiveListActionLabelStyle())
    }
}

extension View {
    /// 加在 List 內的一般動作 Button 上(只有文字的按鈕靠 tint、有圖示的靠 label style)。
    func listAction() -> some View {
        tint(.primary).labelStyle(ListActionLabelStyle())
    }
}
