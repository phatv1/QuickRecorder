import SwiftUI
import AVFoundation
import VideoToolbox

/// Draft edits are committed together, so a partially typed number never changes a live recorder.
struct RecordingOptionsView: View {
    @State private var values = RecordingOptions.settingsSnapshot()
    @State private var profiles: [RecordingProfile] = []
    @State private var selectedProfile = ""
    @State private var profileName = ""
    @State private var status = ""
    @State private var errorMessage = ""
    @State private var recording = SCContext.isRecordingBusy

    private static let integerKeys: Set<String> = ["outputWidth", "outputHeight", "targetHeight", "maxLongEdge", "audioSampleRate", "audioChannels", "audioBitrateKbps", "captureQueueDepth", "highRes", "audioQuality"]
    private static let doubleKeys: Set<String> = ["frameRate", "resolutionScale", "videoBitrateKbps", "encoderQuality", "peakBitrateKbps", "storageBudgetMBPerHour", "adaptiveIdleFPS", "adaptiveActiveFPS", "adaptiveIdleSeconds", "keyFrameIntervalSeconds", "segmentDurationSeconds", "videoQuality"]

    private var parsedValues: [String: Any] {
        var parsed = values
        for key in Self.integerKeys {
            if let text = values[key] as? String, let number = Int(text) { parsed[key] = number }
        }
        for key in Self.doubleKeys {
            if let text = values[key] as? String, let number = Double(text) { parsed[key] = number }
        }
        return parsed
    }
    private var options: RecordingOptions { RecordingOptions(values: parsedValues) }
    private var errors: [String] { options.validationErrors + combinationErrors }
    private var combinationErrors: [String] {
        var errors: [String] = []
        if boolValue("withAlpha") && (stringValue("encoder") != "h265" || stringValue("videoFormat") != "mov") {
            errors.append("Alpha requires HEVC and MOV. Choose that combination or turn alpha off.")
        }
        if boolValue("recordHDR") && stringValue("encoder") != "h265" { errors.append("HDR requires HEVC.") }
        if boolValue("recordHDR") && stringValue("capturePixelFormat") == "nv12" { errors.append("8-bit NV12 is unavailable for HDR; choose automatic.") }
        if stringValue("videoFormat") == "mp4" && stringValue("audioFormat") != "aac" { errors.append("For video MP4, select AAC audio. Other audio formats remain available for audio-only recordings in Output settings.") }
        return errors
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advanced Recording").font(.title2).bold()
                    Text("Edit a profile, then apply it before recording.").foregroundColor(.secondary)
                }
                Spacer()
                Button("Compress a video…") { VideoCompressionView.show() }
                    .disabled(recording)
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profilesSection
                    videoSection
                    resolutionSection
                    audioSection
                    encoderSection
                    captureSection
                    if !errors.isEmpty {
                        GroupBox(label: Text("Fix these settings")) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(errors.enumerated()), id: \.offset) { _, message in Text(message).foregroundColor(.red) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    if !status.isEmpty { Text(status).foregroundColor(.secondary) }
                }.padding().disabled(recording)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Apply and record display trial") {
                        guard !SCContext.isRecordingBusy, errors.isEmpty else { return }
                        errorMessage = ""
                        apply()
                        if errorMessage.isEmpty { RecordingTrial.start() }
                    }.disabled(recording || !errors.isEmpty)
                    note(trialDescription)
                }
                HStack {
                    if recording { Text("Recording or finalization is active. Settings are locked until it finishes.").font(.caption).foregroundColor(.secondary) }
                    Spacer()
                    Button("Reload saved settings") { reload() }.disabled(recording)
                    Button("Apply settings") { apply() }.keyboardShortcut(.defaultAction)
                        .disabled(recording || !errors.isEmpty)
                }
            }.padding()
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 620, idealHeight: 800)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { reloadProfiles() }
        .onReceive(updateTimer) { _ in
            let busy = SCContext.isRecordingBusy
            if recording != busy { recording = busy }
        }
        .alert("Recording settings", isPresented: Binding(get: { !errorMessage.isEmpty }, set: { if !$0 { errorMessage = "" } })) {
            Button("OK", role: .cancel) { errorMessage = "" }
        } message: { Text(errorMessage) }
    }

    private var profilesSection: some View {
        section("Presets and saved profiles") {
            HStack {
                Menu("Load a preset") {
                    ForEach(RecordingPreset.allCases) { preset in
                        Button(preset.name) {
                            values.merge(preset.settings) { _, new in new }
                            status = "Loaded \(preset.name). Apply settings to use it. Low presets trade text readability for size."
                        }
                    }
                }
                Spacer()
                Text("144p/240p presets show layout; small text may be unreadable.").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Picker("Saved profile", selection: $selectedProfile) {
                    Text("Choose a profile").tag("")
                    ForEach(profiles) { Text($0.name).tag($0.id.uuidString) }
                }
                Button("Load") { loadProfile() }.disabled(selectedProfile.isEmpty)
                Button("Delete") { deleteProfile() }.disabled(selectedProfile.isEmpty)
            }
            HStack {
                TextField("New profile name", text: $profileName)
                Button("Save current profile") { saveProfile() }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !errors.isEmpty)
            }
            note("Profiles include video/audio and capture choices, without the output folder. Loading replaces saved settings; draft edits are not saved automatically.")
        }
    }

    private var videoSection: some View {
        section("Video and storage") {
            picker("Container", "videoFormat", [("MP4", "mp4"), ("MOV", "mov")])
            picker("Video codec", "encoder", [("H.264", "h264"), ("HEVC / H.265", "h265")])
            note(hardwareDescription)
            number("Frame rate", "frameRate", "FPS · 0.01–240")
            note(RecordingOptions.fpsDescription(options.frameRate))
            picker("Rate control", "rateControl", [("Automatic (existing quality setting)", "automatic"), ("Target bitrate", "bitrate"), ("Quality (estimated bitrate)", "quality"), ("Storage budget", "budget")])
            switch stringValue("rateControl") {
            case "automatic":
                picker("Automatic quality", "videoQuality", numericChoices: [("Low", 0.3), ("Medium", 0.7), ("High", 1)])
            case "bitrate": number("Video target bitrate", "videoBitrateKbps", "kbps")
            case "quality": number("Estimated encoder quality", "encoderQuality", "0–1")
            case "budget": number("Storage target", "storageBudgetMBPerHour", "MB / hour, including enabled audio")
            default: EmptyView()
            }
            number("Peak video bitrate", "peakBitrateKbps", "kbps · 0 = no extra limit")
            if let size = options.estimatedMBPerHour {
                note(String(format: "Target budget: %.2f MB/hour, %.3f GB/8 hours. Container overhead and temporary files are extra.", size, size * 8 / 1000))
            }
            if stringValue("rateControl") == "budget" { note("Storage-budget mode reserves 3% for container overhead. It remains an estimate, not a hard file-size cap.") }
            note("Targets are not hard size guarantees. Quality estimates a bitrate, not CRF or constant visual quality. Unsupported encoder settings produce an error when recording starts.")
        }
    }

    private var resolutionSection: some View {
        section("Output size") {
            picker("Size mode", "resolutionMode", [("Source size", "source"), ("Target height", "height"), ("Maximum long edge", "longEdge"), ("Scale", "scale"), ("Custom width × height", "custom")])
            picker("Source detail", "highRes", numericChoices: [("Normal (1×)", 1), ("Retina (automatic)", 2)])
            switch stringValue("resolutionMode") {
            case "height": number("Target height", "targetHeight", "pixels")
            case "longEdge": number("Maximum long edge", "maxLongEdge", "pixels")
            case "scale": number("Scale", "resolutionScale", "× source")
            case "custom":
                number("Canvas width", "outputWidth", "pixels")
                number("Canvas height", "outputHeight", "pixels")
            default: EmptyView()
            }
            picker("Canvas scaling", "scalingMode", [("Fit — keep all content, add borders", "fit"), ("Fill — crop outside canvas", "fill"), ("Stretch — change content shape", "stretch")])
            toggle("Allow content upscaling", "allowUpscaling")
            note(sizeDescription)
            note("A custom canvas does not change your display resolution. Odd dimensions are rounded down to even pixels. Encoder dimension limits are checked for the selected source.")
            note("When content upscaling is off, a larger custom canvas can contain borders even with Fill or Stretch.")
        }
    }

    private var audioSection: some View {
        section("Continuous audio") {
            toggle("Record system audio", "recordWinSound")
            toggle("Record microphone", "recordMic")
            picker("Audio codec in video", "audioFormat", stringValue("videoFormat") == "mp4" ? [("AAC", "aac")] : [("AAC", "aac"), ("Apple Lossless", "alac"), ("FLAC (check encoder support)", "flac"), ("Opus (check encoder support)", "opus")])
            picker("Capture sample rate", "audioSampleRate", numericChoices: [("8 kHz", 8000), ("16 kHz", 16000), ("24 kHz", 24000), ("48 kHz", 48000)])
            picker("Channels", "audioChannels", numericChoices: [("Mono", 1), ("Stereo", 2)])
            number("Audio target bitrate", "audioBitrateKbps", "kbps per encoded track").disabled(["alac", "flac"].contains(stringValue("audioFormat")))
            picker("Audio bitrate mode", "audioBitrateMode", [("Average", "average"), ("Variable", "variable"), ("Constant", "constant")]).disabled(["alac", "flac"].contains(stringValue("audioFormat")))
            toggle("Mix system audio and microphone before encoding", "mixAudioLive")
            toggle("Mix microphone into the final main track after recording", "remuxAudio")
            toggle("Acoustic echo cancellation", "enableAEC")
            note("Audio runs continuously regardless of video FPS. Live mixing creates one audio track; separate tracks use more storage and preserve each source. Lossless formats do not use a bitrate target. Sample rate and bitrate support depend on the audio encoder.")
        }
    }

    private var encoderSection: some View {
        section("Encoder options") {
            toggle("Require a hardware video encoder", "requireHardware")
            picker("Encoder priority", "encoderPriority", [("Balanced", "balanced"), ("Speed", "speed")])
            number("Maximum keyframe interval", "keyFrameIntervalSeconds", "seconds · 0 = automatic")
            picker("Frame reordering", "frameReordering", [("Automatic", "automatic"), ("Enabled", "enabled"), ("Disabled", "disabled")])
            number("Segment duration", "segmentDurationSeconds", "seconds · 0 = one file")
            toggle("Grayscale output", "grayscale")
            if #available(macOS 15, *) { toggle("HDR recording", "recordHDR") }
            toggle("Alpha channel (HEVC + MOV)", "withAlpha")
            note("Longer GOPs may reduce size and make seeking slower. Reordering can add latency/buffers. Segments limit the open file duration, not bitrate. Encoder support is validated on the actual recording configuration.")
        }
    }

    private var captureSection: some View {
        section("Capture and changes") {
            picker("Capture pixel format", "capturePixelFormat", [("Automatic / existing behaviour", "automatic"), ("BGRA", "bgra"), ("NV12 8-bit SDR", "nv12")])
            number("Capture queue depth", "captureQueueDepth", "frames · 3–8")
            toggle("Skip unchanged video frames", "dropDuplicateFrames")
            toggle("Adaptive frame rate", "adaptiveFrameRate")
            number("Idle frame rate", "adaptiveIdleFPS", "FPS")
            number("Active frame rate", "adaptiveActiveFPS", "FPS")
            number("Idle delay", "adaptiveIdleSeconds", "seconds")
            toggle("Show cursor in capture", "showMouse")
            toggle("Highlight mouse cursor", "highlightMouse")
            note("Adaptive capture uses visual changes and mouse activity. Sparse frames can miss short actions. NV12 and smaller queues mainly reduce capture memory/work; encoded file size still depends on codec and content.")
        }
    }

    private var hardwareDescription: String {
        "Codec, output dimensions and hardware support are validated for the selected recording source. Enable Require hardware to prevent a software encoder fallback."
    }
    private var trialDescription: String {
        let fps = options.adaptiveFrameRate ? options.adaptiveIdleFPS : options.frameRate
        let duration = fps.isFinite && fps > 0 ? max(30, 2 / fps) : 30
        return String(format: "Records a display for %.0f seconds with enabled audio continuous. You can stop normally.", duration)
    }
    private var sizeDescription: String {
        guard let screen = NSScreen.main else { return "Select a source to check effective output dimensions." }
        let scale = (parsedValues["highRes"] as? NSNumber)?.intValue == 2 ? screen.backingScaleFactor : 1
        guard let size = try? options.outputSize(sourceWidth: Int(screen.frame.width * scale), sourceHeight: Int(screen.frame.height * scale)) else { return "Fix the dimensions to preview the effective canvas." }
        return "Main-display size preview: \(size.width) × \(size.height) px. A selected crop/window may produce a different size."
    }

    private func stringValue(_ key: String) -> String { values[key] as? String ?? "" }
    private func boolValue(_ key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: {
            if let text = values[key] as? String { return text }
            if let number = values[key] as? NSNumber { return String(format: "%.8g", number.doubleValue) }
            return ""
        }, set: { values[key] = $0; status = "Unapplied changes" })
    }
    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { stringValue(key) }, set: { values[key] = $0; status = "Unapplied changes" })
    }
    private func number(_ label: String, _ key: String, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, text: textBinding(key)).multilineTextAlignment(.trailing).frame(width: 110)
            Text(unit).font(.caption).foregroundColor(.secondary).frame(width: 195, alignment: .leading)
        }
    }
    private func picker(_ label: String, _ key: String, _ choices: [(String, String)]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker(label, selection: stringBinding(key)) {
                ForEach(choices, id: \.1) { Text($0.0).tag($0.1) }
            }.labelsHidden().frame(maxWidth: 360)
        }
    }
    private func picker(_ label: String, _ key: String, numericChoices choices: [(String, Double)]) -> some View {
        let selection = Binding<Double>(get: {
            if let n = parsedValues[key] as? NSNumber { return n.doubleValue }
            return .nan
        }, set: { values[key] = Self.integerKeys.contains(key) ? Int($0) as Any : $0 as Any; status = "Unapplied changes" })
        return HStack {
            Text(label)
            Spacer()
            Picker(label, selection: selection) {
                ForEach(choices, id: \.1) { Text($0.0).tag($0.1) }
            }.labelsHidden().frame(maxWidth: 360)
        }
    }
    private func toggle(_ label: String, _ key: String) -> some View {
        Toggle(label, isOn: Binding(get: { boolValue(key) }, set: { values[key] = $0; status = "Unapplied changes" }))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 10, content: content).padding(8).frame(maxWidth: .infinity)
        }
    }
    private func apply() {
        guard !SCContext.isRecordingBusy else { return }
        guard errors.isEmpty else { errorMessage = errors.joined(separator: "\n"); return }
        do { try RecordingOptions.apply(parsedValues); status = "Settings applied. The recorder will validate codec support for the selected source." }
        catch { errorMessage = error.localizedDescription }
    }
    private func reload() { values = RecordingOptions.settingsSnapshot(); status = "Loaded saved settings."; reloadProfiles() }
    private func reloadProfiles() {
        do { profiles = try RecordingOptions.profiles() }
        catch { errorMessage = "Could not load profiles: \(error.localizedDescription)" }
    }
    private func saveProfile() {
        guard !SCContext.isRecordingBusy, errors.isEmpty else { return }
        do {
            try RecordingOptions.apply(parsedValues)
            try RecordingOptions.saveProfile(name: profileName)
            status = "Saved profile \(profileName)."; profileName = ""; reloadProfiles()
        } catch { errorMessage = error.localizedDescription }
    }
    private func loadProfile() {
        guard !SCContext.isRecordingBusy, let id = UUID(uuidString: selectedProfile) else { return }
        do { try RecordingOptions.loadProfile(id: id); reload(); status = "Profile loaded and applied." }
        catch { errorMessage = error.localizedDescription }
    }
    private func deleteProfile() {
        guard !SCContext.isRecordingBusy, let id = UUID(uuidString: selectedProfile) else { return }
        do { try RecordingOptions.deleteProfile(id: id); selectedProfile = ""; reloadProfiles(); status = "Profile deleted." }
        catch { errorMessage = error.localizedDescription }
    }

    private static var optionsWindow: NSWindow?
    static func show() {
        if let window = optionsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let available = NSScreen.main?.visibleFrame.height ?? 900
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: min(820, max(620, available - 80))), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Advanced Recording"
        window.contentView = NSHostingView(rootView: RecordingOptionsView())
        window.minSize = NSSize(width: 700, height: 620)
        window.isReleasedWhenClosed = false
        optionsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AdvancedRecordingSettingsLink: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Recording").font(.title2)
            Text("Choose fractional FPS, custom output dimensions, bitrate/audio settings and named profiles.")
            Button("Open advanced recording options…") { RecordingOptionsView.show() }
            Button("Compress an existing video…") { VideoCompressionView.show() }
            Spacer()
        }.padding(24)
    }
}
