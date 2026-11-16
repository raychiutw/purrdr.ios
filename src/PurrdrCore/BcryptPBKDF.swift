import Crypto
import Foundation

/// OpenBSD 的 `bcrypt_pbkdf`:OpenSSH 私鑰檔以它從 passphrase 推出加密金鑰(`kdfname` = `bcrypt`)。
///
/// 依 OpenBSD `lib/libutil/bcrypt_pbkdf.c` 的演算法以 Swift 實作;正確性由測試對 `ssh-keygen` 產生的
/// 加密金鑰驗證(推錯金鑰就解不開，檢查值不符)。
enum BcryptPBKDF {
    static func derive(passphrase: Data, salt: Data, rounds: Int, count keyLength: Int) -> Data {
        precondition(rounds >= 1 && keyLength > 0)
        let blockSize = 32
        let stride = (keyLength + blockSize - 1) / blockSize
        let amount = (keyLength + stride - 1) / stride
        let hashedPassphrase = Array(SHA512.hash(data: passphrase))
        var key = [UInt8](repeating: 0, count: keyLength)
        var remaining = keyLength
        var counter: UInt32 = 1
        while remaining > 0 {
            var counted = Array(salt)
            counted += [UInt8(counter >> 24), UInt8(truncatingIfNeeded: counter >> 16), UInt8(truncatingIfNeeded: counter >> 8), UInt8(truncatingIfNeeded: counter)]
            var hashedSalt = Array(SHA512.hash(data: counted))
            var block = hash(hashedPassphrase, hashedSalt)
            var output = block
            for _ in 1..<rounds {
                hashedSalt = Array(SHA512.hash(data: block))
                block = hash(hashedPassphrase, hashedSalt)
                for index in output.indices { output[index] ^= block[index] }
            }
            var written = 0
            for index in 0..<min(amount, remaining) {
                let destination = index * stride + Int(counter - 1)
                if destination >= keyLength { break }
                key[destination] = output[index]
                written += 1
            }
            remaining -= written
            counter += 1
        }
        return Data(key)
    }

    /// bcrypt_hash:以 SHA-512 後的 passphrase 與 salt 做 eksblowfish 金鑰排程，再加密固定字串 64 次。
    private static func hash(_ passphrase: [UInt8], _ salt: [UInt8]) -> [UInt8] {
        var cipher = Blowfish()
        cipher.expand(data: salt, key: passphrase)
        for _ in 0..<64 {
            cipher.expand(key: salt)
            cipher.expand(key: passphrase)
        }
        var words = Blowfish.words(Array("OxychromaticBlowfishSwatDynamite".utf8))
        for _ in 0..<64 {
            for index in Swift.stride(from: 0, to: words.count, by: 2) {
                (words[index], words[index + 1]) = cipher.encrypt(words[index], words[index + 1])
            }
        }
        // 輸出是小端序(與 OpenBSD 實作相同)。
        return words.flatMap { word in
            [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16), UInt8(word >> 24)]
        }
    }
}

/// Blowfish(只有 bcrypt 需要的部分：加密一個區塊與 eksblowfish 的金鑰排程)。
struct Blowfish {
    /// P 陣列 18 個字，之後 4 個 S-box 各 256 個字。
    private var state = blowfishInitialState

    /// 大端序把位元組串讀成字(循環讀取，與 OpenBSD 的 `Blowfish_stream2word` 相同)。
    static func words(_ bytes: [UInt8]) -> [UInt32] {
        Swift.stride(from: 0, to: bytes.count, by: 4).map { start in
            (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[(start + $1) % bytes.count]) }
        }
    }

    /// `Blowfish_expandstate`:以 key 混入 P,再一邊混 data 一邊重算整個狀態。
    mutating func expand(data: [UInt8], key: [UInt8]) {
        mixKey(key)
        var position = 0
        regenerate { Self.nextWord(data, &position) }
    }

    /// `Blowfish_expand0state`:同上但不混 data。
    mutating func expand(key: [UInt8]) {
        mixKey(key)
        regenerate { 0 }
    }

    func encrypt(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        state.withUnsafeBufferPointer { Self.encipher(left, right, $0) }
    }

    private mutating func mixKey(_ key: [UInt8]) {
        var position = 0
        for index in 0..<18 { state[index] ^= Self.nextWord(key, &position) }
    }

    private mutating func regenerate(_ next: () -> UInt32) {
        state.withUnsafeMutableBufferPointer { buffer in
            var left: UInt32 = 0
            var right: UInt32 = 0
            for index in Swift.stride(from: 0, to: buffer.count, by: 2) {
                left ^= next()
                right ^= next()
                (left, right) = Self.encipher(left, right, UnsafeBufferPointer(buffer))
                buffer[index] = left
                buffer[index + 1] = right
            }
        }
    }

    private static func nextWord(_ bytes: [UInt8], _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if position >= bytes.count { position = 0 }
            word = word << 8 | UInt32(bytes[position])
            position += 1
        }
        return word
    }

    private static func encipher(_ left: UInt32, _ right: UInt32, _ state: UnsafeBufferPointer<UInt32>) -> (UInt32, UInt32) {
        var left = left ^ state[0]
        var right = right
        for round in Swift.stride(from: 1, through: 16, by: 2) {
            right ^= f(left, state) ^ state[round]
            left ^= f(right, state) ^ state[round + 1]
        }
        return (right ^ state[17], left)
    }

    @inline(__always)
    private static func f(_ value: UInt32, _ state: UnsafeBufferPointer<UInt32>) -> UInt32 {
        let a = state[18 + Int(value >> 24)]
        let b = state[18 + 256 + Int((value >> 16) & 0xFF)]
        let c = state[18 + 512 + Int((value >> 8) & 0xFF)]
        let d = state[18 + 768 + Int(value & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }
}
