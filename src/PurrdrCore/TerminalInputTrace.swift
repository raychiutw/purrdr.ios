import Foundation

/// 終端機輸入元件的輸入入口(診斷紀錄的事件名稱)。
public enum TerminalInputCall: String, Sendable, CaseIterable {
    case setMarkedText, unmarkText, insertText, deleteBackward, replace
    case becomeFirstResponder, resignFirstResponder, cancelComposition
    case keyBarKey, paste
}

/// 終端機輸入的診斷紀錄：把一次輸入呼叫描述成一行，只含字元類別與長度，不含原文。
public enum TerminalInputTrace {
    private static let classLimit = 40

    /// 一次輸入呼叫的紀錄行。`text` 是呼叫帶進來的文字(setMarkedText、insertText、replace)。
    public static func line(
        _ call: TerminalInputCall, text: String? = nil, selectedRange: NSRange,
        markedBefore: String, markedAfter: String, sent: [TerminalRemoteInput]
    ) -> String {
        var fields = [call.rawValue]
        if let text { fields.append("text=\(summary(text))") }
        fields.append("sel=\(selectedRange.location)+\(selectedRange.length)")
        fields.append("marked=\(summary(markedBefore))>\(summary(markedAfter))")
        fields.append("sent=\(describe(sent))")
        return fields.joined(separator: " ")
    }

    /// 每個字元的類別：注音 Z、聲調 T、漢字 H、ASCII A、其他 O;空字串是 `-`,超過 40 個字元截斷。
    public static func characterClasses(_ text: String) -> String {
        guard !text.isEmpty else { return "-" }
        let classes = text.prefix(classLimit).map(characterClass)
        return String(classes) + (text.count > classLimit ? "…" : "")
    }

    private static func summary(_ text: String) -> String {
        "\(text.utf16.count):\(characterClasses(text))"
    }

    private static func characterClass(_ character: Character) -> Character {
        let scalars = character.unicodeScalars
        if scalars.contains(where: \.isZhuyin) { return "Z" }
        if scalars.contains(where: \.isZhuyinTone) { return "T" }
        if character.isASCII { return "A" }
        if let first = scalars.first, first.isHan { return "H" }
        return "O"
    }

    private static func describe(_ sent: [TerminalRemoteInput]) -> String {
        guard !sent.isEmpty else { return "none" }
        return sent.map { input in
            switch input {
            case .bytes(let bytes): "bytes:\(bytes.count)"
            case .key: "key"
            case .paste(let text): "paste:\(text.utf8.count)"
            }
        }.joined(separator: ",")
    }
}

extension Unicode.Scalar {
    /// CJK 統一漢字(含擴充 A 起各區與相容漢字)。
    var isHan: Bool {
        (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x323AF).contains(value) || (0xF900...0xFAFF).contains(value)
    }
}
