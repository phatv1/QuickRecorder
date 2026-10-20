import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics

@main
struct RecordingResourceVerification {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "RecordingResourceVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func frame(at seconds: Double, color: (UInt8, UInt8, UInt8) = (0, 0, 255),
                      tinyChange: Bool = false, width: Int = 640, height: Int = 360) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        try require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                       attributes as CFDictionary, &buffer) == kCVReturnSuccess, "Pixel buffer creation failed")
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * rowBytes + x * 4
                base[i] = color.0; base[i + 1] = color.1; base[i + 2] = color.2; base[i + 3] = 255
            }
        }
        if tinyChange { base[19 * rowBytes + 17 * 4 + 1] = 175 }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    static func pixel(_ sample: CMSampleBuffer, x: Int, y: Int) -> [UInt8] {
        let image = sample.imageBuffer!
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let index = y * CVPixelBufferGetBytesPerRow(image) + x * 4
        return [base[index], base[index + 1], base[index + 2], base[index + 3]]
    }

    static func main() throws {
        let suite = "QuickRecorder.ResourceVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(30, forKey: "frameRate")
        defaults.set(192, forKey: "audioQuality")
        let legacy = RecordingOptions(defaults: defaults)
        try legacy.validate()
        try require(legacy.frameRate == 30 && legacy.audioBitrateKbps == 192, "Legacy preferences were not preserved")
        try require(legacy.resolutionMode == "source" && !legacy.dropDuplicateFrames && !legacy.adaptiveFrameRate,
                    "New features must be opt-in")

        let fractional = RecordingOptions(values: ["frameRate": 0.2], defaults: defaults)
        try require(fractional.frameIntervalSeconds == 5, "Fractional FPS was truncated")
        for invalid in [Double.nan, Double.infinity, 0, -1, 241] {
            try require(!RecordingOptions(values: ["frameRate": invalid], defaults: defaults).validationErrors.isEmpty,
                        "Invalid FPS was accepted")
        }
        let budget = RecordingOptions(values: ["rateControl": "budget", "storageBudgetMBPerHour": 111.6,
                                                "audioBitrateKbps": 48, "recordWinSound": true, "recordMic": false], defaults: defaults)
        try require(budget.requestedVideoBitrateBps == 192_560, "Audio and container reserve were not subtracted from storage budget")
        let impossibleBudget = RecordingOptions(values: ["rateControl": "budget", "storageBudgetMBPerHour": 1], defaults: defaults)
        try require(!impossibleBudget.validationErrors.isEmpty, "Impossible audio/video budget was accepted")
        let invalidProfile = RecordingOptions(values: ["frameRate": 0], defaults: defaults)
        try require(!invalidProfile.validationErrors.isEmpty, "Bad settings unexpectedly valid")
        do {
            try RecordingOptions.apply(["frameRate": 0, "outputWidth": 100], defaults: defaults)
            throw NSError(domain: "Verification", code: 2)
        } catch { try require(defaults.integer(forKey: "frameRate") == 30, "Invalid settings were partially persisted") }
        try RecordingOptions.apply(["frameRate": 0.5, "videoBitrateKbps": 80], defaults: defaults)
        try RecordingOptions.saveProfile(name: "Remote profile", defaults: defaults)
        let profile = try RecordingOptions.profiles(defaults: defaults).first!
        defaults.set(12.0, forKey: "frameRate")
        try RecordingOptions.loadProfile(id: profile.id, defaults: defaults)
        try require(defaults.double(forKey: "frameRate") == 0.5, "Named profile did not round-trip fractional FPS")
        try RecordingOptions.deleteProfile(id: profile.id, defaults: defaults)
        try require(try RecordingOptions.profiles(defaults: defaults).isEmpty, "Named profile deletion failed")

        let source = CGSize(width: 2560, height: 1600)
        let proportional = RecordingOptions(values: ["resolutionMode": "longEdge", "maxLongEdge": 1280], defaults: defaults)
        let proportionalSize = try RecordingVideoProcessor.outputSize(sourceSize: source, options: proportional)
        try require(proportionalSize == CGSize(width: 1280, height: 800), "Aspect-preserving resolution is wrong")
        let fit = RecordingOptions(values: ["resolutionMode": "custom", "outputWidth": 320, "outputHeight": 240, "scalingMode": "fit"], defaults: defaults)
        let capture = try RecordingVideoProcessor.captureSize(sourceSize: CGSize(width: 1920, height: 1080), options: fit)
        try require(capture == CGSize(width: 320, height: 180), "Fit capture should scale before entering the app")
        let sample = try frame(at: 2)
        guard let fitted = RecordingVideoProcessor.prepare(sample: sample, options: fit, outputSize: CGSize(width: 320, height: 240)) else {
            throw NSError(domain: "Verification", code: 3, userInfo: [NSLocalizedDescriptionKey: "GPU fit render failed"])
        }
        try require(fitted.presentationTimeStamp == sample.presentationTimeStamp, "GPU processing changed the timeline")
        let bar = pixel(fitted, x: 160, y: 5), content = pixel(fitted, x: 160, y: 120)
        try require(bar[0] < 5 && bar[1] < 5 && bar[2] < 5 && content[2] > 200, "Fit did not preserve content and letterbox")
        let gray = RecordingOptions(values: ["grayscale": true], defaults: defaults)
        let graySample = RecordingVideoProcessor.prepare(sample: sample, options: gray, outputSize: CGSize(width: 640, height: 360))!
        let grayPixel = pixel(graySample, x: 300, y: 150)
        try require(abs(Int(grayPixel[0]) - Int(grayPixel[1])) < 3 && abs(Int(grayPixel[1]) - Int(grayPixel[2])) < 3,
                    "Grayscale output is not neutral")
        let copied = RecordingVideoProcessor.independentCopy(of: sample)!
        try require(copied.imageBuffer !== sample.imageBuffer && pixel(copied, x: 20, y: 20) == pixel(sample, x: 20, y: 20),
                    "Held-frame copy must release capture surface ownership")

        let policyOptions = RecordingOptions(values: ["frameRate": 1.0, "dropDuplicateFrames": true], defaults: defaults)
        let policy = RecordingFramePolicy(options: policyOptions)
        try require(policy.shouldEncode(try frame(at: 0)), "First frame was dropped")
        try require(!policy.shouldEncode(try frame(at: 0.25, tinyChange: true)), "Cadence limit was bypassed")
        try require(policy.shouldEncode(try frame(at: 1, tinyChange: true)), "A change before the cadence boundary was lost")
        try require(!policy.shouldEncode(try frame(at: 2, tinyChange: true)), "Identical frame was not deduplicated")
        try require(policy.shouldEncode(try frame(at: 3)), "A one-pixel change was missed by exact dedupe")
        let adaptiveOptions = RecordingOptions(values: ["adaptiveFrameRate": true, "adaptiveActiveFPS": 2.0,
                                                         "adaptiveIdleFPS": 0.2, "adaptiveIdleSeconds": 1.0], defaults: defaults)
        let adaptive = RecordingFramePolicy(options: adaptiveOptions)
        try require(adaptive.shouldEncode(try frame(at: 0)), "Adaptive first frame missing")
        try require(adaptive.shouldEncode(try frame(at: 0.5)), "Active cadence missing")
        try require(!adaptive.shouldEncode(try frame(at: 1)), "Idle cadence was not reduced")
        adaptive.noteActivity(at: CMTime(seconds: 2, preferredTimescale: 600_000))
        try require(adaptive.shouldEncode(try frame(at: 2)), "User activity did not wake the capture cadence")
        print("PASS: legacy settings, fractional FPS, validation, budgets, profiles, geometry, GPU rendering, exact dedupe and adaptive cadence")
    }
}
