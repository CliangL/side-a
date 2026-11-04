import AVFoundation
import MediaToolbox
import Synchronization
import SwiftUI

enum SoundPreset: String, CaseIterable, Identifiable, Sendable {
    case original, vocal, bass, soft, commute, night
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "原声"
        case .vocal: return "人声"
        case .bass: return "低音"
        case .soft: return "舒缓"
        case .commute: return "通勤"
        case .night: return "夜间"
        }
    }
    var detail: String {
        switch self {
        case .original: return "保留录音本来的声音"
        case .vocal: return "突出人声与细节"
        case .bass: return "增强低频的厚度"
        case .soft: return "柔和高频，轻松聆听"
        case .commute: return "突出中频，让旋律更清晰"
        case .night: return "收敛低频与高频，柔和聆听"
        }
    }
    // Shared scene targets with Android. Engines have different band responses.
    var gains: [Double] {
        switch self {
        case .original: return [0,0,0,0,0]
        case .vocal: return [-2,-1,2,3,0]
        case .bass: return [4,2,0,-1,-1]
        case .soft: return [1,0,0,-1,-3]
        case .commute: return [-2,0,2,2,0]
        case .night: return [-4,-2,0,-1,-4]
        }
    }
    var preamp: Double { self == .original ? 1 : pow(10, -((gains.max() ?? 0) + 2) / 20) }
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

// A tap owns one processor. Its buffers are allocated before the audio callback.
// prepare/process/unprepare are serialized by MediaToolbox; the UI only reads atomics.
final class SoundDSP {
    private let gains: [Double]
    private let frequencies = [63.0, 250, 1_000, 4_000, 16_000]
    private let gain: Double
    private var bands = [SoundBiquad](repeating: SoundBiquad(), count: 40)
    private var channels = 0
    private var supported = false
    let framesProcessed = Atomic<Int>(0)
    let formatStatus = Atomic<Int>(0) // 0 waiting; 1 supported; -1 unavailable
    init(preset: SoundPreset) { gains = preset.gains; gain = preset.preamp }

    func prepare(_ format: AudioStreamBasicDescription) {
        channels = Int(format.mChannelsPerFrame)
        supported = format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && (1...8).contains(channels) && format.mSampleRate.isFinite && format.mSampleRate >= 8_000
        if supported {
            for c in 0..<channels {
                for b in 0..<5 {
                    bands[c * 5 + b] = .peak(hz: frequencies[b], gain: gains[b], rate: format.mSampleRate)
                }
            }
        }
        framesProcessed.store(0, ordering: .relaxed)
        formatStatus.store(supported ? 1 : -1, ordering: .releasing)
    }
    func reset() {
        for i in 0..<40 { bands[i].z1 = 0; bands[i].z2 = 0 }
    }
    @discardableResult func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Bool {
        guard supported, frames > 0 else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var totalChannels = 0
        for b in buffers {
            let count = Int(b.mNumberChannels)
            guard count > 0, count <= channels, b.mData != nil,
                  Int(b.mDataByteSize) >= frames * count * MemoryLayout<Float>.size else {
                formatStatus.store(-1, ordering: .releasing); return false
            }
            totalChannels += count
        }
        guard totalChannels == channels else { formatStatus.store(-1, ordering: .releasing); return false }
        var offset = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<count {
                    let index = frame * count + channel, band = (offset + channel) * 5
                    var value = Double(samples[index]) * gain
                    if !value.isFinite { value = 0 }
                    for b in 0..<5 { value = bands[band + b].sample(value) }
                    // Headroom is applied before EQ. This final bound also protects corrupt PCM.
                    samples[index] = value.isFinite ? Float(min(1, max(-1, value))) : 0
                }
            }
            offset += count
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

struct SoundEffectsView: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(SoundPreset.allCases) { preset in
                        Button { player.soundPreset = preset } label: {
                            HStack(spacing: 16) {
                                Image(systemName: preset == .original ? "waveform" : "slider.horizontal.3")
                                    .font(.title3).frame(width: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(preset.title).font(.headline)
                                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if player.soundPreset == preset { Image(systemName: "checkmark.circle.fill") }
                            }.padding(17).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                                .glassPlate(22)
                        }.buttonStyle(.plain).accessibilityIdentifier("sound." + preset.rawValue)
                            .accessibilityAddTraits(player.soundPreset == preset ? .isSelected : [])
                    }
                    Text(player.soundStatus).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        .accessibilityIdentifier("sound.status")
                }.padding(20)
            }.background { Paper() }.navigationTitle("音效").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDragIndicator(.visible)
    }
}
