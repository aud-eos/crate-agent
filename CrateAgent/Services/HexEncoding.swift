import Foundation

extension Sequence<UInt8> {
    /// Lowercase hex of the bytes. `String(format: "%02x")` per byte costs a format parse
    /// each time, which dominated duplicate scans that key thousands of digests (#247).
    var lowercaseHex: String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
