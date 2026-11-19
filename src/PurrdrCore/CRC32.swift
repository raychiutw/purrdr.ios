import Foundation

/// CRC-32(IEEE 802.3,gzip 用的那個)。
package enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    package static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        // 經 buffer 逐 byte 讀：Debug 建置下大檔(Demo 的 8.8 MiB 掃描檔)也不吃 CPU。
        table.withUnsafeBufferPointer { lookup in
            data.withUnsafeBytes { bytes in
                for byte in bytes {
                    crc = lookup[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
