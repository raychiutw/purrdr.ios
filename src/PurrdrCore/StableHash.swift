import Foundation

/// 跨啟動穩定的雜湊(`hashValue` 每次啟動不同,不能拿來比對或當 id)。
package enum StableHash {
    /// FNV-1a 64 位元,輸出十六進位(不補零)。
    package static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
