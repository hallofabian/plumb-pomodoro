import AVFoundation
import Observation

/// A background sound: generated on this Mac (noise, binaural beats), or a
/// stream URL the user supplies. No third-party audio ships with the app.
struct AmbientSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case off
        case noise(NoiseColor)
        /// Carrier tone in Hz; the right ear hears carrier + beat.
        case binaural(carrier: Double, beat: Double)
        case custom
    }

    let id: String
    let name: String
    let detail: String
    let kind: Kind

    static let off = AmbientSource(id: "off", name: "off", detail: "", kind: .off)

    static let catalog: [AmbientSource] = [
        off,
        AmbientSource(id: "noise.brown", name: "brown noise", detail: "deep, soft rumble", kind: .noise(.brown)),
        AmbientSource(id: "noise.pink", name: "pink noise", detail: "balanced, like steady rain", kind: .noise(.pink)),
        AmbientSource(id: "noise.white", name: "white noise", detail: "bright hiss", kind: .noise(.white)),
        AmbientSource(id: "binaural.alpha", name: "binaural · alpha 10 Hz", detail: "calm focus · use headphones",
                      kind: .binaural(carrier: 200, beat: 10)),
        AmbientSource(id: "binaural.beta", name: "binaural · beta 16 Hz", detail: "active concentration · use headphones",
                      kind: .binaural(carrier: 220, beat: 16)),
        AmbientSource(id: "binaural.gamma", name: "binaural · gamma 40 Hz", detail: "high alertness · use headphones",
                      kind: .binaural(carrier: 180, beat: 40)),
        AmbientSource(id: "custom", name: "custom stream", detail: "an MP3/AAC stream URL you have the rights to use",
                      kind: .custom),
    ]

    static func find(_ id: String) -> AmbientSource { catalog.first { $0.id == id } ?? off }

    var isGenerated: Bool {
        switch kind {
        case .noise, .binaural: true
        case .off, .custom: false
        }
    }
}

enum NoiseColor: Hashable { case white, pink, brown }

/// Sample-by-sample signal for one source; pure, so tests can inspect it.
struct Signal {
    let kind: AmbientSource.Kind
    let sampleRate: Double
    private var pink = [Float](repeating: 0, count: 7)
    private var brown: Float = 0
    private var phaseLeft = 0.0
    private var phaseRight = 0.0
    private var random = SplitMix64(seed: 0xF0C5)

    /// Level of the pink-noise bed under binaural tones.
    var bedLevel: Float

    init(kind: AmbientSource.Kind, sampleRate: Double = 44_100, bedLevel: Float = 0.35) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.bedLevel = bedLevel
    }

    /// Next stereo frame in −1…1.
    mutating func next() -> (left: Float, right: Float) {
        switch kind {
        case .off, .custom:
            return (0, 0)
        case .noise(let color):
            let v = noise(color)
            return (v, v)
        case .binaural(let carrier, let beat):
            phaseLeft = (phaseLeft + carrier / sampleRate).truncatingRemainder(dividingBy: 1)
            phaseRight = (phaseRight + (carrier + beat) / sampleRate).truncatingRemainder(dividingBy: 1)
            // Soft tones over a quiet pink-noise bed, which makes the beat easier to listen to.
            let bed = bedLevel > 0 ? noise(.pink) * bedLevel : 0
            return (Float(sin(2 * .pi * phaseLeft)) * 0.22 + bed, Float(sin(2 * .pi * phaseRight)) * 0.22 + bed)
        }
    }

    private mutating func noise(_ color: NoiseColor) -> Float {
        let white = Float(Double(random.next() >> 11) / Double(1 << 53)) * 2 - 1
        switch color {
        case .white:
            return white * 0.25
        case .pink:
            // Paul Kellet's refined pink filter.
            pink[0] = 0.99886 * pink[0] + white * 0.0555179
            pink[1] = 0.99332 * pink[1] + white * 0.0750759
            pink[2] = 0.96900 * pink[2] + white * 0.1538520
            pink[3] = 0.86650 * pink[3] + white * 0.3104856
            pink[4] = 0.55000 * pink[4] + white * 0.5329522
            pink[5] = -0.7616 * pink[5] - white * 0.0168980
            let v = (pink[0] + pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + white * 0.5362) * 0.06
            pink[6] = white * 0.115926
            return v
        case .brown:
            brown = (brown + 0.02 * white) / 1.02
            return brown * 2.5
        }
    }
}

/// Plays the selected background sound while the timer wants it.
@MainActor
@Observable
final class AmbientPlayer {
    enum State: Equatable { case stopped, loading, playing, failed(String) }

    private(set) var state = State.stopped
    /// Track title from a custom stream's metadata, when it sends one.
    private(set) var nowPlaying: String?

    @ObservationIgnored private var current: (id: String, url: String?)?
    @ObservationIgnored private let generator = SoundGenerator()
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private let metadata = MetadataReader()

    init() {
        metadata.onTitle = { [weak self] title in self?.nowPlaying = title }
    }

    /// Brings playback in line with what should be heard right now.
    func update(play shouldPlay: Bool, sourceID: String, customURL: String?, volume: Double) {
        let source = AmbientSource.find(sourceID)
        let customKey = source.kind == .custom ? customURL : nil
        generator.volume = Float(volume)
        player?.volume = Float(volume)

        guard shouldPlay, source.kind != .off else {
            stop()
            return
        }
        if let current, current.id == source.id, current.url == customKey, state != .stopped { return }
        stop()
        current = (source.id, customKey)
        if source.isGenerated {
            do {
                try generator.start(source.kind)
                state = .playing
            } catch {
                state = .failed("Audio output unavailable.")
            }
        } else {
            guard let text = customURL, let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
                  ["http", "https"].contains(url.scheme?.lowercased()) else {
                state = .failed("Enter a stream URL starting with https://")
                return
            }
            playStream(url, volume: volume)
        }
    }

    func stop() {
        generator.stop()
        player?.pause()
        player = nil
        statusObservation = nil
        nowPlaying = nil
        current = nil
        state = .stopped
    }

    /// A fresh item each time, so resuming joins a live stream instead of
    /// replaying the buffer from when it was paused.
    private func playStream(_ url: URL, volume: Double) {
        let player = AVPlayer()
        player.volume = Float(volume)
        self.player = player
        state = .loading
        let item = AVPlayerItem(url: url)
        metadata.attach(to: item)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                switch status {
                case .readyToPlay: self?.state = .playing
                case .failed: self?.state = .failed("The stream could not be played.")
                default: break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }
}

/// Reads ICY "StreamTitle" and other title metadata from a live stream.
final class MetadataReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: ((String?) -> Void)?

    /// Streams send anything from "Artist - Title" to their own name or an
    /// internal id; only the first is worth showing.
    static func trackTitle(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.contains(" - ") || text.contains(" – ") else { return nil }
        return text
    }

    func attach(to item: AVPlayerItem) {
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        let items = groups.flatMap(\.items)
        let title = items.first { $0.commonKey == .commonKeyTitle || $0.identifier?.rawValue.contains("StreamTitle") == true }
        let callback = onTitle
        Task {
            let text = try? await title?.load(.stringValue)
            let cleaned = MetadataReader.trackTitle(text)
            await MainActor.run { callback?(cleaned) }
        }
    }
}

/// Renders a `Signal` in real time through AVAudioEngine, in stereo.
final class SoundGenerator: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var fadeTimer: Timer?
    var volume: Float = 0.5 {
        didSet { if source != nil, fadeTimer == nil { engine.mainMixerNode.outputVolume = volume } }
    }

    func start(_ kind: AmbientSource.Kind) throws {
        stop()
        let rate = 44_100.0
        var signal = Signal(kind: kind, sampleRate: rate)
        let node = AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            for frame in 0..<Int(frameCount) {
                let sample = signal.next()
                left?[frame] = sample.left
                right?[frame] = sample.right
            }
            return noErr
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        try engine.start()
        source = node
        fade(to: volume)
    }

    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let source else { return }
        engine.stop()
        engine.detach(source)
        self.source = nil
    }

    /// Ramps the volume up over ~1.5 s so the sound does not start abruptly.
    private func fade(to target: Float) {
        fadeTimer?.invalidate()
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            let t = min(1, Float(step) / 30)
            self.engine.mainMixerNode.outputVolume = self.volume * t * t
            if t >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
    }
}
