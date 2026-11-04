import AVFoundation
import MediaToolbox
import Synchronization

enum SoundPreset: String, CaseIterable, Identifiable, Sendable {
    case original, surround, hall, vocal, studio, bass, soft
    var id: String { rawValue }
    static func restored(_ value: String?) -> Self {
        switch value {
        case "commute": return .vocal
        case "night": return .soft
        default: return Self(rawValue: value ?? "") ?? .original
        }
    }
    var title: String {
        switch self {
        case .original: return "原声"
        case .surround: return "立体环绕"
        case .hall: return "音乐厅"
        case .vocal: return "清澈人声"
        case .studio: return "录音棚"
        case .bass: return "低音增强"
        case .soft: return "柔和聆听"
        }
    }
    var detail: String {
        switch self {
        case .original: return "保留录音本来的声音"
        case .surround: return "立体声扩展与侧向早反射"
        case .hall: return "柔和、宽阔的厅堂混响"
        case .vocal: return "减轻浑浊，突出歌声细节"
        case .studio: return "短房间反射，紧凑自然"
        case .bass: return "低频更饱满，保留人声"
        case .soft: return "柔和高频，轻松聆听"
        }
    }
    var gains: [Double] {
        switch self {
        case .original, .surround, .studio: return [0,0,0,0,0]
        case .hall: return [0,-0.5,0,0,-1]
        case .vocal: return [-2,-1,2,3,0]
        case .bass: return [4,2,0,-1,-1]
        case .soft: return [1,0,0,-1,-3]
        }
    }
    var preamp: Double {
        if self == .original { return 1 }
        let headroom = self == .surround || self == .hall ? 4.0 : self == .studio ? 3.0 : 2.0
        return pow(10, -((gains.max() ?? 0) + headroom) / 20)
    }
    var spatial: Bool { self == .surround || self == .hall || self == .studio }
}

private struct SoundBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0
    static func peak(hz: Double, gain: Double, rate: Double) -> Self {
        guard hz < rate * 0.45, gain != 0 else { return Self() }
        let a = pow(10, gain / 40), w = 2 * Double.pi * hz / rate
        let alpha = sin(w) / (2 * 0.8), denominator = 1 + alpha / a
        return Self(b0: (1 + alpha * a) / denominator, b1: -2 * cos(w) / denominator,
                    b2: (1 - alpha * a) / denominator, a1: -2 * cos(w) / denominator,
                    a2: (1 - alpha / a) / denominator)
    }
    mutating func sample(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// All delay storage is created in prepare, never in the realtime process callback.
private final class SoundDelay {
    let memory: UnsafeMutablePointer<Double>
    let length: Int
    var position = 0, damped = 0.0
    init(seconds: Double, rate: Double) {
        length = max(1, Int((seconds * rate).rounded()))
        memory = .allocate(capacity: length); memory.initialize(repeating: 0, count: length)
    }
    deinit { memory.deinitialize(count: length); memory.deallocate() }
    func clear() { memory.update(repeating: 0, count: length); position = 0; damped = 0 }
    func delay(_ input: Double) -> Double {
        let value = memory[position]; memory[position] = input
        position += 1; if position == length { position = 0 }
        return value
    }
    func comb(_ input: Double, feedback: Double, damping: Double) -> Double {
        let value = memory[position]
        damped = value * (1 - damping) + damped * damping
        memory[position] = input * (1 - feedback) + damped * feedback
        position += 1; if position == length { position = 0 }
        return value
    }
    func allpass(_ input: Double) -> Double {
        let delayed = memory[position], value = delayed - input * 0.5
        memory[position] = input + value * 0.5
        position += 1; if position == length { position = 0 }
        return value
    }
}

// Original, modest-wet room model: four damped combs and two allpass diffusers.
// Stable feedback and normalized comb input avoid a buildup on sustained notes.
private final class SoundRoom {
    private let combs: [SoundDelay], diffusers: [SoundDelay]
    private let feedback: Double, damping: Double
    init(rate: Double, hall: Bool, right: Bool) {
        let times = hall ? [0.0297,0.0371,0.0411,0.0437] : [0.0091,0.0137,0.0173,0.0211]
        combs = times.map { SoundDelay(seconds: $0 + (right ? 0.0011 : 0), rate: rate) }
        diffusers = [SoundDelay(seconds: hall ? 0.0053 : 0.0027, rate: rate),
                     SoundDelay(seconds: hall ? 0.0017 : 0.0011, rate: rate)]
        feedback = hall ? 0.78 : 0.38
        // A fixed low-pass corner, independent of the asset sample rate.
        damping = exp(-2 * Double.pi * (hall ? 5_500 : 7_000) / rate)
    }
    func clear() { for line in combs { line.clear() }; for line in diffusers { line.clear() } }
    func sample(_ input: Double) -> Double {
        var value = 0.0
        for i in 0..<4 { value += combs[i].comb(input, feedback: feedback, damping: damping) * 0.25 }
        for i in 0..<2 { value = diffusers[i].allpass(value) }
        return value
    }
}

// prepare/process/unprepare are serialized by MediaToolbox; the UI reads atomics only.
// Pointer-backed filter/scratch arrays avoid Swift Array COW inside the callback.
final class SoundDSP {
    private let preset: SoundPreset, gains: [Double]
    private let frequencies = [63.0, 250, 1_000, 4_000, 16_000]
    private let gain: Double
    private let bands = UnsafeMutablePointer<SoundBiquad>.allocate(capacity: 40)
    private let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 8)
    private let strides = UnsafeMutablePointer<Int>.allocate(capacity: 8)
    private let values = UnsafeMutablePointer<Double>.allocate(capacity: 8)
    private let dry = UnsafeMutablePointer<Double>.allocate(capacity: 8)
    private var sideDelay: SoundDelay?, leftRoom: SoundRoom?, rightRoom: SoundRoom?
    private var channels = 0, rampFrames = 480, rampPosition = 0
    private var supported = false
    let framesProcessed = Atomic<Int>(0)
    let formatStatus = Atomic<Int>(0) // 0 waiting; 1 supported; -1 format; -2 stereo required
    init(preset: SoundPreset) {
        self.preset = preset; gains = preset.gains; gain = preset.preamp
        bands.initialize(repeating: SoundBiquad(), count: 40)
        pointers.initialize(repeating: nil, count: 8); strides.initialize(repeating: 0, count: 8)
        values.initialize(repeating: 0, count: 8); dry.initialize(repeating: 0, count: 8)
    }
    deinit {
        bands.deinitialize(count: 40); bands.deallocate()
        pointers.deinitialize(count: 8); pointers.deallocate(); strides.deinitialize(count: 8); strides.deallocate()
        values.deinitialize(count: 8); values.deallocate(); dry.deinitialize(count: 8); dry.deallocate()
    }
    func prepare(_ format: AudioStreamBasicDescription) {
        channels = Int(format.mChannelsPerFrame)
        supported = format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && (1...8).contains(channels) && format.mSampleRate.isFinite
            && (8_000...192_000).contains(format.mSampleRate)
        if preset.spatial && channels > 2 { supported = false }
        let stereoMissing = preset == .surround && channels != 2
        if stereoMissing { supported = false }
        sideDelay = nil; leftRoom = nil; rightRoom = nil
        if supported {
            rampFrames = max(1, Int(format.mSampleRate * 0.010))
            for c in 0..<channels {
                for b in 0..<5 { bands[c * 5 + b] = .peak(hz: frequencies[b], gain: gains[b], rate: format.mSampleRate) }
            }
            if preset == .surround { sideDelay = SoundDelay(seconds: 0.008, rate: format.mSampleRate) }
            if preset == .hall || preset == .studio {
                leftRoom = SoundRoom(rate: format.mSampleRate, hall: preset == .hall, right: false)
                if channels == 2 { rightRoom = SoundRoom(rate: format.mSampleRate, hall: preset == .hall, right: true) }
            }
        }
        reset(); framesProcessed.store(0, ordering: .relaxed)
        formatStatus.store(supported ? 1 : stereoMissing ? -2 : -1, ordering: .releasing)
    }
    func reset() {
        for i in 0..<40 { bands[i].z1 = 0; bands[i].z2 = 0 }
        sideDelay?.clear(); leftRoom?.clear(); rightRoom?.clear(); rampPosition = 0
    }
    @discardableResult func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Bool {
        guard supported, frames > 0, frames <= Int.max / 32 else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var totalChannels = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            guard count > 0, totalChannels + count <= channels, let data = buffer.mData,
                  Int(buffer.mDataByteSize) >= frames * count * MemoryLayout<Float>.size else {
                formatStatus.store(-1, ordering: .releasing); return false
            }
            for c in 0..<count {
                pointers[totalChannels + c] = data.assumingMemoryBound(to: Float.self).advanced(by: c)
                strides[totalChannels + c] = count
            }
            totalChannels += count
        }
        guard totalChannels == channels else { formatStatus.store(-1, ordering: .releasing); return false }
        if preset == .original { framesProcessed.wrappingAdd(frames, ordering: .relaxed); return true }
        for frame in 0..<frames {
            for c in 0..<channels {
                let raw = Double(pointers[c]![frame * strides[c]])
                dry[c] = raw.isFinite ? min(1, max(-1, raw)) : 0
                var value = dry[c] * gain
                for b in 0..<5 { value = bands[c * 5 + b].sample(value) }
                values[c] = value
            }
            if let sideDelay {
                let mid = (values[0] + values[1]) * 0.5, side = (values[0] - values[1]) * 0.5
                let expanded = side * 1.18 + sideDelay.delay(side) * 0.10
                values[0] = mid + expanded; values[1] = mid - expanded
            } else if let leftRoom {
                let left = values[0], right = channels == 2 ? values[1] : left
                let wetL = leftRoom.sample(left * 0.82 + right * 0.18)
                let wetR = rightRoom?.sample(right * 0.82 + left * 0.18) ?? wetL
                let mix = preset == .hall ? 0.24 : 0.12
                values[0] = left * (1 - mix * 0.45) + wetL * mix
                if channels == 2 { values[1] = right * (1 - mix * 0.45) + wetR * mix }
            }
            // Crossfade from dry over 10ms on attach/reset, avoiding abrupt effect engagement.
            rampPosition = min(rampFrames, rampPosition + 1)
            let blend = Double(rampPosition) / Double(rampFrames)
            for c in 0..<channels {
                let value = dry[c] + (values[c] - dry[c]) * blend
                pointers[c]![frame * strides[c]] = value.isFinite ? Float(min(1, max(-1, value))) : 0
            }
        }
        framesProcessed.wrappingAdd(frames, ordering: .relaxed)
        return true
    }
}

final class SoundTap {
    let processor: SoundDSP
    let tap: MTAudioProcessingTap
    init(preset: SoundPreset) throws {
        processor = SoundDSP(preset: preset)
        let retained = Unmanaged.passRetained(processor)
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<SoundDSP>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<SoundDSP>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            }, unprepare: { _ in },
            process: { tap, requested, _, buffers, count, flags in
                let result = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, count)
                guard result == noErr, count.pointee > 0 else { return }
                let dsp = Unmanaged<SoundDSP>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                if flags.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0 { dsp.reset() }
                dsp.process(buffers, frames: Int(count.pointee))
            })
        var value: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &value)
        guard status == noErr, let value else {
            retained.release()
            throw NSError(domain: "SideA.SoundTap", code: Int(status))
        }
        tap = value
    }
    func mix(track: AVAssetTrack) -> AVAudioMix {
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [input]
        return mix
    }
}
