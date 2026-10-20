// Native, offline screen-recording pipeline verification (no screen/mic permission).
// swiftc -swift-version 5 -parse-as-library QuickRecorder/RecordingOptions.swift \
//   QuickRecorder/RecordingSession.swift QuickRecorder/RecordingVideoProcessor.swift \
//   verification/RecordingPipelineVerification.swift -o /tmp/qr-pipeline-verification
// /tmp/qr-pipeline-verification [OUTPUT_FOLDER] [baseline|peak|vbr|hardware]
import Foundation
import AVFoundation
import VideoToolbox

@main struct RecordingPipelineVerification {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "RecordingPipelineVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func pcm(rate: Int = 48000, channels: Int = 2, frames: Int = 1024, offset: Int = 0, constant: Float? = nil) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            for index in 0..<frames { buffer.floatChannelData![channel][index] = constant ?? (0.2 * sin(Float(offset + index) * 2 * .pi * 440 / Float(rate))) }
        }
        return buffer
    }

    static func video(at seconds: Double, seed: UInt8 = 20) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        try require(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &image) == kCVReturnSuccess, "CVPixelBufferCreate")
        let pixel = image!
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for row in 0..<180 { for column in 0..<320 {
            let offset = row * stride + column * 4
            base[offset] = seed; base[offset + 1] = UInt8((row + column) % 255)
            base[offset + 2] = 120; base[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "Video sample creation")
        return sample!
    }

    static func verifyPrimitives() throws {
        var timeline = RecordingTimeline()
        timeline.start(at: CMTime(seconds: 100, preferredTimescale: 600000))
        timeline.pause(at: CMTime(seconds: 110, preferredTimescale: 600000))
        timeline.resume(at: CMTime(seconds: 140, preferredTimescale: 600000))
        try require(timeline.presentationTime(for: CMTime(seconds: 150, preferredTimescale: 600000)).seconds == 20, "Shared pause offset")
        timeline.pause(at: CMTime(seconds: 160, preferredTimescale: 600000))
        try require(timeline.elapsed(at: CMTime(seconds: 1000, preferredTimescale: 600000)).seconds == 30, "Stopping while paused must freeze time")
        let input = pcm().recordingSampleBuffer(at: CMTime(seconds: 150, preferredTimescale: 600000))!
        let normalized = recordingRetimedSample(input, offset: timeline.origin + timeline.pauseOffset)!
        try require(normalized.presentationTimeStamp.seconds == 20, "Audio and video use the same normalized epoch")
        let first = recordingAudioSlice(input, offset: 0, count: 500)!
        let second = recordingAudioSlice(input, offset: 500, count: 524)!
        try require(first.numSamples + second.numSamples == input.numSamples, "Segment split preserves PCM frame count")
        try require(abs((second.presentationTimeStamp - input.presentationTimeStamp).seconds - 500.0 / 48000) < 0.000001, "Segment split preserves sample clock")
        let converter = RecordingAudioConverter(sampleRate: 24000, channels: 1)
        let converted = converter.convert(input)!
        try require(converted.format.channelCount == 1 && converted.format.sampleRate == 24000, "Explicit mono/resample")
        let muted = converter.convert(input, muted: true)!
        try require((0..<Int(muted.frameLength)).allSatisfy { muted.floatChannelData![0][$0] == 0 }, "Mic mute generates silence")
        let muteSample = muted.recordingSampleBuffer(at: input.presentationTimeStamp)!
        try require(muteSample.presentationTimeStamp == input.presentationTimeStamp, "Mic mute preserves capture time")
        let mixer = RecordingAudioMixer(sampleRate: 24000, channels: 1, mixesTwoSources: true)
        var total = 0
        var values: [Float] = []
        for index in 0..<30 {
            let pts = CMTime(value: Int64(index * 1024), timescale: 24000)
            let a = pcm(rate: 24000, channels: 1, constant: 0.2)
            let b = pcm(rate: 24000, channels: 1, constant: 0.6)
            let samples = mixer.append(a, at: pts, source: .system) + mixer.append(b, at: pts, source: .microphone)
            for sample in samples { total += sample.numSamples; values.append(sample.presentationTimeStamp.seconds.isFinite ? 1 : 0) }
        }
        total += mixer.finish().reduce(0) { $0 + $1.numSamples }
        try require(total == 30 * 1024 && values.allSatisfy { $0 == 1 }, "Realtime mixer must retain continuous sample count")
        let invalid = mixer.append(pcm(rate: 24000, channels: 2), at: .invalid, source: .system)
        try require(invalid.isEmpty, "Mixer must reject invalid timestamp/channel format")
        let gapMixer = RecordingAudioMixer(sampleRate: 24000, channels: 1, mixesTwoSources: false)
        let far = gapMixer.append(pcm(rate: 24000, channels: 1), at: CMTime(seconds: 86400, preferredTimescale: 600), source: .system)
        try require(far.count < 10 && gapMixer.finish().count < 10, "A source timestamp gap must not allocate hours of silence")
        print("PASS timeline/pause, resample/mono, timestamp-preserving mute, PCM segment slicing, bounded realtime mixer")
    }

    static func waitReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        try require(input.isReadyForMoreMediaData && writer.status == .writing, "Writer input stalled: \(String(describing: writer.error))")
    }

    static func encodedTimes(_ asset: AVAsset, media: AVMediaType) throws -> [Double] {
        guard let track = asset.tracks(withMediaType: media).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try require(reader.startReading(), "AssetReader start")
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            // The reader ends a track with marker buffers (no samples / invalid PTS); they carry no media.
            let count = sample.numSamples
            guard count > 0, sample.presentationTimeStamp.isNumeric else { continue }
            let step = sample.duration.isNumeric ? sample.duration.seconds / Double(count) : 0
            for index in 0..<count { times.append(sample.presentationTimeStamp.seconds + Double(index) * step) }
        }
        try require(reader.status == .completed, "AssetReader failed: \(String(describing: reader.error))")
        return times
    }

    static func writeProbe(folder: URL, fps: Double, codec: AVVideoCodecType, variant: String) throws -> URL {
        let suite = "QuickRecorder.Pipeline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var values: [String: Any] = ["frameRate": fps, "rateControl": "bitrate", "videoBitrateKbps": 120.0,
            "audioSampleRate": 24000, "audioChannels": 1, "audioBitrateKbps": 32, "audioFormat": "aac",
            "encoder": codec == .hevc ? "h265" : "h264", "videoFormat": "mp4", "recordWinSound": true,
            "keyFrameIntervalSeconds": 2.0, "frameReordering": "disabled"]
        if variant == "peak" { values["peakBitrateKbps"] = 300.0; values["encoderPriority"] = "speed" }
        if variant == "vbr" { values["audioBitrateMode"] = "variable" }
        if variant == "hardware" { values["requireHardware"] = true }
        let options = RecordingOptions(values: values, defaults: defaults)
        try options.validate()
        let url = folder.appendingPathComponent("\(variant)-\(codec.rawValue)-\(fps)fps.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var videoSettings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: recordingVideoCompression(options: options, width: 320, height: 180,
                hevc: codec == .hevc, hdr: false, legacyQuality: 1, audioTrackCount: 1)]
        if options.requireHardware { videoSettings[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] }
        try require(writer.canApply(outputSettings: videoSettings, forMediaType: .video), "Unsupported video settings \(variant)")
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let strategy = options.audioBitrateMode == "variable" ? AVAudioBitRateStrategy_VariableConstrained : AVAudioBitRateStrategy_LongTermAverage
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000, AVEncoderBitRateStrategyKey: strategy]
        try require(writer.canApply(outputSettings: audioSettings, forMediaType: .audio), "Unsupported AAC settings")
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        writer.add(videoInput); writer.add(audioInput)
        try require(writer.startWriting(), "Writer start: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        let duration = 8.0
        let totalFrames = Int(duration * 24000)
        var nextVideo = 0.0
        var lastVideo: CMSampleBuffer?
        var position = 0
        while position < totalFrames {
            let time = Double(position) / 24000
            if time + 0.000001 >= nextVideo {
                let sample = try video(at: nextVideo, seed: UInt8(20 + Int(nextVideo) * 10))
                try waitReady(videoInput, writer: writer)
                try require(videoInput.append(sample), "Video append: \(String(describing: writer.error))")
                lastVideo = sample
                nextVideo += 1 / fps
            }
            let count = min(1024, totalFrames - position)
            let sample = pcm(rate: 24000, channels: 1, frames: count, offset: position).recordingSampleBuffer(at: CMTime(value: Int64(position), timescale: 24000))!
            try waitReady(audioInput, writer: writer)
            try require(audioInput.append(sample), "AAC append: \(String(describing: writer.error))")
            position += count
        }
        let terminalPTS = CMTime(seconds: duration, preferredTimescale: 600000) - recordingTerminalFrameLead
        let terminal = recordingRetimedSample(lastVideo!, offset: lastVideo!.presentationTimeStamp - terminalPTS)!
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "QuickRecorder.PipelineVerification.finalize")
        var outcome: Result<Void, Error>?
        queue.async {
            RecordingWriterFinalizer.finish(writer: writer, video: videoInput, videoSamples: [terminal],
                audio: [.init(input: audioInput, samples: [])], end: CMTime(seconds: duration, preferredTimescale: 600000), on: queue) {
                    outcome = $0; semaphore.signal()
                }
        }
        try require(semaphore.wait(timeout: .now() + 20) == .success, "Finalizer timeout")
        try outcome!.get()
        let asset = AVAsset(url: url)
        let videoTimes = try encodedTimes(asset, media: .video)
        let audioTimes = try encodedTimes(asset, media: .audio)
        try require(videoTimes.count >= 2 && videoTimes.last! > duration - 0.1, "Terminal sparse frame missing: \(videoTimes)")
        try require(audioTimes.count > 150 && audioTimes.last! > duration - 0.1, "Audio must continue between sparse video frames")
        for index in 1..<audioTimes.count { try require(audioTimes[index] - audioTimes[index - 1] < 0.05, "AAC gap over 50 ms") }
        try require(abs(asset.duration.seconds - duration) < 0.1, "Movie duration differs from timeline")
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
        print("PASS \(variant) \(codec.rawValue) fps=\(fps) videoPTS=\(videoTimes) audioPackets=\(audioTimes.count) duration=\(asset.duration.seconds) bytes=\(bytes) file=\(url.path)")
        return url
    }

    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/quickrecorder-pipeline-verification", isDirectory: true)
        let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "baseline"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try verifyPrimitives()
        _ = try writeProbe(folder: folder, fps: 0.2, codec: .hevc, variant: variant)
        _ = try writeProbe(folder: folder, fps: 0.5, codec: .h264, variant: variant)
    }
}
