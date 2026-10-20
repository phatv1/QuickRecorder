// Native offline export smoke test. Supply a disposable synthetic video containing audio.
// swiftc -swift-version 5 -parse-as-library QuickRecorder/VideoCompression.swift \
//   verification/VideoCompressionVerification.swift -o /tmp/qr-compression-verification
// /tmp/qr-compression-verification /path/to/synthetic.mp4 /path/to/output-folder
// Independently inspect output frame PTS and audio continuity with ffprobe/ffmpeg.
import Foundation
import AVFoundation
import CryptoKit

@main struct VideoCompressionVerification {
    static func fingerprint(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize()
    }

    static func run(source: URL, folder: URL, options: VideoCompressionOptions, cancel: Bool = false) throws -> VideoCompressionResult? {
        let compressor = VideoCompressor()
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<VideoCompressionResult, Error>?
        compressor.compress(sourceURL: source, destinationDirectory: folder, options: options,
            progress: { _ in if cancel { compressor.cancel() } }, completion: { result in outcome = result; done.signal() })
        guard done.wait(timeout: .now() + 120) == .success else {
            compressor.cancel()
            throw VideoCompressionError.message("Verification timed out.")
        }
        guard let outcome = outcome else { throw VideoCompressionError.message("No completion result.") }
        if cancel {
            if case .failure(let error) = outcome, case VideoCompressionError.cancelled = error { return nil }
            throw VideoCompressionError.message("Cancellation did not report cancellation: \(outcome)")
        }
        return try outcome.get()
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw VideoCompressionError.message("Usage: qr-compression-verification SOURCE_VIDEO OUTPUT_FOLDER")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originalHash = try fingerprint(source)
        let sourceInfo = try VideoFileInspection.inspect(url: source)
        guard sourceInfo.audioTrackCount > 0 else { throw VideoCompressionError.message("The fixture must contain audio to verify continuous audio export.") }

        let cases: [(Double?, VideoCompressionOptions.AudioMode, VideoCompressionOptions.Codec, VideoCompressionOptions.Container, VideoCompressionOptions.Geometry)] = [
            (0.1, .separate, .hevc, .mp4, .fit),
            (0.2, .separate, .h264, .mp4, .fit),
            (0.5, .mix, .hevc, .mp4, .fill),
            (0.2, .first, .h264, .mp4, .stretch),
            (0.2, .remove, .hevc, .mov, .fit),
            (nil, .separate, .h264, .mov, .fit)
        ]
        for (fps, mode, codec, container, geometry) in cases {
            var options = VideoCompressionOptions()
            options.width = 320
            options.height = 240
            options.framesPerSecond = fps
            options.codec = codec
            options.container = container
            options.audioMode = mode
            options.geometry = geometry
            options.grayscale = mode == .mix
            options.requireHardwareEncoder = true
            guard let result = try run(source: source, folder: folder, options: options) else { fatalError("Missing output") }
            let expectedAudio = mode == .remove ? 0 : mode == .separate ? sourceInfo.audioTrackCount : 1
            guard result.output.audioTrackCount == expectedAudio,
                  abs(result.output.durationSeconds - sourceInfo.durationSeconds) < 0.25,
                  result.output.width == 320, result.output.height == 240,
                  result.output.url != source,
                  try fingerprint(source) == originalHash else {
                throw VideoCompressionError.message("Export changed the source or failed duration/dimension/track validation.")
            }
            print("PASS fps=\(fps.map(String.init(describing:)) ?? "source") audio=\(mode.rawValue) codec=\(codec.rawValue) bytes=\(result.output.bytes) output=\(result.output.url.path)")
        }
        let beforeCancel = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        _ = try run(source: source, folder: folder, options: VideoCompressionOptions(), cancel: true)
        guard Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == beforeCancel,
              try fingerprint(source) == originalHash else {
            throw VideoCompressionError.message("Cancel left a partial export or changed the source.")
        }
        var invalid = VideoCompressionOptions()
        invalid.width = 319
        do {
            _ = try run(source: source, folder: folder, options: invalid)
            throw VideoCompressionError.message("Odd dimensions unexpectedly succeeded.")
        } catch VideoCompressionError.message(let message) where message.contains("even") { }
        print("PASS cancel cleans partial output; invalid dimensions fail; source SHA256 unchanged")
    }
}
