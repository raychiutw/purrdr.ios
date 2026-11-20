import Foundation
import PurrdrCore
import Testing

/// 這支裝置的推播 id:主機路徑與後台「通知裝置」共用同一個(審查 #1)。
@Suite("推播裝置 id")
struct PushDeviceIDTests {
    static func isUUIDShaped(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(\.count)
        return parts == [8, 4, 4, 4, 12] && text.replacingOccurrences(of: "-", with: "").allSatisfy(\.isHexDigit)
            && text == text.lowercased()
    }

    @Test("新產生的 id 是小寫 UUID,主機路徑與後台用同一個值")
    func generatedIDIsLowercaseUUID() {
        let id = PushDeviceID.generate()

        #expect(Self.isUUIDShaped(id.rawValue))
        #expect(id.backendValue == id.rawValue)
        #expect(PushDeviceID(rawValue: id.rawValue) == id)
    }

    @Test("0.45 以前的 16 位 hex 沿用為主機路徑，後台值換成固定的 UUID 格式")
    func legacyIDKeepsHostPathAndMapsBackendValue() throws {
        let legacy = try #require(PushDeviceID(rawValue: "0123456789abcdef"))

        #expect(legacy.rawValue == "0123456789abcdef")
        #expect(Self.isUUIDShaped(legacy.backendValue))
        #expect(legacy.backendValue == PushDeviceID(rawValue: "0123456789abcdef")?.backendValue)
        #expect(legacy.backendValue != PushDeviceID(rawValue: "fedcba9876543210")?.backendValue)
    }

    @Test("會拼進主機路徑：只接受 1～64 個小寫英數與 -,且不能是 plugin",
          arguments: ["", "plugin", "ABCDEF", "a/b", "a b", "../x", String(repeating: "a", count: 65)])
    func rejectsUnsafeIDs(_ raw: String) {
        #expect(PushDeviceID(rawValue: raw) == nil)
    }
}
