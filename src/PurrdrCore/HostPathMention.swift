import Foundation

/// 訊息文字中的主機絕對路徑(#229)。主機服務以同一套規則(`host_path_mentions.rs`)判斷「對話紀錄出現過」,
/// 兩端共用 `vendor/purrdr-host/protocol/host-path-mentions.json` 的案例。
///
/// - POSIX(`/` 開頭、至少兩段)與 Windows 磁碟機路徑(`C:\…`、`C:/…`);不含 `.`／`..`、空段落，結尾不是分隔符號。
/// - 一般文字裡的路徑到空白或標點為止，前面要接空白、標點或非 ASCII 文字;句尾標點與 `:行號` 不算。
/// - 含空白的路徑要整段包在反引號、`"…"`、`“…”`、`「…」` 或 `『…』` 裡。行內 code 與程式碼區塊只在整段是路徑時才算。
/// - 網址、`~`、相對路徑不算。
public enum HostPathMention {
    /// 一個路徑：在原文中的範圍與路徑本身。
    public struct Match: Equatable, Sendable {
        public var range: Range<String.Index>
        public var path: String
    }

    /// 文字中認得的主機路徑，依出現順序。
    public static func paths(in text: String) -> [String] {
        matches(in: text).map(\.path)
    }

    /// 文字中認得的主機路徑與範圍(反引號內的路徑也算)。
    public static func matches(in text: String) -> [Match] {
        let scalars = Array(text.unicodeScalars)
        let indices = Array(text.unicodeScalars.indices) + [text.unicodeScalars.endIndex]
        var found: [Match] = []
        func record(_ start: Int, _ path: String) {
            let end = start + path.unicodeScalars.count
            found.append(Match(range: indices[start]..<indices[end], path: path))
        }
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            if scalar == "`" {
                let run = runLength(of: "`", in: scalars, at: position)
                guard let close = closingRun(of: run, in: scalars, after: position + run) else {
                    position += run
                    continue
                }
                var start = position + run
                var content = string(scalars[start..<close])
                if content.unicodeScalars.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "), content.contains(where: { $0 != " " }) {
                    content = String(content.dropFirst().dropLast())
                    start += 1
                }
                if let path = path(inCodeSpan: content) { record(start, path) }
                position = close + run
                continue
            }
            if let closing = quotePairs[scalar],
               let close = scalars[(position + 1)...].firstIndex(where: { $0 == closing || $0 == "\n" }), scalars[close] == closing,
               let path = delimitedPath(string(scalars[(position + 1)..<close])) {
                record(position + 1, path)
                position = close + 1
                continue
            }
            if let end = bareEnd(in: scalars, at: position) {
                let candidate = string(scalars[position..<end])
                if isHostPath(candidate, allowsSpaces: false) {
                    record(position, candidate)
                    position = end
                    continue
                }
            }
            position += 1
        }
        return found
    }

    /// 行內 code 的內容整段是主機路徑(可含空白，結尾可帶 `:行號`)時回路徑。
    public static func path(inCodeSpan code: String) -> String? {
        delimitedPath(code)
    }

    /// 可點路徑的連結(畫面攔下，不交給系統 openURL)。
    public static func linkURL(for path: String) -> URL? {
        // 只留英數與 `-._~/`,其他(空白、中文、`\`、`#`、`&`、`+`…)都編碼，平台間解讀一致。
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: linkAllowed) else { return nil }
        return URL(string: "\(linkScheme):?path=\(encoded)")
    }

    /// `linkURL(for:)` 的路徑;其他網址回 `nil`。
    public static func path(fromLink url: URL) -> String? {
        // 從 absoluteString 讀，不用 `query`:沒有 `//` 的網址經 NSURL 橋接(SwiftUI 點文字連結交回的就是)時舊解析器讀不到 query(#251)。
        let prefix = "\(linkScheme):?path="
        let string = url.absoluteString
        guard string.hasPrefix(prefix) else { return nil }
        return string.dropFirst(prefix.count).removingPercentEncoding
    }

    private static let linkScheme = "purrdr-host-path"
    private static let linkAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")

    // MARK: 規則

    private static let quotePairs: [Unicode.Scalar: Unicode.Scalar] = ["\"": "\"", "“": "”", "「": "」", "『": "』"]

    /// 一般文字中的路徑在這些字元前結束。
    private static let terminators = Set("`\"'<>|*[]{},;:「」『』（）【】《》〈〉“”‘’，。、；：！？".unicodeScalars)

    /// 路徑前面接這些字元時不算開頭(例如 `a/b`、`https://`、`~/`、`./`)。
    private static let continuations = Set("/\\.~-_$%@+&#".unicodeScalars)

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func runLength(of scalar: Unicode.Scalar, in scalars: [Unicode.Scalar], at position: Int) -> Int {
        var count = 0
        while position + count < scalars.count, scalars[position + count] == scalar { count += 1 }
        return count
    }

    /// 長度剛好是 `run` 的下一串反引號的開頭。
    private static func closingRun(of run: Int, in scalars: [Unicode.Scalar], after start: Int) -> Int? {
        var search = start
        while search < scalars.count {
            guard scalars[search] == "`" else {
                search += 1
                continue
            }
            let length = runLength(of: "`", in: scalars, at: search)
            if length == run { return search }
            search += length
        }
        return nil
    }

    /// 從 `position` 開始的一般文字路徑的結尾;這裡不是路徑開頭時 `nil`。
    private static func bareEnd(in scalars: [Unicode.Scalar], at position: Int) -> Int? {
        if position > 0 {
            let previous = scalars[position - 1]
            guard !(previous.isASCII && (previous.properties.isAlphabetic || ("0"..."9").contains(previous))), !continuations.contains(previous) else {
                return nil
            }
        }
        let isWindows = position + 2 < scalars.count && isASCIILetter(scalars[position]) && scalars[position + 1] == ":"
            && (scalars[position + 2] == "\\" || scalars[position + 2] == "/")
        guard isWindows || scalars[position] == "/" else { return nil }
        var end = isWindows ? position + 2 : position
        while end < scalars.count, !isTerminator(scalars[end]) { end += 1 }
        while end > position {
            let last = scalars[end - 1]
            let opening = scalars[position..<end].count { $0 == "(" }
            let closing = scalars[position..<end].count { $0 == ")" }
            guard ".!?".unicodeScalars.contains(last) || (last == ")" && closing > opening) else { break }
            end -= 1
        }
        return end
    }

    private static func isTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.generalCategory == .control || terminators.contains(scalar)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// 包起來的整段：去掉結尾的 `:行號`(與 `:欄`)後是主機路徑(可含空白)。
    private static func delimitedPath(_ content: String) -> String? {
        let path = content.replacing(/:\d+(:\d+)?$/, with: "")
        return isHostPath(path, allowsSpaces: true) ? path : nil
    }

    /// 整段是一個主機絕對路徑。
    private static func isHostPath(_ candidate: String, allowsSpaces: Bool) -> Bool {
        let scalars = candidate.unicodeScalars
        guard let first = scalars.first, let last = scalars.last, first != " ", last != " " else { return false }
        for scalar in scalars where scalar.properties.generalCategory == .control || scalar.properties.isWhitespace {
            guard allowsSpaces, scalar == " " else { return false }
        }
        let components: [Substring]
        let minimumCount: Int
        if HostPathSyntax.isWindowsDrivePath(candidate) {
            guard !candidate.dropFirst(2).contains(where: { "<>:\"|?*".contains($0) }) else { return false }
            components = candidate.dropFirst(3).split(separator: /[\\\/]/, omittingEmptySubsequences: false)
            minimumCount = 1
        } else if first == "/" {
            components = candidate.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            minimumCount = 2
        } else {
            return false
        }
        return components.count >= minimumCount
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }
    }
}
