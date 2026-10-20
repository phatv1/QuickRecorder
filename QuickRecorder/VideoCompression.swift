import Foundation
import AVFoundation
import CoreImage
import VideoToolbox
import AudioToolbox

/// Settings for a new, offline export. The source is always retained.
struct VideoCompressionOptions {
    enum Codec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC" }
    enum Container: String, CaseIterable { case mp4, mov }
    enum Geometry: String, CaseIterable { case fit = "Fit", fill = "Fill", stretch = "Stretch" }
    enum AudioMode: String, CaseIterable {
        case separate = "Keep all tracks separately"
        case mix = "Mix all tracks"
        case first = "First track"
        case remove = "Remove audio"
    }
    var codec: Codec = .hevc
    var container: Container = .mp4
    var width: Int? = 1280
    var height: Int? = 720
    var geometry: Geometry = .fit
    var framesPerSecond: Double? = 0.5
    var videoBitRate: Int = 150_000
    var grayscale: Bool = false
    var audioMode: AudioMode = .separate
    var audioSampleRate: Int = 24_000
    var audioChannels: Int = 1
    var audioBitRate: Int = 32_000
    var requireHardwareEncoder: Bool = false
}

struct VideoFileInspection {
    struct Track {
        let mediaType: String
        let startSeconds: Double
        let durationSeconds: Double
        let nominalFrameRate: Float
        let estimatedBitsPerSecond: Float
    }
    let url: URL
    let bytes: Int64
    let durationSeconds: Double
    let width: Int
    let height: Int
    let tracks: [Track]
    var audioTrackCount: Int { tracks.filter { $0.mediaType == AVMediaType.audio.rawValue }.count }
    var videoTrackCount: Int { tracks.filter { $0.mediaType == AVMediaType.video.rawValue }.count }

    /// Container/track metadata inspection; it does not claim to detect gaps inside a track.
    static func inspect(url: URL) throws -> VideoFileInspection {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { throw VideoCompressionError.message("The file has no readable duration.") }
        let video = asset.tracks(withMediaType: .video).first
        let rect = video.map { CGRect(origin: .zero, size: $0.naturalSize).applying($0.preferredTransform) } ?? .zero
        guard rect.width.isFinite, rect.height.isFinite, abs(rect.width) <= 100_000, abs(rect.height) <= 100_000 else {
            throw VideoCompressionError.message("The source has invalid video dimensions.")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return VideoFileInspection(url: url, bytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            durationSeconds: duration, width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()),
            tracks: asset.tracks.map { Track(mediaType: $0.mediaType.rawValue,
                startSeconds: CMTimeGetSeconds($0.timeRange.start), durationSeconds: CMTimeGetSeconds($0.timeRange.duration),
                nominalFrameRate: $0.nominalFrameRate, estimatedBitsPerSecond: $0.estimatedDataRate) })
    }
}

struct VideoCompressionResult {
    let source: VideoFileInspection
    let output: VideoFileInspection
    let codec: VideoCompressionOptions.Codec
    let hardwareWasRequired: Bool
    var bytesSaved: Int64 { source.bytes - output.bytes }
}

enum VideoCompressionError: LocalizedError {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .cancelled: return "Compression cancelled. The source file was kept."
        }
    }
}

/// Native offline transcoding with independent audio/video pumps and original timestamps.
/// Completion/progress callbacks run on a background queue. Retain this object to cancel.
final class VideoCompressor {
    private let lock = NSLock()
    private var cancelled = false
    private var running = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    static func supportsHardware(codec: VideoCompressionOptions.Codec, width: Int = 1280, height: Int = 720) -> Bool {
        var session: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session = session else { return false }
        defer { VTCompressionSessionInvalidate(session) }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { return false }
        var value: CFTypeRef?
        guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                    allocator: kCFAllocatorDefault, valueOut: &value) == noErr else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let currentReader = reader
        let currentWriter = writer
        lock.unlock()
        if currentReader?.status == .reading { currentReader?.cancelReading() }
        if currentWriter?.status == .writing { currentWriter?.cancelWriting() }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func compress(sourceURL: URL, destinationDirectory: URL? = nil, options: VideoCompressionOptions,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<VideoCompressionResult, Error>) -> Void) {
        lock.lock()
        guard !running else {
            lock.unlock()
            DispatchQueue.global().async { completion(.failure(VideoCompressionError.message("A compression export is already running."))) }
            return
        }
        running = true
        cancelled = false
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            var destination: URL?
            do {
                let result = try self.run(sourceURL: sourceURL, destinationDirectory: destinationDirectory,
                                          options: options, destination: &destination, progress: progress)
                self.clearState()
                completion(.success(result))
            } catch {
                self.stopActive()
                // Only our newly created destination may be removed, never the input.
                if let url = destination, url.standardizedFileURL != sourceURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                self.clearState()
                completion(.failure(error))
            }
        }
    }

    private func clearState() {
        lock.lock(); defer { lock.unlock() }
        reader = nil
        writer = nil
        running = false
    }

    private func stopActive() {
        lock.lock()
        let currentReader = reader
        let currentWriter = writer
        lock.unlock()
        if currentReader?.status == .reading { currentReader?.cancelReading() }
        if currentWriter?.status == .writing { currentWriter?.cancelWriting() }
    }

    private func run(sourceURL: URL, destinationDirectory: URL?, options: VideoCompressionOptions,
                     destination: inout URL?, progress: @escaping (Double) -> Void) throws -> VideoCompressionResult {
        try validate(options)
        if isCancelled { throw VideoCompressionError.cancelled }
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        let directoryAccess = destinationDirectory?.startAccessingSecurityScopedResource() ?? false
        defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            if directoryAccess { destinationDirectory?.stopAccessingSecurityScopedResource() }
        }
        let sourceInfo = try VideoFileInspection.inspect(url: sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw VideoCompressionError.message("Choose a file containing a video track.")
        }
        let width = options.width ?? max(2, sourceInfo.width - sourceInfo.width % 2)
        let height = options.height ?? max(2, sourceInfo.height - sourceInfo.height % 2)
        guard (16...8192).contains(width), (16...8192).contains(height) else {
            throw VideoCompressionError.message("Output dimensions must be from 16 to 8192 pixels. Choose a smaller custom size for this source.")
        }
        let directory = destinationDirectory ?? sourceURL.deletingLastPathComponent()
        // UUID prevents replacing either the original or an earlier export.
        var outputURL: URL
        repeat {
            let name = sourceURL.deletingPathExtension().lastPathComponent + " (compressed " + UUID().uuidString.prefix(8) + ")." + options.container.rawValue
            outputURL = directory.appendingPathComponent(name)
        } while FileManager.default.fileExists(atPath: outputURL.path)
        guard outputURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw VideoCompressionError.message("The output must differ from the source.")
        }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: options.container == .mp4 ? .mp4 : .mov)
        lock.lock()
        self.reader = reader
        self.writer = writer
        lock.unlock()

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoCompressionError.message("The source video cannot be decoded.") }
        reader.add(videoOutput)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: options.videoBitRate, AVVideoAllowFrameReorderingKey: false,
                                          AVVideoMaxKeyFrameIntervalDurationKey: 10.0]
        if let fps = options.framesPerSecond { compression[AVVideoExpectedSourceFrameRateKey] = fps }
        var videoSettings: [String: Any] = [AVVideoCodecKey: options.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        if options.requireHardwareEncoder {
            guard Self.supportsHardware(codec: options.codec, width: width, height: height) else {
                throw VideoCompressionError.message("This Mac does not report hardware support for the selected codec.")
            }
            videoSettings[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw VideoCompressionError.message("The selected codec, dimensions, or video settings are unsupported.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoCompressionError.message("Cannot add the video encoder.") }
        writer.add(videoInput)

        let sourceAudioTracks = asset.tracks(withMediaType: .audio)
        let audioGroups: [[AVAssetTrack]]
        switch options.audioMode {
        case .separate: audioGroups = sourceAudioTracks.map { [$0] }
        case .mix: audioGroups = sourceAudioTracks.isEmpty ? [] : [sourceAudioTracks]
        case .first: audioGroups = sourceAudioTracks.first.map { [[$0]] } ?? []
        case .remove: audioGroups = []
        }
        var audioPipes: [(AVAssetReaderAudioMixOutput, AVAssetWriterInput)] = []
        for tracks in audioGroups {
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: options.audioSampleRate,
                AVNumberOfChannelsKey: options.audioChannels, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            output.alwaysCopiesSampleData = false
            if tracks.count > 1 {
                // Sum with headroom to avoid clipping when several tracks are active.
                let mix = AVMutableAudioMix()
                mix.inputParameters = tracks.map { track in
                    let parameter = AVMutableAudioMixInputParameters(track: track)
                    parameter.setVolume(1.0 / Float(tracks.count), at: .zero)
                    return parameter
                }
                output.audioMix = mix
            }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: options.audioSampleRate,
                AVNumberOfChannelsKey: options.audioChannels, AVEncoderBitRateKey: options.audioBitRate]
            guard reader.canAdd(output), writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                throw VideoCompressionError.message("The selected audio conversion is unsupported.")
            }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw VideoCompressionError.message("Cannot add an audio encoder.") }
            writer.add(input)
            audioPipes.append((output, input))
        }

        if isCancelled { throw VideoCompressionError.cancelled }
        guard writer.startWriting() else { throw writer.error ?? VideoCompressionError.message("The output encoder could not start.") }
        // Cleanup only a destination that this writer successfully created.
        destination = outputURL
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? VideoCompressionError.message("The source reader could not start.") }

        let state = CompressionPumpState(duration: sourceInfo.durationSeconds, streams: audioPipes.count + 1, progress: progress)
        let group = DispatchGroup()
        let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
        group.enter()
        DispatchQueue(label: "quickrecorder.compress.video", qos: .userInitiated).async {
            defer { if writer.status == .writing { videoInput.markAsFinished() }; group.leave() }
            do {
                var pending: (CVPixelBuffer, CMTime)?
                var lastKept: Double?
                let interval = options.framesPerSecond.map { 1.0 / $0 }
                while !self.isCancelled && !state.hasError {
                    try self.waitUntilReady(videoInput, writer: writer, state: state)
                    guard let sample = videoOutput.copyNextSampleBuffer() else { break }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let seconds = CMTimeGetSeconds(pts)
                    guard seconds.isFinite else { continue }
                    state.update(seconds)
                    if let interval = interval, let last = lastKept, seconds - last + 0.000001 < interval { continue }
                    guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
                    if let previous = pending {
                        try self.append(pixel: previous.0, pts: previous.1, duration: CMTimeSubtract(pts, previous.1), to: videoInput, writer: writer)
                    }
                    let pixel = try autoreleasepool { try self.render(image, transform: videoTrack.preferredTransform,
                        width: width, height: height, options: options, context: context) }
                    pending = (pixel, pts)
                    lastKept = seconds
                }
                if !self.isCancelled && !state.hasError, let previous = pending {
                    try self.waitUntilReady(videoInput, writer: writer, state: state)
                    if !self.isCancelled && !state.hasError {
                        let tail = CMTimeSubtract(asset.duration, previous.1)
                        try self.append(pixel: previous.0, pts: previous.1, duration: tail, to: videoInput, writer: writer)
                    }
                }
            } catch { state.fail(error); reader.cancelReading() }
        }
        for (audioIndex, pipe) in audioPipes.enumerated() {
            let (output, input) = pipe
            group.enter()
            DispatchQueue(label: "quickrecorder.compress.audio.\(UUID().uuidString)", qos: .userInitiated).async {
                defer { if writer.status == .writing { input.markAsFinished() }; group.leave() }
                do {
                    while !self.isCancelled && !state.hasError {
                        try self.waitUntilReady(input, writer: writer, state: state)
                        guard let sample = output.copyNextSampleBuffer() else { break }
                        // Do not drop or retime audio when limiting the video cadence.
                        guard input.append(sample) else { throw writer.error ?? VideoCompressionError.message("An audio sample could not be written.") }
                        state.update(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), stream: audioIndex + 1)
                    }
                } catch { state.fail(error); reader.cancelReading() }
            }
        }
        group.wait()
        if isCancelled { reader.cancelReading(); writer.cancelWriting(); throw VideoCompressionError.cancelled }
        if let error = state.error { reader.cancelReading(); writer.cancelWriting(); throw error }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? VideoCompressionError.message("Source decoding failed.") }
        guard writer.status == .writing else { throw writer.error ?? VideoCompressionError.message("Encoding did not finish.") }
        writer.endSession(atSourceTime: asset.duration)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        if finished.wait(timeout: .now() + 60) == .timedOut {
            if writer.status == .writing { writer.cancelWriting() }
            throw VideoCompressionError.message("Finalizing the output timed out. The source file was kept.")
        }
        if isCancelled { throw VideoCompressionError.cancelled }
        guard writer.status == .completed else { throw writer.error ?? VideoCompressionError.message("The output file could not be finalized.") }
        let outputInfo = try VideoFileInspection.inspect(url: outputURL)
        guard outputInfo.bytes > 0, outputInfo.videoTrackCount == 1, outputInfo.audioTrackCount == audioGroups.count,
              abs(outputInfo.durationSeconds - sourceInfo.durationSeconds) < 0.25 else {
            throw VideoCompressionError.message("The output did not pass track/duration validation.")
        }
        let outputAudioTracks = outputInfo.tracks.filter { $0.mediaType == AVMediaType.audio.rawValue }
        for (group, track) in zip(audioGroups, outputAudioTracks) {
            let expectedStart = group.map { CMTimeGetSeconds($0.timeRange.start) }.min() ?? 0
            let expectedEnd = group.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRange)) }.max() ?? 0
            guard track.startSeconds <= expectedStart + 0.25,
                  track.startSeconds + track.durationSeconds >= min(expectedEnd, sourceInfo.durationSeconds) - 0.25 else {
                throw VideoCompressionError.message("An exported audio track is shorter than its source. The incomplete export was discarded.")
            }
        }
        progress(1)
        return VideoCompressionResult(source: sourceInfo, output: outputInfo, codec: options.codec, hardwareWasRequired: options.requireHardwareEncoder)
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter, state: CompressionPumpState) throws {
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            if isCancelled { throw VideoCompressionError.cancelled }
            if let error = state.error { throw error }
            guard writer.status == .writing else { throw writer.error ?? VideoCompressionError.message("The output encoder stopped.") }
            guard Date() < deadline else { throw VideoCompressionError.message("The output encoder made no progress for 30 seconds. The source file was kept.") }
            Thread.sleep(forTimeInterval: 0.003)
        }
        if isCancelled { throw VideoCompressionError.cancelled }
        if let error = state.error { throw error }
    }

    private func validate(_ options: VideoCompressionOptions) throws {
        guard (options.width == nil) == (options.height == nil) else { throw VideoCompressionError.message("Set both output dimensions, or keep both at source size.") }
        if let width = options.width, let height = options.height {
            guard (16...8192).contains(width), (16...8192).contains(height), width % 2 == 0, height % 2 == 0 else {
                throw VideoCompressionError.message("Dimensions must be even numbers from 16 to 8192 pixels.")
            }
        }
        if let fps = options.framesPerSecond, (!fps.isFinite || fps < 0.01 || fps > 240) { throw VideoCompressionError.message("FPS must be between 0.01 and 240, or keep the source cadence.") }
        guard (10_000...100_000_000).contains(options.videoBitRate) else { throw VideoCompressionError.message("Video bitrate must be between 10 and 100,000 kbps.") }
        if options.audioMode != .remove {
            guard [8000, 16000, 24000, 44100, 48000].contains(options.audioSampleRate), [1, 2].contains(options.audioChannels),
                  (16_000...320_000).contains(options.audioBitRate) else { throw VideoCompressionError.message("Choose a supported AAC sample rate, 1 or 2 channels, and 16–320 kbps.") }
        }
    }

    private func render(_ source: CVPixelBuffer, transform: CGAffineTransform, width: Int, height: Int,
                        options: VideoCompressionOptions, context: CIContext) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixel)
        guard status == kCVReturnSuccess, let pixel = pixel else { throw VideoCompressionError.message("Cannot allocate an output frame (\(status)).") }
        var image = CIImage(cvPixelBuffer: source).transformed(by: transform)
        let extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let sx = CGFloat(width) / extent.width
        let sy = CGFloat(height) / extent.height
        let xScale: CGFloat
        let yScale: CGFloat
        switch options.geometry {
        case .fit: xScale = min(sx, sy); yScale = xScale
        case .fill: xScale = max(sx, sy); yScale = xScale
        case .stretch: xScale = sx; yScale = sy
        }
        image = image.transformed(by: CGAffineTransform(scaleX: xScale, y: yScale))
            .transformed(by: CGAffineTransform(translationX: (CGFloat(width) - extent.width * xScale) / 2,
                                               y: (CGFloat(height) - extent.height * yScale) / 2))
        if options.grayscale { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        image = image.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        context.render(image, to: pixel, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        return pixel
    }

    private func append(pixel: CVPixelBuffer, pts: CMTime, duration: CMTime,
                        to input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        guard CMTimeGetSeconds(duration) > 0 else { return }
        var format: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
        guard status == noErr, let format = format else { throw VideoCompressionError.message("Cannot describe an output frame (\(status)).") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample = sample, input.append(sample) else {
            throw writer.error ?? VideoCompressionError.message("Cannot write an output frame (\(status)).")
        }
    }
}

private final class CompressionPumpState {
    private let lock = NSLock()
    private var storedError: Error?
    private var streamProgress: [Double]
    private var lastReport = Date.distantPast
    private let duration: Double
    private let progress: (Double) -> Void
    init(duration: Double, streams: Int, progress: @escaping (Double) -> Void) {
        self.duration = duration
        self.streamProgress = Array(repeating: 0, count: streams)
        self.progress = progress
    }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    var hasError: Bool { error != nil }
    func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; if storedError == nil { storedError = error } }
    func update(_ seconds: Double, stream: Int = 0) {
        guard seconds.isFinite else { return }
        lock.lock()
        streamProgress[stream] = max(streamProgress[stream], min(0.99, max(0, seconds / duration)))
        let shouldReport = Date().timeIntervalSince(lastReport) > 0.1
        let value = streamProgress.reduce(0, +) / Double(streamProgress.count)
        if shouldReport { lastReport = Date() }
        lock.unlock()
        if shouldReport { progress(value) }
    }
}
