import SwiftUI
import UniformTypeIdentifiers

struct VideoCompressionView: View {
    var sourceURL: URL? = nil
    @StateObject private var model = VideoCompressionViewModel()
    @State private var codec = VideoCompressionOptions.Codec.hevc
    @State private var container = VideoCompressionOptions.Container.mp4
    @State private var resolution = "1280 × 720"
    @State private var width = 1280
    @State private var height = 720
    @State private var geometry = VideoCompressionOptions.Geometry.fit
    @State private var limitFPS = true
    @State private var fps = 0.5
    @State private var videoKbps = 150
    @State private var grayscale = false
    @State private var audioMode = VideoCompressionOptions.AudioMode.separate
    @State private var audioRate = 24000
    @State private var audioChannels = 1
    @State private var audioKbps = 32
    @State private var requireHardware = false

    static func show(sourceURL: URL? = nil) {
        AppDelegate.shared.createNewWindow(view: VideoCompressionView(sourceURL: sourceURL),
            title: "Compress Video", random: true, only: false)
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        formatter.usesGroupingSeparator = false
        return formatter
    }()
    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compress Video").font(.headline)
                    Text("Export a new file. Your original is kept.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Open Video…") { model.chooseSource() }.disabled(model.isRunning)
            }
            if let url = model.sourceURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1).help(url.path)
                    if let info = model.sourceInfo {
                        Text("\(info.width) × \(info.height) · \(String(format: "%.1f", info.durationSeconds)) s · \(formatBytes(info.bytes)) · \(info.audioTrackCount) audio track(s)")
                            .font(.caption).foregroundColor(.secondary)
                    } else if model.isLoading { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Choose a video to inspect its size and export settings.")
                    .frame(maxWidth: .infinity, alignment: .leading).foregroundColor(.secondary)
            }
            ScrollView {
                VStack(spacing: 12) {
                    GroupBox(label: Text("Video")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Picker("Codec", selection: $codec) {
                                    ForEach(VideoCompressionOptions.Codec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                Picker("Container", selection: $container) {
                                    ForEach(VideoCompressionOptions.Container.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                                }
                            }
                            HStack {
                                Picker("Size", selection: $resolution) {
                                    ForEach(["Keep source size", "1280 × 720", "1600 × 900", "1920 × 1080", "Custom"], id: \.self) { Text($0) }
                                }
                                if resolution == "Custom" {
                                    TextField("Width", value: $width, formatter: Self.integerFormatter).frame(width: 65)
                                    Text("×")
                                    TextField("Height", value: $height, formatter: Self.integerFormatter).frame(width: 65)
                                }
                            }
                            HStack {
                                Picker("Resize", selection: $geometry) {
                                    ForEach(VideoCompressionOptions.Geometry.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.disabled(resolution == "Keep source size")
                                Text(geometry == .fit ? "Fit keeps the whole image with padding." : geometry == .fill ? "Fill crops edges to fill the output." : "Stretch can change proportions.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            HStack {
                                Toggle("Limit video FPS", isOn: $limitFPS)
                                TextField("FPS", value: $fps, formatter: Self.decimalFormatter).frame(width: 65).disabled(!limitFPS)
                                Text("fps (0.1 = one frame / 10 s)").font(.caption).foregroundColor(.secondary)
                                Spacer()
                            }
                            HStack {
                                Text("Video target")
                                TextField("kbps", value: $videoKbps, formatter: Self.integerFormatter).frame(width: 75)
                                Text("kbps").foregroundColor(.secondary)
                                Spacer()
                                Toggle("Grayscale", isOn: $grayscale)
                            }
                            Toggle("Require a hardware encoder", isOn: $requireHardware)
                            Text("Automatic encoding uses the system encoder. Requiring hardware fails if these settings are unsupported. Output is standard 8-bit SDR.")
                                .font(.caption).foregroundColor(.secondary)
                        }.padding(6)
                    }
                    GroupBox(label: Text("Continuous audio")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Tracks", selection: $audioMode) {
                                ForEach(VideoCompressionOptions.AudioMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            HStack {
                                Picker("AAC", selection: $audioRate) {
                                    ForEach([8000, 16000, 24000, 44100, 48000], id: \.self) { Text("\($0) Hz").tag($0) }
                                }
                                Picker("Channels", selection: $audioChannels) {
                                    Text("Mono").tag(1)
                                    Text("Stereo").tag(2)
                                }
                                TextField("kbps", value: $audioKbps, formatter: Self.integerFormatter).frame(width: 60)
                                Text("kbps / track").font(.caption).foregroundColor(.secondary)
                            }.disabled(audioMode == .remove)
                            Text(audioMode == .mix ? "Mixing averages all audio tracks to leave headroom. Quiet sources may need more volume." : "Video FPS does not reduce audio samples. Keeping separate tracks retains every source audio track.")
                                .font(.caption).foregroundColor(.secondary)
                        }.padding(6)
                    }
                    GroupBox(label: Text("Destination")) {
                        HStack {
                            Text(model.outputDirectory?.path ?? "Same folder as source")
                                .lineLimit(1).truncationMode(.middle).font(.caption)
                            Spacer()
                            Button("Choose Folder…") { model.chooseDestination() }
                        }.padding(6)
                    }
                }.disabled(model.isRunning)
            }
            if model.isRunning {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: model.progress)
                    Text("\(Int(model.progress * 100))% · Final size is measured after export.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let error = model.errorText {
                Text(error).foregroundColor(.red).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result = model.result {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(formatBytes(result.source.bytes)) → \(formatBytes(result.output.bytes))")
                        .font(.headline)
                    Text(result.bytesSaved >= 0 ? "Saved \(formatBytes(result.bytesSaved)) (\(String(format: "%.1f", 100 * Double(result.bytesSaved) / Double(max(1, result.source.bytes))))%)." : "This export is larger by \(formatBytes(-result.bytesSaved)). Try a lower bitrate or FPS.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("\(result.output.width) × \(result.output.height) · \(String(format: "%.2f", result.output.durationSeconds)) s · \(result.output.audioTrackCount) audio track(s)")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("Play Export") { NSWorkspace.shared.open(result.output.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.output.url]) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Low FPS can miss brief on-screen events. Bitrate is a target, not a size limit.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if model.isRunning {
                    Button("Cancel Export") { model.cancel() }
                } else {
                    Button("Export Compressed Copy") { model.start(options: options) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.sourceInfo?.videoTrackCount == 0 || model.sourceInfo == nil || model.isLoading)
                }
            }
        }
        .padding(20).frame(width: 640, height: 700)
        .onAppear { if model.sourceURL == nil, let sourceURL = sourceURL { model.selectSource(sourceURL) } }
        .onDisappear { model.cancel() }
        .onChange(of: resolution) { value in
            switch value {
            case "1280 × 720": width = 1280; height = 720
            case "1600 × 900": width = 1600; height = 900
            case "1920 × 1080": width = 1920; height = 1080
            default: break
            }
        }
    }

    private var options: VideoCompressionOptions {
        var value = VideoCompressionOptions()
        value.codec = codec
        value.container = container
        value.width = resolution == "Keep source size" ? nil : width
        value.height = resolution == "Keep source size" ? nil : height
        value.geometry = geometry
        value.framesPerSecond = limitFPS ? fps : nil
        // Bound before multiplication so malformed text cannot overflow an Int.
        value.videoBitRate = min(max(videoKbps, 0), 100_001) * 1000
        value.grayscale = grayscale
        value.audioMode = audioMode
        value.audioSampleRate = audioRate
        value.audioChannels = audioChannels
        value.audioBitRate = min(max(audioKbps, 0), 321) * 1000
        value.requireHardwareEncoder = requireHardware
        return value
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private final class VideoCompressionViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var sourceInfo: VideoFileInspection?
    @Published var outputDirectory: URL?
    @Published var isRunning = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var errorText: String?
    @Published var result: VideoCompressionResult?
    private var compressor: VideoCompressor?

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { selectSource(url) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    func selectSource(_ url: URL) {
        sourceURL = url
        sourceInfo = nil
        result = nil
        errorText = nil
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let inspection = Result { try VideoFileInspection.inspect(url: url) }
            DispatchQueue.main.async {
                guard self.sourceURL == url else { return }
                self.isLoading = false
                switch inspection {
                case .success(let value):
                    self.sourceInfo = value
                    if value.videoTrackCount == 0 { self.errorText = "This file has no video track." }
                case .failure(let error): self.errorText = error.localizedDescription
                }
            }
        }
    }

    func start(options: VideoCompressionOptions) {
        guard let sourceURL = sourceURL, !isRunning else { return }
        isRunning = true
        progress = 0
        errorText = nil
        result = nil
        let compressor = VideoCompressor()
        self.compressor = compressor
        compressor.compress(sourceURL: sourceURL, destinationDirectory: outputDirectory, options: options, progress: { value in
            DispatchQueue.main.async { self.progress = max(self.progress, value) }
        }, completion: { outcome in
            DispatchQueue.main.async {
                self.isRunning = false
                self.compressor = nil
                switch outcome {
                case .success(let value): self.result = value
                case .failure(let error): self.errorText = error.localizedDescription
                }
            }
        })
    }

    func cancel() { compressor?.cancel() }
}
