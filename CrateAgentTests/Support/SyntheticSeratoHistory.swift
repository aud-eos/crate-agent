import Foundation

/// Writes synthetic Serato `History/Sessions/*.session` files in the
/// shape Serato DJ Pro records: a `vrsn` header then one `oent` → `adat`
/// per deck load, whose fields are numeric-id TLVs.
enum SyntheticSeratoHistory {
    struct Entry {
        let path: String
        let startedAt: UInt32
        var played = true
    }

    static func historyDirectory(in seratoDirectory: URL) -> URL {
        seratoDirectory.appendingPathComponent("History", isDirectory: true)
    }

    static func write(_ entries: [Entry], session: String, seratoDirectory: URL) throws {
        let sessions = historyDirectory(in: seratoDirectory).appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let bytes = entries.reduce(SeratoTestEncoding.record("vrsn", utf16("1.0/Serato Scratch LIVE Review"))) { data, entry in
            let fields = field(1, bigEndian(UInt32(1)))
                + field(2, utf16(entry.path + "\0"))
                + field(28, bigEndian(entry.startedAt))
                + field(50, Data([entry.played ? 1 : 0]))
            return data + SeratoTestEncoding.record("oent", SeratoTestEncoding.record("adat", fields))
        }
        try bytes.write(to: sessions.appendingPathComponent("\(session).session"))
    }

    static func writeCorrupt(session: String, seratoDirectory: URL) throws {
        let sessions = historyDirectory(in: seratoDirectory).appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let truncated = SeratoTestEncoding.record("vrsn", utf16("1.0/Serato Scratch LIVE Review")) + Data("oent".utf8) + bigEndian(UInt32(64))
        try truncated.write(to: sessions.appendingPathComponent("\(session).session"))
    }

    private static func field(_ identifier: UInt32, _ payload: Data) -> Data {
        bigEndian(identifier) + bigEndian(UInt32(payload.count)) + payload
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { bytes in Data(bytes) }
    }

    private static func utf16(_ text: String) -> Data {
        Data(text.utf16.flatMap { unit in [UInt8(unit >> 8), UInt8(unit & 0xFF)] })
    }
}
