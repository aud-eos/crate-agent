import Foundation

enum TestAudio {
    /// Ten seconds of a mono sine. 24-bit files carry `lowBits` below the
    /// 16-bit range, so their PCM differs from the 16-bit master, and from
    /// each other, while sounding the same.
    /// `title` adds a RIFF INFO tag chunk.
    static func wav(frequency: Double, bitsPerSample: Int = 16, lowBits: Int32 = 1, title: String? = nil) -> Data {
        let sampleRate = 44100
        let bytesPerSample = bitsPerSample / 8
        var samples = Data()
        for index in 0 ..< sampleRate * 10 {
            let value = Int32(sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)) * 20000)
            let encoded = bitsPerSample == 24 ? (value << 8) | lowBits : value
            samples += little(encoded).prefix(bytesPerSample)
        }
        return riff(samples: samples, sampleRate: sampleRate, bitsPerSample: bitsPerSample, title: title)
    }

    /// 16-bit mono at 11,025 Hz: one second of each tone in `frequencies`.
    /// Files that list the same first 120 tones share a 120 s fingerprint.
    static func tones(_ frequencies: [Double], title: String? = nil) -> Data {
        let sampleRate = 11025
        var samples = Data()
        for (second, frequency) in frequencies.enumerated() {
            for index in 0 ..< sampleRate {
                let time = Double(second * sampleRate + index) / Double(sampleRate)
                samples += little(Int16(sin(2 * Double.pi * frequency * time) * 12000))
            }
        }
        return riff(samples: samples, sampleRate: sampleRate, bitsPerSample: 16, title: title)
    }

    private static func riff(samples: Data, sampleRate: Int, bitsPerSample: Int, title: String?) -> Data {
        let bytesPerSample = bitsPerSample / 8
        var info = Data()
        if let title {
            var value = Data(title.utf8) + Data([0])
            if value.count.isMultiple(of: 2) == false {
                value += Data([0])
            }
            info = Data("LIST".utf8) + little(UInt32(12 + value.count)) + Data("INFOINAM".utf8) + little(UInt32(value.count)) + value
        }
        var bytes = Data("RIFF".utf8) + little(UInt32(36 + info.count + samples.count)) + Data("WAVEfmt ".utf8)
        bytes += little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1)) + little(UInt32(sampleRate))
        bytes += little(UInt32(sampleRate * bytesPerSample)) + little(UInt16(bytesPerSample)) + little(UInt16(bitsPerSample))
        return bytes + info + Data("data".utf8) + little(UInt32(samples.count)) + samples
    }

    private static func little(_ value: some FixedWidthInteger) -> Data {
        var encoded = value.littleEndian
        return withUnsafeBytes(of: &encoded) { buffer in Data(buffer) }
    }
}
