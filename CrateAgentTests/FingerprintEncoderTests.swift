@testable import CrateAgent
import XCTest

final class FingerprintEncoderTests: XCTestCase {
    func testRoundTripEncodesNonEmpty() {
        let hashes: [UInt32] = [0x0001, 0x00FF, 0xDEAD_BEEF]
        let bytes = FingerprintEncoder.serialize(hashes)
        XCTAssertEqual(bytes.count, hashes.count * 4)
        XCTAssertEqual(FingerprintEncoder.deserialize(bytes), hashes)
        XCTAssertFalse(FingerprintEncoder.base64(fromStoredBytes: bytes)?.isEmpty ?? true)
    }

    func testSerializeUsesLittleEndian() {
        // Pin the byte order so the on-disk format is documented:
        // 0x01020304 → 04 03 02 01.
        let bytes = FingerprintEncoder.serialize([0x0102_0304])
        XCTAssertEqual(Array(bytes), [0x04, 0x03, 0x02, 0x01])
    }

    func testEmptyBytesReturnNil() {
        XCTAssertNil(FingerprintEncoder.base64(fromStoredBytes: Data()))
    }
}
