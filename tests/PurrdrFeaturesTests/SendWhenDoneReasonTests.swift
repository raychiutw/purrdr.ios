#if os(macOS)
import Foundation
import PurrdrCore
import Testing

@testable import PurrdrFeatures

/// 「做完再送」不能用的原因文字(#626、spec #612):寫在開關下方的說明,不再點了才跳 alert。
@Suite("做完再送停用原因")
struct SendWhenDoneReasonTests {
    @Test("可用時沒有原因,不能用的兩種各有說明")
    func reasonPerAvailability() {
        #expect(SendWhenDoneAvailability.available.unavailabilityReason == nil)
        #expect(SendWhenDoneAvailability.needsHostService.unavailabilityReason?.contains("host service") == true)
        #expect(SendWhenDoneAvailability.readOnlyDevice.unavailabilityReason?.contains("read-only") == true)
    }
}
#endif
