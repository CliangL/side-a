import XCTest
import AVFoundation
@testable import SideA

final class SoundEffectsTests: XCTestCase {
    private func format(channels: UInt32 = 1, rate: Double = 48_000) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
    private func render(_ preset: SoundPreset, _ input: [Float], channels: Int = 2, rate: Double = 48_000, block: Int = 257) -> [Float] {
        let dsp = SoundDSP(preset: preset); dsp.prepare(format(channels: UInt32(channels), rate: rate))
        var output = input
        output.withUnsafeMutableBufferPointer { ptr in
            for start in stride(from: 0, to: input.count / channels, by: block) {
                let count = min(block, input.count / channels - start)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * channels * 4), mData: ptr.baseAddress!.advanced(by: start * channels)))
                XCTAssertTrue(dsp.process(&list, frames: count))
            }
        }
        return output
    }
    private func amplitude(_ preset: SoundPreset, hz: Double) -> Double {
        let input = (0..<24_000).flatMap { i -> [Float] in let value = Float(0.2 * sin(2 * Double.pi * hz * Double(i) / 48_000)); return [value,value] }
        let output = render(preset, input)
        return sqrt(output.suffix(24_000).reduce(0) { $0 + Double($1 * $1) } / 24_000)
    }
    func testPresetsChangeActualPCMAndKeepHeadroom() {
        XCTAssertGreaterThan(amplitude(.bass, hz: 63) / amplitude(.bass, hz: 4_000), 1.4)
        XCTAssertGreaterThan(amplitude(.vocal, hz: 4_000) / amplitude(.vocal, hz: 63), 1.4)
        XCTAssertLessThan(amplitude(.soft, hz: 16_000) / amplitude(.soft, hz: 1_000), 0.85)
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
    func testCanonicalPresetsRestorePreviousChoices() {
        XCTAssertEqual(SoundPreset.allCases.count, 7)
        XCTAssertEqual(SoundPreset.restored("commute"), .vocal)
        XCTAssertEqual(SoundPreset.restored("night"), .soft)
        XCTAssertEqual(SoundPreset.restored("hall"), .hall)
        XCTAssertEqual(SoundPreset.restored("unknown"), .original)
    }
    func testSurroundWidensSidesPreservesMonoAndRequiresStereo() {
        let mono = (0..<8_000).flatMap { i -> [Float] in let value = Float(0.2 * sin(Double(i) * 0.08)); return [value,value] }
        let centered = render(.surround, mono)
        for i in stride(from: 2_000, to: mono.count, by: 2) {
            XCTAssertEqual(centered[i], centered[i+1], accuracy: 0.000001)
            XCTAssertEqual(centered[i], mono[i] * Float(SoundPreset.surround.preamp), accuracy: 0.000001)
        }
        var impulse = [Float](repeating: 0, count: 8_000 * 2); impulse[1_024 * 2] = 0.5
        let widened = render(.surround, impulse)
        XCTAssertLessThan(widened[1_024 * 2 + 1], 0, "Side expansion must affect the opposite channel")
        XCTAssertGreaterThan(abs(widened[(1_024 + 384) * 2]), 0.005, "8ms early reflection must exist")
        for i in stride(from: 2_000, to: impulse.count, by: 2) {
            XCTAssertEqual(widened[i] + widened[i+1], (impulse[i] + impulse[i+1]) * Float(SoundPreset.surround.preamp), accuracy: 0.000001)
        }
        let dsp = SoundDSP(preset: .surround); dsp.prepare(format())
        var one: Float = 0.25
        withUnsafeMutablePointer(to: &one) { ptr in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: ptr))
            XCTAssertFalse(dsp.process(&list, frames: 1))
        }
        XCTAssertEqual(one,0.25); XCTAssertEqual(dsp.formatStatus.load(ordering: .acquiring), -2)
    }
    func testRoomsHaveDifferentDecayingTailsAndCrossChannelReflections() {
        var impulse = [Float](repeating: 0, count: 96_000 * 2); impulse[2_048 * 2] = 0.5
        let hall = render(.hall,impulse), studio = render(.studio,impulse)
        func energy(_ samples: [Float], _ start: Int, _ end: Int) -> Double { samples[(start * 2)..<(end * 2)].reduce(0) { $0 + Double($1 * $1) } }
        XCTAssertGreaterThan(energy(hall,12_000,24_000), 1e-8, "Hall must have a real reverberation tail")
        XCTAssertGreaterThan(energy(hall,12_000,24_000), energy(studio,12_000,24_000) * 10)
        XCTAssertLessThan(energy(hall,72_000,96_000), energy(hall,12_000,36_000) * 0.001)
        XCTAssertGreaterThan(energy(studio,2_500,5_000), 1e-7, "Studio needs short room reflections")
        XCTAssertTrue(stride(from: 4_097, to: 24_000, by: 2).contains { abs(hall[$0]) > 0.00001 })
        for preset in [SoundPreset.hall, .studio] {
            let dsp = SoundDSP(preset:preset); dsp.prepare(format(channels:2))
            var samples = impulse
            samples.withUnsafeMutableBytes { p in
                var list = AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(p.count),mData:p.baseAddress))
                XCTAssertTrue(dsp.process(&list,frames:96_000))
            }
            dsp.reset(); samples = [Float](repeating:0,count:4_096)
            samples.withUnsafeMutableBytes { p in
                var list = AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(p.count),mData:p.baseAddress))
                XCTAssertTrue(dsp.process(&list,frames:2_048))
            }
            XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "Seeking must remove the old room tail")
        }
    }
    func testSpatialPlanarMatchesInterleavedAndProcessingIsBlockIndependent() {
        let input = (0..<7_000).flatMap { i in [Float(0.7 * sin(Double(i)*0.07)),Float(0.4 * cos(Double(i)*0.11))] }
        for preset in [SoundPreset.surround,.hall,.studio] {
            let expected = render(preset,input,block:7_000)
            XCTAssertEqual(expected,render(preset,input,block:113))
            let dsp = SoundDSP(preset:preset)
            var f = format(channels:2); f.mFormatFlags |= kAudioFormatFlagIsNonInterleaved; f.mBytesPerFrame = 4; f.mBytesPerPacket = 4
            dsp.prepare(f)
            var left = stride(from:0,to:input.count,by:2).map { input[$0] }
            var right = stride(from:1,to:input.count,by:2).map { input[$0] }
            let list = AudioBufferList.allocate(maximumBuffers:2)
            defer { list.unsafeMutablePointer.deallocate() }
            left.withUnsafeMutableBytes { l in right.withUnsafeMutableBytes { r in
                list[0] = AudioBuffer(mNumberChannels:1,mDataByteSize:UInt32(l.count),mData:l.baseAddress)
                list[1] = AudioBuffer(mNumberChannels:1,mDataByteSize:UInt32(r.count),mData:r.baseAddress)
                XCTAssertTrue(dsp.process(list.unsafeMutablePointer,frames:7_000))
            } }
            for i in 0..<7_000 { XCTAssertEqual(left[i],expected[i*2]); XCTAssertEqual(right[i],expected[i*2+1]) }
        }
    }
    func testRoomFeedbackDoesNotBuildUpOnDCAndDamagedInputIsSanitized() {
        for rate in [44_100.0,48_000,96_000,192_000] {
            for preset in [SoundPreset.hall,.studio] {
                let frames = Int(rate * 0.75)
                var dc = [Float](repeating:1,count:frames * 2)
                dc[2_002] = .nan; dc[3_001] = .infinity
                let output = render(preset,dc,rate:rate,block:1024)
                XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
                XCTAssertLessThan(output.suffix(frames).map { abs($0) }.max()!,0.95, "DC must not cause feedback saturation")
                var impulse = [Float](repeating:0,count:frames * 2)
                impulse[2_048] = 0.5
                let response = render(preset,impulse,rate:rate,block:1024)
                let early = response[Int(rate*0.10)*2..<Int(rate*0.25)*2].reduce(0) { $0 + Double($1*$1) }
                let late = response[Int(rate*0.50)*2..<Int(rate*0.75)*2].reduce(0) { $0 + Double($1*$1) }
                XCTAssertGreaterThan(early,1e-12)
                XCTAssertLessThan(late,early * 0.02)
            }
        }
    }

    func testProcessingStaysFiniteAtSupportedRatesAndMalformedBuffersBypass() {
        for rate in [8_000.0,48_000,96_000,192_000] {
            let signal = (0..<12_000).flatMap { i in [Float(sin(Double(i)*0.037)),Float(cos(Double(i)*0.049))] }
            for preset in SoundPreset.allCases {
                let output = render(preset,signal,rate:rate)
                XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
                if preset != .original { XCTAssertLessThan(output.filter { abs($0) >= 0.9999 }.count, 100, "Effects should leave headroom, not routinely clip: \(preset) at \(rate)") }
                else { XCTAssertEqual(output,signal) }
            }
        }
        let dsp = SoundDSP(preset:.hall); dsp.prepare(format(channels:2))
        var samples:[Float] = [0.3,0.2]
        samples.withUnsafeMutableBytes { p in
            var list = AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:4,mData:p.baseAddress))
            XCTAssertFalse(dsp.process(&list,frames:1))
        }
        XCTAssertEqual(samples,[0.3,0.2])
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
        let item = AVPlayerItem(asset: asset), effect = try SoundTap(preset: .hall)
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
        let replacement = try SoundTap(preset: .surround)
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
