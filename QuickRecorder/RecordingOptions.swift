import Foundation
import CoreFoundation
import AudioToolbox

/// A snapshot of recording preferences. Missing new preferences retain the old recorder behaviour.
struct RecordingOptions {
    let frameRate: Double
    let resolutionMode: String
    let outputWidth: Int
    let outputHeight: Int
    let targetHeight: Int
    let maxLongEdge: Int
    let resolutionScale: Double
    let scalingMode: String
    let allowUpscaling: Bool
    let rateControl: String
    let videoBitrateKbps: Double
    let encoderQuality: Double
    let peakBitrateKbps: Double
    let storageBudgetMBPerHour: Double
    let audioSampleRate: Int
    let audioChannels: Int
    let audioBitrateKbps: Int
    let audioBitrateMode: String
    let mixAudioLive: Bool
    let requireHardware: Bool
    let capturePixelFormat: String
    let captureQueueDepth: Int
    let dropDuplicateFrames: Bool
    let adaptiveFrameRate: Bool
    let adaptiveIdleFPS: Double
    let adaptiveActiveFPS: Double
    let adaptiveIdleSeconds: Double
    let keyFrameIntervalSeconds: Double
    let frameReordering: String
    let segmentDurationSeconds: Double
    let grayscale: Bool
    let encoderPriority: String
    let recordMicrophone: Bool
    let recordSystemAudio: Bool
    private let audioCodec: String
    private let videoCodec: String
    private let videoContainer: String
    private let hdrEnabled: Bool
    private let alphaEnabled: Bool
    private let readErrors: [String]

    static let advancedDefaults: [String: Any] = [
        "resolutionMode": "source", "outputWidth": 1280, "outputHeight": 720,
        "targetHeight": 720, "maxLongEdge": 1920, "resolutionScale": 1.0,
        "scalingMode": "fit", "allowUpscaling": false,
        "rateControl": "automatic", "videoBitrateKbps": 200.0, "encoderQuality": 0.5,
        "peakBitrateKbps": 0.0, "storageBudgetMBPerHour": 100.0,
        "audioSampleRate": 48000, "audioChannels": 2, "audioBitrateMode": "average",
        "mixAudioLive": false, "requireHardware": false,
        "capturePixelFormat": "automatic", "captureQueueDepth": 3,
        "dropDuplicateFrames": false, "adaptiveFrameRate": false,
        "adaptiveIdleFPS": 0.1, "adaptiveActiveFPS": 2.0, "adaptiveIdleSeconds": 5.0,
        "keyFrameIntervalSeconds": 0.0, "frameReordering": "automatic",
        "segmentDurationSeconds": 0.0, "grayscale": false, "encoderPriority": "balanced"
    ]

    init(defaults: UserDefaults = .standard) {
        self.init(values: [:], defaults: defaults)
    }

    /// Overlay values without writing preferences; useful for transactional profile/script validation.
    init(values: [String: Any], defaults: UserDefaults = .standard) {
        let reader = RecordingPreferenceReader { values[$0] ?? defaults.object(forKey: $0) }
        frameRate = reader.double("frameRate", fallback: 60)
        resolutionMode = reader.string("resolutionMode", fallback: "source")
        outputWidth = reader.integer("outputWidth", fallback: 1280)
        outputHeight = reader.integer("outputHeight", fallback: 720)
        targetHeight = reader.integer("targetHeight", fallback: 720)
        maxLongEdge = reader.integer("maxLongEdge", fallback: 1920)
        resolutionScale = reader.double("resolutionScale", fallback: 1)
        scalingMode = reader.string("scalingMode", fallback: "fit")
        allowUpscaling = reader.boolean("allowUpscaling", fallback: false)
        rateControl = reader.string("rateControl", fallback: "automatic")
        videoBitrateKbps = reader.double("videoBitrateKbps", fallback: 200)
        encoderQuality = reader.double("encoderQuality", fallback: 0.5)
        peakBitrateKbps = reader.double("peakBitrateKbps", fallback: 0)
        storageBudgetMBPerHour = reader.double("storageBudgetMBPerHour", fallback: 100)
        audioSampleRate = reader.integer("audioSampleRate", fallback: 48000)
        audioChannels = reader.integer("audioChannels", fallback: 2)
        audioBitrateKbps = reader.integer("audioBitrateKbps", fallback: reader.integer("audioQuality", fallback: 256))
        audioBitrateMode = reader.string("audioBitrateMode", fallback: "average")
        mixAudioLive = reader.boolean("mixAudioLive", fallback: false)
        requireHardware = reader.boolean("requireHardware", fallback: false)
        capturePixelFormat = reader.string("capturePixelFormat", fallback: "automatic")
        captureQueueDepth = reader.integer("captureQueueDepth", fallback: 3)
        dropDuplicateFrames = reader.boolean("dropDuplicateFrames", fallback: false)
        adaptiveFrameRate = reader.boolean("adaptiveFrameRate", fallback: false)
        adaptiveIdleFPS = reader.double("adaptiveIdleFPS", fallback: 0.1)
        adaptiveActiveFPS = reader.double("adaptiveActiveFPS", fallback: 2)
        adaptiveIdleSeconds = reader.double("adaptiveIdleSeconds", fallback: 5)
        keyFrameIntervalSeconds = reader.double("keyFrameIntervalSeconds", fallback: 0)
        frameReordering = reader.string("frameReordering", fallback: "automatic")
        segmentDurationSeconds = reader.double("segmentDurationSeconds", fallback: 0)
        grayscale = reader.boolean("grayscale", fallback: false)
        encoderPriority = reader.string("encoderPriority", fallback: "balanced")
        recordMicrophone = reader.boolean("recordMic", fallback: false)
        recordSystemAudio = reader.boolean("recordWinSound", fallback: true)
        videoCodec = reader.string("encoder", fallback: "h264")
        videoContainer = reader.string("videoFormat", fallback: "mp4")
        audioCodec = reader.string("audioFormat", fallback: "aac")
        hdrEnabled = reader.boolean("recordHDR", fallback: false)
        alphaEnabled = reader.boolean("withAlpha", fallback: false)
        readErrors = reader.errors
    }

    var frameIntervalSeconds: Double { 1 / frameRate }

    var audioTrackCount: Int {
        let sources = (recordMicrophone ? 1 : 0) + (recordSystemAudio ? 1 : 0)
        return mixAudioLive && sources > 0 ? 1 : sources
    }

    /// A target, never a promise about actual encoded size. Nil retains automatic/quality mode.
    var requestedVideoBitrateBps: Int? {
        let value: Double
        switch rateControl {
        case "bitrate": value = videoBitrateKbps * 1000
        case "budget": value = storageBudgetMBPerHour * 8_000_000 / 3600 * 0.97 - Double(audioBitrateKbps) * Double(audioTrackCount) * 1000
        default: return nil
        }
        guard value.isFinite, value >= 1, value < Double(Int.max) else { return nil }
        if rateControl == "budget" && value < 1000 { return nil }
        return Int(value.rounded())
    }

    var estimatedMBPerHour: Double? {
        guard let video = requestedVideoBitrateBps else { return nil }
        return (Double(video) / 1000 + Double(audioBitrateKbps) * Double(audioTrackCount)) * 0.45
    }

    var validationErrors: [String] {
        var errors = readErrors
        func member(_ value: String, _ choices: [String], _ label: String) {
            if !choices.contains(value) { errors.append("\(label): choose \(choices.joined(separator: ", ")).") }
        }
        func positive(_ value: Double, _ label: String) {
            if !value.isFinite || value <= 0 { errors.append("\(label) must be a finite positive number.") }
        }
        if !frameRate.isFinite || !(0.01...240).contains(frameRate) { errors.append("Frame rate must be between 0.01 and 240 FPS.") }
        member(resolutionMode, ["source", "height", "longEdge", "scale", "custom"], "Resolution mode")
        member(scalingMode, ["fit", "fill", "stretch"], "Scaling mode")
        for (key, value) in [("Output width", outputWidth), ("Output height", outputHeight), ("Target height", targetHeight), ("Long edge", maxLongEdge)] {
            if value < 2 || value > 32768 { errors.append("\(key) must be between 2 and 32768 pixels; encoder limits may be lower.") }
        }
        positive(resolutionScale, "Resolution scale")
        member(rateControl, ["automatic", "bitrate", "quality", "budget"], "Rate control")
        positive(videoBitrateKbps, "Video bitrate")
        if videoBitrateKbps >= Double(Int.max) / 1000 { errors.append("Video bitrate is too large.") }
        if !encoderQuality.isFinite || !(0...1).contains(encoderQuality) { errors.append("Encoder quality must be between 0 and 1.") }
        if !peakBitrateKbps.isFinite || peakBitrateKbps < 0 || peakBitrateKbps >= Double(Int.max) / 1000 { errors.append("Peak bitrate must be finite, nonnegative and within encoder limits.") }
        positive(storageBudgetMBPerHour, "Storage budget")
        if ![8000, 16000, 24000, 48000].contains(audioSampleRate) { errors.append("Capture audio sample rate must be 8000, 16000, 24000 or 48000 Hz.") }
        if ![1, 2].contains(audioChannels) { errors.append("Audio channels must be 1 or 2.") }
        if audioBitrateKbps < 1 || audioBitrateKbps > 100000 { errors.append("Audio bitrate must be a positive kbps value within encoder limits.") }
        member(audioBitrateMode, ["average", "variable", "constant"], "Audio bitrate mode")
        // mp3 and Opus-in-MP4 are written as AAC (SCContext.updateAudioSettings).
        if audioTrackCount > 0, audioCodec == "aac" || audioCodec == "mp3" || (audioCodec == "opus" && videoContainer == "mp4"),
           let range = aacEncodeBitrateRange(sampleRate: audioSampleRate, channels: audioChannels),
           !range.contains(audioBitrateKbps * 1000) {
            errors.append("AAC at \(audioSampleRate) Hz \(audioChannels == 1 ? "mono" : "stereo") supports \(range.lowerBound / 1000)–\(range.upperBound / 1000) kbps; \(audioBitrateKbps) kbps would fail when audio is written.")
        }
        member(capturePixelFormat, ["automatic", "bgra", "nv12"], "Capture pixel format")
        if !(3...8).contains(captureQueueDepth) { errors.append("Capture queue depth must be between 3 and 8.") }
        for (label, value) in [("Idle FPS", adaptiveIdleFPS), ("Active FPS", adaptiveActiveFPS)] {
            if !value.isFinite || !(0.01...240).contains(value) { errors.append("\(label) must be between 0.01 and 240 FPS.") }
        }
        if adaptiveIdleFPS > adaptiveActiveFPS { errors.append("Idle FPS must not exceed active FPS.") }
        positive(adaptiveIdleSeconds, "Idle delay")
        for (label, value) in [("Keyframe interval", keyFrameIntervalSeconds), ("Segment duration", segmentDurationSeconds)] {
            if !value.isFinite || value < 0 { errors.append("\(label) must be finite and nonnegative; 0 selects automatic/off.") }
        }
        member(frameReordering, ["automatic", "enabled", "disabled"], "Frame reordering")
        member(encoderPriority, ["balanced", "speed"], "Encoder priority")
        member(videoCodec, ["h264", "h265"], "Video codec")
        member(videoContainer, ["mp4", "mov"], "Video container")
        member(audioCodec, ["aac", "mp3", "alac", "flac", "opus"], "Audio codec")
        if rateControl == "bitrate" && requestedVideoBitrateBps == nil { errors.append("Video target bitrate must be representable as at least 1 bit per second.") }
        if rateControl == "budget" && requestedVideoBitrateBps == nil { errors.append("Storage budget must leave at least 1 kbps for video after enabled audio tracks and a 3% container reserve.") }
        if rateControl == "budget", audioTrackCount > 0, ["alac", "flac"].contains(audioCodec) { errors.append("A total storage budget requires lossy audio or audio disabled; lossless audio has no fixed target bitrate.") }
        if segmentDurationSeconds > 0 && recordMicrophone && recordSystemAudio && !mixAudioLive { errors.append("Segmenting microphone and system audio together requires live audio mixing to keep segment boundaries continuous.") }
        if alphaEnabled && (videoCodec != "h265" || videoContainer != "mov") { errors.append("Alpha requires HEVC and MOV.") }
        if alphaEnabled && capturePixelFormat == "nv12" { errors.append("NV12 capture cannot preserve an alpha channel; choose automatic or BGRA.") }
        if alphaEnabled && hdrEnabled { errors.append("HDR and alpha cannot be enabled together.") }
        if hdrEnabled && capturePixelFormat == "nv12" { errors.append("8-bit NV12 capture is unavailable for HDR; choose automatic.") }
        if peakBitrateKbps > 0, let bitrate = requestedVideoBitrateBps, peakBitrateKbps * 1000 < Double(bitrate) { errors.append("Peak video bitrate must be at least the requested average bitrate.") }
        return errors
    }

    func validate() throws {
        if !validationErrors.isEmpty { throw RecordingOptionsError.invalid(validationErrors) }
    }

    /// Returns an even canvas, preserving source aspect except in custom-canvas mode.
    /// The caller applies fit/fill/stretch inside that canvas and checks codec capabilities.
    func outputSize(sourceWidth: Int, sourceHeight: Int) throws -> (width: Int, height: Int) {
        try validate()
        guard sourceWidth > 0, sourceHeight > 0 else { throw RecordingOptionsError.invalid(["Source dimensions must be positive."]) }
        let sourceW = Double(sourceWidth), sourceH = Double(sourceHeight)
        var w = sourceW, h = sourceH
        switch resolutionMode {
        case "height": h = Double(targetHeight); w = h * sourceW / sourceH
        case "longEdge": let scale = Double(maxLongEdge) / max(sourceW, sourceH); w *= scale; h *= scale
        case "scale": w *= resolutionScale; h *= resolutionScale
        case "custom": w = Double(outputWidth); h = Double(outputHeight)
        default: break
        }
        // A custom canvas is intentional. The fit/fill renderer controls whether its content is upscaled.
        if !allowUpscaling && resolutionMode != "custom" {
            let cap = min(1, min(sourceW / w, sourceH / h)); w *= cap; h *= cap
        }
        guard w.isFinite, h.isFinite, w >= 2, h >= 2, w <= 32768, h <= 32768 else {
            throw RecordingOptionsError.invalid(["Effective dimensions must be between 2 and 32768 pixels; reduce the requested size or scale."])
        }
        return (max(2, Int(w.rounded(.down)) / 2 * 2), max(2, Int(h.rounded(.down)) / 2 * 2))
    }

    static func fpsDescription(_ fps: Double) -> String {
        guard fps.isFinite, fps > 0 else { return "Invalid FPS" }
        let number = String(format: "%.4g", fps)
        if fps < 1 { return "\(number) FPS · 1 frame every \(String(format: "%.4g", 1 / fps)) s" }
        return "\(number) FPS"
    }

    static func apply(_ values: [String: Any], defaults: UserDefaults = .standard) throws {
        try RecordingOptions(values: values, defaults: defaults).validate()
        for (key, value) in values { defaults.set(value, forKey: key) }
    }
}

enum RecordingOptionsError: LocalizedError {
    case invalid([String])
    case profile(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let messages): return messages.joined(separator: "\n")
        case .profile(let message): return message
        }
    }
}

private final class RecordingPreferenceReader {
    let value: (String) -> Any?
    var errors: [String] = []
    init(value: @escaping (String) -> Any?) { self.value = value }
    func double(_ key: String, fallback: Double) -> Double {
        guard let raw = value(key) else { return fallback }
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        errors.append("\(key) must be numeric."); return fallback
    }
    func integer(_ key: String, fallback: Int) -> Int {
        guard let raw = value(key) else { return fallback }
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
           n.doubleValue.rounded() == n.doubleValue, n.doubleValue > Double(Int.min), n.doubleValue < Double(Int.max) { return n.intValue }
        errors.append("\(key) must be an integer."); return fallback
    }
    func string(_ key: String, fallback: String) -> String {
        guard let raw = value(key) else { return fallback }
        if let s = raw as? String { return s }
        errors.append("\(key) must be text."); return fallback
    }
    func boolean(_ key: String, fallback: Bool) -> Bool {
        guard let raw = value(key) else { return fallback }
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        errors.append("\(key) must be true or false."); return fallback
    }
}

enum RecordingPreset: String, CaseIterable, Identifiable {
    case original, minimal144p, minimal240p, observation, balanced, detail, remoteWatch
    var id: String { rawValue }
    var name: String {
        switch self {
        case .original: return "Original recorder defaults"
        case .minimal144p: return "144p · 0.1 FPS · layout only"
        case .minimal240p: return "240p · 0.2 FPS · layout only"
        case .observation: return "Observe · 0.2 FPS · 1600 px"
        case .balanced: return "Balanced · 0.5 FPS · 1920 px"
        case .detail: return "Detail · 1 FPS · 1920 px"
        case .remoteWatch: return "Remote Watch · Lean · 0.5–1 FPS · 0.75×"
        }
    }
    var settings: [String: Any] {
        var values = RecordingOptions.advancedDefaults
        values.merge(["frameRate": 60.0, "highRes": 2, "videoQuality": 1.0,
                      "videoFormat": "mp4", "encoder": "h264", "recordHDR": false,
                      "withAlpha": false, "audioFormat": "aac", "audioQuality": 256,
                      "audioBitrateKbps": 256]) { _, new in new }
        guard self != .original else { return values }
        values.merge(["encoder": "h265", "highRes": 1, "rateControl": "bitrate",
                      "audioSampleRate": 24000, "audioChannels": 1, "audioBitrateKbps": 32,
                      "keyFrameIntervalSeconds": 20.0]) { _, new in new }
        switch self {
        case .minimal144p: values.merge(["resolutionMode": "height", "targetHeight": 144, "frameRate": 0.1, "videoBitrateKbps": 16.0]) { _, new in new }
        case .minimal240p: values.merge(["resolutionMode": "height", "targetHeight": 240, "frameRate": 0.2, "videoBitrateKbps": 32.0]) { _, new in new }
        case .observation: values.merge(["resolutionMode": "longEdge", "maxLongEdge": 1600, "frameRate": 0.2, "videoBitrateKbps": 80.0]) { _, new in new }
        case .balanced: values.merge(["resolutionMode": "longEdge", "frameRate": 0.5, "videoBitrateKbps": 200.0, "audioBitrateKbps": 48]) { _, new in new }
        case .detail: values.merge(["resolutionMode": "longEdge", "frameRate": 1.0, "videoBitrateKbps": 350.0, "audioSampleRate": 48000, "audioBitrateKbps": 64]) { _, new in new }
        // Tuned for remote focus review: readable text, clear speech, ~50 MB/hour; cursor kept as an attention signal.
        case .remoteWatch: values.merge(["resolutionMode": "scale", "resolutionScale": 0.75, "frameRate": 0.5,
                                         "videoBitrateKbps": 100.0, "peakBitrateKbps": 800.0,
                                         "audioSampleRate": 16000, "audioBitrateKbps": 16, "audioBitrateMode": "variable",
                                         "recordWinSound": true, "recordMic": false, "showMouse": true, "highlightMouse": false,
                                         "requireHardware": true, "keyFrameIntervalSeconds": 60.0, "capturePixelFormat": "nv12",
                                         "dropDuplicateFrames": true, "adaptiveFrameRate": true,
                                         "adaptiveIdleFPS": 0.5, "adaptiveActiveFPS": 1.0, "adaptiveIdleSeconds": 5.0]) { _, new in new }
        case .original: break
        }
        return values
    }
}

struct RecordingProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    let settingsData: Data
}

extension RecordingOptions {
    private static var profileKey: String { "recordingNamedProfiles" }
    static var profileSettingKeys: [String] {
        Array(advancedDefaults.keys) + ["frameRate", "audioBitrateKbps", "encoder", "videoFormat", "audioFormat", "audioQuality", "videoQuality", "highRes", "recordHDR", "withAlpha", "recordMic", "recordWinSound", "enableAEC", "AECLevel", "micDevice", "remuxAudio", "background", "showMouse", "highlightMouse", "includeMenuBar", "hideDesktopFiles", "hideSelf"]
    }
    static func settingsSnapshot(defaults: UserDefaults = .standard) -> [String: Any] {
        var snapshot = advancedDefaults
        snapshot.merge(["frameRate": 60.0, "encoder": "h264", "videoFormat": "mp4", "audioFormat": "aac", "audioQuality": 256, "videoQuality": 1.0, "highRes": 2, "recordHDR": false, "withAlpha": false, "recordMic": false, "recordWinSound": true, "enableAEC": false, "AECLevel": "mid", "micDevice": "default", "remuxAudio": true, "background": "wallpaper", "showMouse": true, "highlightMouse": false, "includeMenuBar": true, "hideDesktopFiles": false, "hideSelf": true]) { _, new in new }
        for key in profileSettingKeys { if let value = defaults.object(forKey: key) { snapshot[key] = value } }
        snapshot["audioBitrateKbps"] = RecordingOptions(defaults: defaults).audioBitrateKbps
        return snapshot
    }
    static func profiles(defaults: UserDefaults = .standard) throws -> [RecordingProfile] {
        guard let data = defaults.data(forKey: profileKey) else { return [] }
        return try JSONDecoder().decode([RecordingProfile].self, from: data)
    }
    static func saveProfile(name: String, defaults: UserDefaults = .standard) throws {
        try RecordingOptions(defaults: defaults).validate()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw RecordingOptionsError.profile("Enter a profile name.") }
        var saved = try profiles(defaults: defaults)
        guard !saved.contains(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) else { throw RecordingOptionsError.profile("A profile with that name already exists. Choose another name or delete the saved profile first.") }
        let snapshot = settingsSnapshot(defaults: defaults)
        let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
        saved.append(RecordingProfile(id: UUID(), name: cleanName, settingsData: data))
        defaults.set(try JSONEncoder().encode(saved), forKey: profileKey)
    }
    static func loadProfile(id: UUID, defaults: UserDefaults = .standard) throws {
        guard let profile = try profiles(defaults: defaults).first(where: { $0.id == id }) else { throw RecordingOptionsError.profile("Profile not found.") }
        guard let values = try PropertyListSerialization.propertyList(from: profile.settingsData, options: [], format: nil) as? [String: Any] else { throw RecordingOptionsError.profile("Invalid recording profile.") }
        let allowed = values.filter { profileSettingKeys.contains($0.key) }
        try apply(allowed, defaults: defaults)
    }
    static func deleteProfile(id: UUID, defaults: UserDefaults = .standard) throws {
        let saved = try profiles(defaults: defaults).filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(saved), forKey: profileKey)
    }
}

/// Bitrates (bps) the system AAC encoder accepts for this format; nil if it can't be queried.
func aacEncodeBitrateRange(sampleRate: Int, channels: Int) -> ClosedRange<Int>? {
    let ch = UInt32(channels)
    var input = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * ch, mFramesPerPacket: 1,
        mBytesPerFrame: 4 * ch, mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
    var output = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
        mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: ch, mBitsPerChannel: 0, mReserved: 0)
    var converter: AudioConverterRef?
    guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
    defer { AudioConverterDispose(converter) }
    var size: UInt32 = 0
    guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr, size > 0 else { return nil }
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr else { return nil }
    let valid = ranges.prefix(Int(size) / MemoryLayout<AudioValueRange>.size).filter { $0.mMaximum > 0 }
    guard let low = valid.map(\.mMinimum).min(), let high = valid.map(\.mMaximum).max() else { return nil }
    return Int(low)...Int(high)
}
