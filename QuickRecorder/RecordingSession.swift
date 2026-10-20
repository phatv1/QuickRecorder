// Resource-aware recording primitives. These types deliberately have no UI dependencies.
import Foundation
import AVFoundation
import VideoToolbox

struct RecordingTimeline {
    private(set) var origin: CMTime = .zero
    private(set) var pauseOffset: CMTime = .zero
    private(set) var pausedAt: CMTime?

    mutating func start(at hostTime: CMTime) {
        origin = hostTime
        pauseOffset = .zero
        pausedAt = nil
    }

    mutating func pause(at hostTime: CMTime) {
        if pausedAt == nil { pausedAt = hostTime }
    }

    mutating func resume(at hostTime: CMTime) {
        guard let pausedAt else { return }
        pauseOffset = CMTimeAdd(pauseOffset, CMTimeMaximum(.zero, CMTimeSubtract(hostTime, pausedAt)))
        self.pausedAt = nil
    }

    func presentationTime(for sourceTime: CMTime) -> CMTime {
        CMTimeSubtract(CMTimeSubtract(sourceTime, origin), pauseOffset)
    }

    func elapsed(at hostTime: CMTime) -> CMTime {
        CMTimeMaximum(.zero, presentationTime(for: pausedAt ?? hostTime))
    }
}

/// Copies timing entries, rather than allocating one entry per PCM sample.
func recordingRetimedSample(_ sample: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
    var count = 0
    guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
          count > 0 else { return nil }
    var entries = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &entries, entriesNeededOut: nil) == noErr else { return nil }
    for index in entries.indices {
        if entries[index].presentationTimeStamp.isValid { entries[index].presentationTimeStamp = CMTimeSubtract(entries[index].presentationTimeStamp, offset) }
        if entries[index].decodeTimeStamp.isValid { entries[index].decodeTimeStamp = CMTimeSubtract(entries[index].decodeTimeStamp, offset) }
    }
    var output: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
        sampleTimingEntryCount: count, sampleTimingArray: &entries, sampleBufferOut: &output) == noErr else { return nil }
    return output
}

extension AVAudioPCMBuffer {
    /// Uses the captured buffer's time. Passing wall-clock callback time would add scheduling jitter.
    func recordingSampleBuffer(at time: CMTime) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: Int(frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
            let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: audioBufferList) == noErr else { return nil }
        return sample
    }
}

/// One persistent converter per source preserves resampler state between capture callbacks.
final class RecordingAudioConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(sampleRate: Int, channels: Int) {
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))!
    }

    func convert(_ sample: CMSampleBuffer, muted: Bool = false) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription, var asbd = description.audioStreamBasicDescription,
              let inputFormat = AVAudioFormat(streamDescription: &asbd),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
        input.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else { return nil }
        if sourceFormat != inputFormat {
            sourceFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 64)) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        if muted, let channels = output.floatChannelData {
            for channel in 0..<Int(outputFormat.channelCount) { channels[channel].initialize(repeating: 0, count: Int(output.frameLength)) }
        }
        return output
    }
}

/// Small timestamp-addressed PCM chunks. A missing source becomes silence after 150 ms,
/// so unplugging a microphone cannot grow memory or hold back system audio indefinitely.
final class RecordingAudioMixer {
    enum Source: Hashable { case system, microphone }
    let format: AVAudioFormat
    private let chunkFrames = 1024
    private let gains: Float
    private var chunks: [Int64: [[Float]]] = [:]
    private var latest: [Source: Int64] = [:]
    private var nextChunk: Int64 = 0
    private var finalFrame: Int64 = 0
    private(set) var discardedLateFrames = 0

    init(sampleRate: Int, channels: Int, mixesTwoSources: Bool) {
        format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))!
        gains = mixesTwoSources ? 0.5 : 1
    }

    func append(_ pcm: AVAudioPCMBuffer, at pts: CMTime, source: Source) -> [CMSampleBuffer] {
        guard pts.isNumeric, pts.seconds.isFinite, pts.seconds >= 0,
              pts.seconds < Double(Int64.max / 2) / format.sampleRate,
              pcm.format.sampleRate == format.sampleRate,
              pcm.format.channelCount == format.channelCount,
              pcm.format.commonFormat == .pcmFormatFloat32, !pcm.format.isInterleaved,
              pcm.frameLength <= 65536,
              let input = pcm.floatChannelData else { return [] }
        let start = Int64((pts.seconds * format.sampleRate).rounded())
        for index in 0..<Int(pcm.frameLength) {
            let position = start + Int64(index)
            if position < nextChunk * Int64(chunkFrames) { discardedLateFrames += 1; continue }
            let chunkIndex = position / Int64(chunkFrames)
            if chunks[chunkIndex] == nil {
                chunks[chunkIndex] = Array(repeating: [Float](repeating: 0, count: chunkFrames), count: Int(format.channelCount))
            }
            for channel in 0..<Int(format.channelCount) {
                chunks[chunkIndex]![channel][Int(position % Int64(chunkFrames))] += input[channel][index] * gains
            }
        }
        let end = max(0, start + Int64(pcm.frameLength))
        latest[source] = max(latest[source] ?? 0, end)
        finalFrame = max(finalFrame, end)
        // A stalled source must not prevent progress. The bounded wait absorbs callback jitter.
        let deadline = max(0, finalFrame - Int64(format.sampleRate * 0.15))
        let watermark = latest.count == 2 ? max(latest.values.min() ?? 0, deadline) : deadline
        return drain(through: watermark, final: false)
    }

    func finish() -> [CMSampleBuffer] { drain(through: finalFrame, final: true) }

    private func drain(through frame: Int64, final: Bool) -> [CMSampleBuffer] {
        var result: [CMSampleBuffer] = []
        while (nextChunk + 1) * Int64(chunkFrames) <= frame || (final && nextChunk * Int64(chunkFrames) < frame) {
            if chunks[nextChunk] == nil {
                guard let available = chunks.keys.filter({ $0 >= nextChunk }).min() else { break }
                nextChunk = available
                if !final && (nextChunk + 1) * Int64(chunkFrames) > frame { break }
            }
            let start = nextChunk * Int64(chunkFrames)
            let count = Int(min(Int64(chunkFrames), frame - start))
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = output.floatChannelData else { break }
            output.frameLength = AVAudioFrameCount(count)
            let values = chunks.removeValue(forKey: nextChunk)
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<count { data[channel][index] = min(1, max(-1, values?[channel][index] ?? 0)) }
            }
            if let sample = output.recordingSampleBuffer(at: CMTime(value: start, timescale: CMTimeScale(format.sampleRate))) { result.append(sample) }
            nextChunk += 1
        }
        return result
    }
}

struct RecordingSegment: Codable {
    let file: String
    let startSeconds: Double
    let durationSeconds: Double
}

struct RecordingManifest: Codable {
    let version: Int
    let startedAt: Date
    var segments: [RecordingSegment]
}

/// AVAssetWriter's supported H.264/HEVC path uses a target bitrate. A quality slider
/// therefore selects an estimated target rather than claiming unsupported constant quality.
func recordingVideoCompression(options: RecordingOptions, width: Int, height: Int,
                               hevc: Bool, hdr: Bool, legacyQuality: Double,
                               audioTrackCount: Int) -> [String: Any] {
    let fps = options.frameRate
    let pixels = Double(max(600, width)) * Double(max(600, height))
    let fpsMultiplier = fps / 8
    var quality = 1 - log10(max(0.0001, sqrt(pixels) * fpsMultiplier)) / 5
    if legacyQuality == 0.3 { quality = max(0.1, quality) }
    else if legacyQuality == 0.7 { quality = max(0.4, min(0.6, quality * 3)) }
    else { quality = 1 }
    let legacy = pixels * fpsMultiplier * (hevc ? 0.5 : 0.9) * quality * (hdr ? 2 : 1)
    var bitrate = max(200000, Int(legacy))
    switch options.rateControl {
    case "bitrate": bitrate = Int(options.videoBitrateKbps * 1000)
    case "budget":
        let total = options.storageBudgetMBPerHour * 1_000_000 * 8 / 3600
        bitrate = max(1000, Int(total * 0.97) - audioTrackCount * options.audioBitrateKbps * 1000)
    case "quality":
        // Nonlinear slider; sparse desktop still needs enough bits for readable intra frames.
        bitrate = Int(Double(width * height) * max(0.2, sqrt(fps)) * (hevc ? 0.07 : 0.11) * pow(12, options.encoderQuality))
    default: break
    }
    var properties: [String: Any] = [
        AVVideoProfileLevelKey: hevc ? (hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) : AVVideoProfileLevelH264HighAutoLevel,
        AVVideoAverageBitRateKey: max(1000, bitrate),
        AVVideoExpectedSourceFrameRateKey: fps
    ]
    if options.keyFrameIntervalSeconds > 0 { properties[AVVideoMaxKeyFrameIntervalDurationKey] = options.keyFrameIntervalSeconds }
    if options.frameReordering != "automatic" { properties[AVVideoAllowFrameReorderingKey] = options.frameReordering == "enabled" }
    if options.encoderPriority == "speed" {
        properties[AVVideoAllowFrameReorderingKey] = false
        if !hevc { properties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCAVLC }
    }
    if options.peakBitrateKbps > 0 {
        properties[kVTCompressionPropertyKey_DataRateLimits as String] = [options.peakBitrateKbps * 1000 / 8, 1.0]
    }
    return properties
}

/// Finishes one writer independently of the active segment. Pending media and the
/// terminal still remain owned until readiness returns; a timeout is an explicit error.
/// How far before the session end the terminal (still) video frame is placed. AVAssetWriter's
/// video track timescale is 600, so anything under 1/600 s rounds onto the end and the frame is dropped.
let recordingTerminalFrameLead = CMTime(value: 1, timescale: 600)
/// movieFragmentInterval for SDR writers; a crash loses at most about this much plus encoder latency.
let recordingFragmentSeconds = 2.0

final class RecordingWriterFinalizer {
    struct AudioTrack {
        let input: AVAssetWriterInput
        var samples: [CMSampleBuffer]
    }
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput?
    private var videoSamples: [CMSampleBuffer]
    private var tracks: [AudioTrack]
    private let end: CMTime
    private let queue: DispatchQueue
    private let deadline: Date
    private let completion: (Result<Void, Error>) -> Void
    private var failure: Error?

    static func finish(writer: AVAssetWriter, video: AVAssetWriterInput?,
                       videoSamples: [CMSampleBuffer], audio: [AudioTrack], end: CMTime,
                       on queue: DispatchQueue, timeout: TimeInterval = 2,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        let finalizer = RecordingWriterFinalizer(writer: writer, video: video, videoSamples: videoSamples,
            audio: audio, end: end, queue: queue, timeout: timeout, completion: completion)
        finalizer.poll()
    }

    private init(writer: AVAssetWriter, video: AVAssetWriterInput?, videoSamples: [CMSampleBuffer],
                 audio: [AudioTrack], end: CMTime, queue: DispatchQueue, timeout: TimeInterval,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        self.writer = writer
        self.video = video
        self.videoSamples = videoSamples
        self.tracks = audio
        self.end = end
        self.queue = queue
        self.deadline = Date().addingTimeInterval(timeout)
        self.completion = completion
    }

    private func poll() {
        guard writer.status == .writing else {
            completion(.failure(writer.error ?? NSError(domain: "QuickRecorder.Writer", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "The writer stopped before its media could be finalized."])))
            return
        }
        if let video {
            while !videoSamples.isEmpty && video.isReadyForMoreMediaData {
                if !video.append(videoSamples.removeFirst()) { failure = writer.error ?? appendError(); break }
            }
        }
        for index in tracks.indices {
            while !tracks[index].samples.isEmpty && tracks[index].input.isReadyForMoreMediaData {
                if !tracks[index].input.append(tracks[index].samples.removeFirst()) { failure = writer.error ?? appendError(); break }
            }
        }
        let pending = !videoSamples.isEmpty || tracks.contains { !$0.samples.isEmpty }
        if pending && failure == nil && Date() < deadline {
            queue.asyncAfter(deadline: .now() + 0.02) { self.poll() }
            return
        }
        if pending && failure == nil {
            failure = NSError(domain: "QuickRecorder.Writer", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "The encoder remained blocked while saving pending audio or the final video frame. The saved recording may be incomplete."])
        }
        guard writer.status == .writing else { completion(.failure(writer.error ?? failure ?? appendError())); return }
        writer.endSession(atSourceTime: end)
        video?.markAsFinished()
        for track in tracks { track.input.markAsFinished() }
        writer.finishWriting {
            self.queue.async {
                if self.writer.status == .completed && self.failure == nil { self.completion(.success(())) }
                else { self.completion(.failure(self.writer.error ?? self.failure ?? self.appendError())) }
            }
        }
    }

    private func appendError() -> Error {
        NSError(domain: "QuickRecorder.Writer", code: 10,
            userInfo: [NSLocalizedDescriptionKey: "An audio or video sample could not be written."])
    }
}

func recordingAudioSlice(_ sample: CMSampleBuffer, offset: Int, count: Int) -> CMSampleBuffer? {
    guard offset >= 0, count > 0, offset <= sample.numSamples, count <= sample.numSamples - offset,
          offset <= Int(Int32.max), count <= Int(Int32.max),
          var asbd = sample.formatDescription?.audioStreamBasicDescription,
          let format = AVAudioFormat(streamDescription: &asbd),
          let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
    output.frameLength = AVAudioFrameCount(count)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset), frameCount: Int32(count),
        into: output.mutableAudioBufferList) == noErr else { return nil }
    let pts = sample.presentationTimeStamp + CMTime(value: Int64(offset), timescale: CMTimeScale(format.sampleRate))
    return output.recordingSampleBuffer(at: pts)
}
