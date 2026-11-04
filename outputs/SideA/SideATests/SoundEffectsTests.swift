import XCTest
import AVFoundation
@testable import SideA

final class SoundEffectsTests: XCTestCase {
    private func format(channels: UInt32 = 1) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
    private func amplitude(_ preset: SoundPreset, hz: Double) -> Double {
        let dsp = SoundDSP(preset: preset); dsp.prepare(format())
        var samples = (0..<24_000).map { Float(0.2 * sin(2 * Double.pi * hz * Double($0) / 48_000)) }
        samples.withUnsafeMutableBytes { ptr in
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(ptr.count), mData: ptr.baseAddress))
            XCTAssertTrue(dsp.process(&buffer, frames: 24_000))
        }
        XCTAssertEqual(dsp.framesProcessed.load(ordering: .relaxed), 24_000)
        return sqrt(samples.suffix(12_000).reduce(0) { $0 + Double($1 * $1) } / 12_000)
    }
    func testPresetsChangeActualPCMAndKeepHeadroom() {
        XCTAssertGreaterThan(amplitude(.bass, hz: 63) / amplitude(.bass, hz: 4_000), 1.4)
        XCTAssertGreaterThan(amplitude(.vocal, hz: 4_000) / amplitude(.vocal, hz: 63), 1.4)
        XCTAssertLessThan(amplitude(.night, hz: 63) / amplitude(.night, hz: 1_000), 0.8)
        for preset in SoundPreset.allCases where preset != .original {
            XCTAssertLessThan(preset.preamp, 1)
            XCTAssertLessThan(amplitude(preset, hz: 1_000), 0.2)
        }
    }
    func testStereoChannelsStayIndependentAndUnsupportedFormatBypasses() {
        let dsp = SoundDSP(preset: .bass); dsp.prepare(format(channels: 2))
        var samples = [Float](repeating: 0, count: 4096)
        samples[0] = 0.5
        samples.withUnsafeMutableBytes { ptr in
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(ptr.count), mData: ptr.baseAddress))
            XCTAssertTrue(dsp.process(&buffer, frames: 2048))
        }
        for i in stride(from: 1, to: samples.count, by: 2) { XCTAssertEqual(samples[i], 0) }
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        var unsupported = format(); unsupported.mFormatFlags = kAudioFormatFlagIsSignedInteger
        dsp.prepare(unsupported)
        let before = samples
        samples.withUnsafeMutableBytes { ptr in
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(ptr.count), mData: ptr.baseAddress))
            XCTAssertFalse(dsp.process(&buffer, frames: 2048))
        }
        XCTAssertEqual(samples, before)
        XCTAssertEqual(dsp.formatStatus.load(ordering: .acquiring), -1)
    }
    func testOldBackupDecodesAndSoundPreferenceMergesIndependently() throws {
        let original = CloudPlayback()
        let data = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(CloudPlayback.self, from: data).soundPreset)
        var base = DeviceLibrarySnapshot(), local = DeviceLibrarySnapshot(), remote = DeviceLibrarySnapshot()
        base.playback.soundPreset = "original"; local = base; remote = base
        local.playback.soundPreset = "night"; remote.playback.losslessOnly = true
        let merged = DeviceLibrarySnapshot.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.playback.soundPreset, "night")
        XCTAssertTrue(merged.playback.losslessOnly)
        XCTAssertEqual(try JSONDecoder().decode(DeviceLibrarySnapshot.self, from: JSONEncoder().encode(merged)), merged)
    }

    @MainActor private func verifyPlaybackTap(_ url: URL) async throws {
        try await verifyPlaybackTap(asset: AVURLAsset(url: url))
    }
    @MainActor private func verifyPlaybackTap(asset: AVURLAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let item = AVPlayerItem(asset: asset), effect = try SoundTap(preset: .vocal)
        item.audioMix = effect.mix(track: track)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        defer { player.pause(); player.replaceCurrentItem(with: nil); try? AVAudioSession.sharedInstance().setActive(false) }
        player.play()
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline && effect.processor.framesProcessed.load(ordering: .relaxed) < 1_000 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(effect.processor.framesProcessed.load(ordering: .relaxed), 1_000, "Tap must process real decoded frames: \(asset.url.lastPathComponent); \(String(describing: item.error))")
        XCTAssertEqual(effect.processor.formatStatus.load(ordering: .acquiring), 1)
        await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600))
        player.play()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(player.currentTime().seconds, 4.2, "Playback must continue after seek")
        let replacement = try SoundTap(preset: .bass)
        item.audioMix = replacement.mix(track: track)
        await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
        player.play()
        let switchingDeadline = Date().addingTimeInterval(5)
        while Date() < switchingDeadline && replacement.processor.framesProcessed.load(ordering: .relaxed) < 1_000 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(replacement.processor.framesProcessed.load(ordering: .relaxed), 1_000, "Changing scene must install a live processor")
        item.audioMix = nil
        let before = player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(player.currentTime().seconds, before, "Returning to original must keep playback running")
    }
    @MainActor func testLocalPlaybackTapActuallyReceivesDecodedAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames: AVAudioFrameCount = 48_000 * 8
        let buffer = AVAudioPCMBuffer(pcmFormat: audio, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(0.1 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000)) } }
        let file = try AVAudioFile(forWriting: url, settings: audio.settings)
        try file.write(from: buffer)
        try await verifyPlaybackTap(url)
    }
    @MainActor func testKuwoResourceLoaderTapAndSeek() async throws {
        guard let value = ProcessInfo.processInfo.environment["SIDEA_SOUND_QA_KUWO"], let url = URL(string: value) else {
            throw XCTSkip("Opt-in public Kuwo CDN verification")
        }
        let loader = KuwoResourceLoader(url: url)
        defer { loader.invalidate() }
        try await verifyPlaybackTap(asset: loader.asset())
    }
    @MainActor func testHTTPProgressiveFLACAndMP3TapAndSeek() async throws {
        guard let base = ProcessInfo.processInfo.environment["SIDEA_SOUND_QA_BASE"], let url = URL(string: base) else {
            throw XCTSkip("Opt-in local synthetic HTTP fixture server")
        }
        for ext in ["flac", "mp3"] { try await verifyPlaybackTap(url.appendingPathComponent("tone." + ext)) }
    }
}
