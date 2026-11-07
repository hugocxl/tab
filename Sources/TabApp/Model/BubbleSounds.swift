import AppKit
import TabCore

/// Notification sounds synthesized on each play, after cuelume's bubble
/// family (MIT, see THIRD_PARTY_NOTICES.md): short sine tones that slide in
/// pitch, with soft filtered-noise pops. Every play varies a little in pitch
/// and level, as a struck object would.
enum BubbleSounds {
    @MainActor private static var playing: [NSSound] = []

    /// Plays `sound` without waiting for it to be rendered.
    @MainActor
    static func play(_ sound: NotificationSound) {
        Task.detached(priority: .userInitiated) {
            var random = SystemRandomNumberGenerator()
            let data = wav(render(sound, random: &random))
            await MainActor.run {
                playing.removeAll { !$0.isPlaying }
                guard let player = NSSound(data: data) else { return }
                playing.append(player)
                player.play()
            }
        }
    }

    @MainActor private static var lastAlert = Date.distantPast

    /// Plays `sound` for a status, unless one just played, so a burst of
    /// changes makes one sound.
    @MainActor
    static func alert(_ sound: NotificationSound) {
        guard -lastAlert.timeIntervalSinceNow > 0.4 else { return }
        lastAlert = Date()
        play(sound)
    }

    static let sampleRate = 48_000.0

    struct Layer {
        enum Source {
            case tone
            case lowpass(q: Double)
            case bandpass(q: Double)
        }

        var source: Source
        /// The tone's pitch, or the noise filter's frequency, in hertz.
        var from: Double
        var to: Double?
        var glide: Double = 0
        var attack: Double
        /// Seconds to fall 60 dB.
        var decay: Double
        var peak: Double
    }

    struct Recipe {
        var gain: Double
        var pitchVariation: Double
        var levelVariation: Double
        var layers: [Layer]
    }

    private static func tone(_ from: Double, _ to: Double?, glide: Double, attack: Double, decay: Double, peak: Double) -> Layer {
        Layer(source: .tone, from: from, to: to, glide: glide, attack: attack, decay: decay, peak: peak)
    }

    private static func pop(_ frequency: Double, peak: Double) -> Layer {
        Layer(source: .lowpass(q: 0.9), from: frequency, attack: 0.001, decay: 0.0032, peak: peak)
    }

    /// The layers each sound plays at normal emphasis.
    static func recipe(_ sound: NotificationSound) -> Recipe {
        let lively = (0.06, 0.1)
        let steady = (0.0, 0.08)
        switch sound {
        case .tap:
            return Recipe(gain: 0.411, pitchVariation: 0.08, levelVariation: 0.1, layers: [
                tone(480, 300, glide: 0.018, attack: 0.001, decay: 0.0216, peak: 0.06),
                tone(600, 900, glide: 0.04, attack: 0.012, decay: 0.0489, peak: 0.014),
                tone(960, 600, glide: 0.018, attack: 0.001, decay: 0.0165, peak: 0.015),
            ])
        case .select:
            return Recipe(gain: 0.214, pitchVariation: 0.03, levelVariation: 0.1, layers: [
                tone(700, 1050, glide: 0.012, attack: 0.001, decay: 0.0278, peak: 0.05),
                pop(3000, peak: 0.075),
            ])
        case .toggle:
            return Recipe(gain: 0.175, pitchVariation: 0.04, levelVariation: 0.1, layers: [
                Layer(source: .lowpass(q: 0.9), from: 900, attack: 0.001, decay: 0.00779, peak: 0.12),
                tone(330, 660, glide: 0.06, attack: 0.003, decay: 0.0791, peak: 0.045),
                tone(990, 1485, glide: 0.02, attack: 0.03, decay: 0.045, peak: 0.01),
            ])
        case .open:
            return Recipe(gain: 0.221, pitchVariation: lively.0, levelVariation: lively.1, layers: [
                tone(220, 520, glide: 0.14, attack: 0.1, decay: 0.0692, peak: 0.04),
                tone(330, 780, glide: 0.14, attack: 0.1, decay: 0.0866, peak: 0.012),
            ])
        case .close:
            return Recipe(gain: 0.357, pitchVariation: lively.0, levelVariation: lively.1, layers: [
                tone(700, 220, glide: 0.07, attack: 0.004, decay: 0.0905, peak: 0.045),
                pop(1200, peak: 0.06),
            ])
        case .navigate:
            return Recipe(gain: 0.554, pitchVariation: lively.0, levelVariation: lively.1, layers: [
                tone(300, 1500, glide: 0.09, attack: 0.01, decay: 0.0943, peak: 0.035),
                Layer(source: .bandpass(q: 1), from: 1500, to: 3000, glide: 0.09, attack: 0.02, decay: 0.0778, peak: 0.05),
            ])
        case .success:
            return Recipe(gain: 0.52, pitchVariation: steady.0, levelVariation: steady.1, layers: [
                tone(523.25, 783.99, glide: 0.08, attack: 0.003, decay: 0.323, peak: 0.04),
                tone(1046.5, 1567.98, glide: 0.08, attack: 0.003, decay: 0.12, peak: 0.01),
            ])
        case .error:
            return Recipe(gain: 0.387, pitchVariation: steady.0, levelVariation: steady.1, layers: [
                tone(349.23, 261.63, glide: 0.14, attack: 0.004, decay: 0.226, peak: 0.045),
                pop(900, peak: 0.12),
            ])
        case .warning:
            return Recipe(gain: 0.436, pitchVariation: steady.0, levelVariation: steady.1, layers: [
                tone(500, 440, glide: 0.05, attack: 0.002, decay: 0.181, peak: 0.045),
                pop(1800, peak: 0.09),
            ])
        case .ready:
            return Recipe(gain: 0.532, pitchVariation: steady.0, levelVariation: steady.1, layers: [
                tone(1400, 700, glide: 0.012, attack: 0.001, decay: 0.0242, peak: 0.03),
                tone(392, 587.33, glide: 0.06, attack: 0.012, decay: 0.288, peak: 0.04),
                pop(2000, peak: 0.03),
            ])
        case .attention:
            return Recipe(gain: 0.666, pitchVariation: steady.0, levelVariation: steady.1, layers: [
                tone(659.25, 880, glide: 0.14, attack: 0.003, decay: 0.295, peak: 0.035),
                pop(2200, peak: 0.12),
            ])
        }
    }

    /// The output's level before it is softly clipped.
    private static let outputGain = 5.8

    /// One play of `sound` as mono samples.
    static func render<R: RandomNumberGenerator>(_ sound: NotificationSound, random: inout R) -> [Float] {
        let recipe = recipe(sound)
        func nudge(_ amount: Double) -> Double { 1 + Double.random(in: -1..<1, using: &random) * amount }
        let pitch = nudge(recipe.pitchVariation)
        let force = nudge(recipe.levelVariation)
        let length = recipe.layers.map { $0.attack + $0.decay * 1.1 + 0.05 }.max() ?? 0
        var mix = [Double](repeating: 0, count: Int(length * sampleRate))
        for var layer in recipe.layers {
            layer.peak *= force
            layer.decay *= nudge(0.1)
            switch layer.source {
            case .tone:
                let scale = pitch * nudge(0.005)
                layer.from *= scale
                layer.to = layer.to.map { $0 * scale }
            case .lowpass, .bandpass:
                layer.from *= pitch * force
                layer.to = layer.to.map { $0 * pitch * force }
            }
            add(layer, to: &mix, random: &random)
        }
        return mix.map { Float(softClip($0 * recipe.gain * outputGain)) }
    }

    private static func add<R: RandomNumberGenerator>(_ layer: Layer, to mix: inout [Double], random: inout R) {
        let count = min(Int((layer.attack + layer.decay + 0.05) * sampleRate), mix.count)
        let fall = layer.decay / (3 * log(10))
        var phase = 0.0
        var filter = Biquad()
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let envelope = time < layer.attack ? layer.peak * time / layer.attack : layer.peak * exp(-(time - layer.attack) / fall)
            var frequency = layer.from
            if let to = layer.to, layer.glide > 0 { frequency = layer.from * pow(to / layer.from, min(time / layer.glide, 1)) }
            let sample: Double
            switch layer.source {
            case .tone:
                phase += 2 * .pi * frequency / sampleRate
                sample = sin(phase)
            case .lowpass(let q):
                if index == 0 || layer.to != nil { filter.lowpass(frequency, q: q) }
                sample = filter.process(Double.random(in: -1..<1, using: &random))
            case .bandpass(let q):
                if index == 0 || layer.to != nil { filter.bandpass(frequency, q: q) }
                sample = filter.process(Double.random(in: -1..<1, using: &random))
            }
            mix[index] += sample * envelope
        }
    }

    /// Linear up to the knee, then bending toward full scale.
    static func softClip(_ value: Double) -> Double {
        let knee = 0.7
        let magnitude = abs(value)
        guard magnitude > knee else { return value }
        return (value < 0 ? -1 : 1) * (knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee)))
    }

    /// A Web Audio style biquad: lowpass Q in decibels, bandpass Q linear.
    private struct Biquad {
        private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func lowpass(_ frequency: Double, q: Double) {
            let w0 = 2 * .pi * min(frequency, sampleRate / 2 - 1) / sampleRate
            let alpha = sin(w0) / (2 * pow(10, q / 20))
            let a0 = 1 + alpha
            b0 = (1 - cos(w0)) / 2 / a0
            b1 = (1 - cos(w0)) / a0
            b2 = b0
            a1 = -2 * cos(w0) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func bandpass(_ frequency: Double, q: Double) {
            let w0 = 2 * .pi * min(frequency, sampleRate / 2 - 1) / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b1 = 0
            b2 = -alpha / a0
            a1 = -2 * cos(w0) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    /// `samples` as a 16-bit mono WAV file.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in samples { append(Int16(max(min(sample, 1), -1) * Float(Int16.max))) }
        return data
    }
}
