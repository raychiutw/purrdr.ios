import Foundation
import Testing

/// 非同步 closure 參數的預設值不用 closure 字面值(#105)。
///
/// `@MainActor` 型別的 init 以 `{ try await Task.sleep(for: $0) }` 當預設值、再從 task group 的子 task 呼叫時，
/// 以 native build system 編譯的測試會在 `swift_task_dealloc` 中止(`freed pointer was not the last allocation`);
/// 預設值改成 `Sleeping.task` 這類非隔離的常數就不會。
@Suite("非同步 closure 的預設值")
struct AsyncDefaultArgumentTests {
    /// `@escaping` 的非同步 closure 型別(含 `Sleep` 別名)接著 `= {`。型別本身標 `@MainActor` 的不算(沒有隔離轉換)。
    static func hasAsyncClosureLiteralDefault(_ line: String) -> Bool {
        guard !line.contains("@MainActor") else { return false }
        return line.range(of: #"@escaping[^=]*(\basync\b|\bSleep\b)[^=]*=\s*\{"#, options: .regularExpression) != nil
    }

    @Test("判斷規則：async closure 與 Sleep 別名的字面值預設值算違規;常數預設值、@MainActor 型別不算")
    func detectsAsyncClosureLiteralDefaults() {
        #expect(Self.hasAsyncClosureLiteralDefault("sleep: @escaping Sleep = { try await Task.sleep(for: $0) }"))
        #expect(Self.hasAsyncClosureLiteralDefault(
            "init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {"
        ))
        #expect(!Self.hasAsyncClosureLiteralDefault("sleep: @escaping Sleep = Sleeping.task"))
        #expect(!Self.hasAsyncClosureLiteralDefault("refresh: @escaping @MainActor () async -> Void = {}"))
        #expect(!Self.hasAsyncClosureLiteralDefault("isLocked: @escaping @Sendable () -> Bool = { false }"))
    }

    @Test("正式程式碼的非同步 closure 參數沒有以 closure 字面值當預設值")
    func sourcesUseConstantDefaults() throws {
        let files = HostConnectionBoundaryTests.sources(in: "src")
        #expect(!files.isEmpty, "沒有掃到任何原始碼，路徑可能錯了")
        var violations: [String] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            where Self.hasAsyncClosureLiteralDefault(String(line)) {
                violations.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(violations.isEmpty, "改用 Sleeping.task 之類的常數：\(violations)")
    }
}
