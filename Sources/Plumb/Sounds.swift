import AppKit

/// Short synthesized sounds, rendered once into WAV data. Device-like and
/// independent of the system sound set; no audio files ship with the app.
enum Synth {
    static let names = ["plumb chime", "plumb bell", "plumb blip"]
    private static let rate = 44_100.0
    @MainActor private static var cache: [String: Data] = [:]

    @MainActor
    static func sound(named name: String) -> NSSound? {
        if cache[name] == nil, let samples = render(name) { cache[name] = wav(samples) }
        return cache[name].flatMap { NSSound(data: $0) }
    }

    static func render(_ name: String) -> [Float]? {
        switch name {
        case "plumb chime":
            // Two rising sine notes with soft decay.
            return mix(tone(880, length: 0.9, decay: 5, partials: [(1, 1), (2, 0.25)]),
                       tone(1318.5, length: 1.1, decay: 4, partials: [(1, 1), (2, 0.2)]), offset: 0.16)
        case "plumb bell":
            // Inharmonic partials, like a small struck plate.
            return tone(660, length: 1.8, decay: 2.5, partials: [(1, 1), (2.76, 0.45), (5.4, 0.25), (8.93, 0.1)])
        case "plumb blip":
            return mix(square(1200, length: 0.06), square(1600, length: 0.06), offset: 0.09)
        default:
            return nil
        }
    }

    private static func tone(_ freq: Double, length: Double, decay: Double, partials: [(Double, Double)]) -> [Float] {
        let n = Int(length * rate)
        let norm = partials.reduce(0) { $0 + $1.1 }
        return (0..<n).map { i in
            let t = Double(i) / rate
            let attack = min(1, t / 0.004)
            let env = attack * exp(-decay * t)
            let v = partials.reduce(0.0) { $0 + $1.1 * sin(2 * .pi * freq * $1.0 * t) } / norm
            return Float(v * env * 0.6)
        }
    }

    private static func square(_ freq: Double, length: Double) -> [Float] {
        let n = Int(length * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.003) * min(1, (length - t) / 0.01)
            // Band-limited-ish square from three odd harmonics.
            let v = sin(2 * .pi * freq * t) + sin(6 * .pi * freq * t) / 3 + sin(10 * .pi * freq * t) / 5
            return Float(v * env * 0.25)
        }
    }

    private static func mix(_ a: [Float], _ b: [Float], offset: Double) -> [Float] {
        let shift = Int(offset * rate)
        var out = a + Array(repeating: 0, count: max(0, shift + b.count - a.count))
        for (i, v) in b.enumerated() { out[shift + i] += v }
        return out
    }

    /// 16-bit mono PCM in a RIFF/WAVE container.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for s in samples { append(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}
