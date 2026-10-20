import Foundation
import SwiftUI
import ScreenCaptureKit
import CoreMedia

/// A user-invoked short recording using the actual capture/writer path and saved options.
/// It writes an ordinary recording, and never changes the profile or deletes the result.
enum RecordingTrial {
    private static var timer: Timer?
    private static var token: UUID?

    static func duration(options: RecordingOptions) -> Double {
        max(30, 2 / (options.adaptiveFrameRate ? options.adaptiveIdleFPS : options.frameRate))
    }

    static func start() {
        DispatchQueue.main.async {
            guard token == nil, !SCContext.isRecordingBusy else { return }
            do { try RecordingOptions().validate() }
            catch { showError(error.localizedDescription); return }
            let trialToken = UUID()
            token = trialToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if token == trialToken && timer == nil {
                    token = nil
                    showError("Capture preparation did not finish. Check Screen Recording permission and try again.")
                }
            }
            Task {
                if RecordingOptions().recordMicrophone { await SCContext.performMicCheck() }
                DispatchQueue.main.async {
                    guard token == trialToken, !SCContext.isRecordingBusy else { token = nil; return }
                    SCContext.updateAvailableContent {
                        DispatchQueue.main.async { begin(token: trialToken) }
                    }
                }
            }
        }
    }

    private static func begin(token trialToken: UUID) {
        guard token == trialToken, !SCContext.isRecordingBusy,
              let display = SCContext.getSCDisplayWithMouse() ?? SCContext.availableContent?.displays.first else {
            token = nil
            showError("No display is available for the recording trial.")
            return
        }
        let state = TrialState(duration: duration(options: RecordingOptions()))
        AppDelegate.shared.prepRecord(type: "display", screens: display, windows: nil, applications: nil, fastStart: false)
        let scheduled = Timer(timeInterval: 0.25, repeats: true) { currentTimer in
            guard token == trialToken else { currentTimer.invalidate(); return }
            if state.stream == nil, let stream = SCContext.stream {
                state.stream = stream
                state.initialPath = SCContext.filePath ?? ""
                state.basePath = SCContext.segmentBasePath
                state.segmented = SCContext.recordingOptions.segmentDurationSeconds > 0
            }
            guard state.stream != nil else {
                if Date().timeIntervalSince(state.requestedAt) > 20 {
                    currentTimer.invalidate(); timer = nil; token = nil
                    showError("The trial did not start. Check capture permissions and the recording settings, then try again.")
                }
                return
            }
            if let current = SCContext.stream, current !== state.stream {
                currentTimer.invalidate(); timer = nil; token = nil
                inspect(state)
                return
            }
            if SCContext.stream != nil {
                let elapsed = SCContext.onMediaQueue {
                    SCContext.timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())).seconds
                }
                if elapsed >= state.duration { SCContext.stopRecording() }
            } else if !SCContext.isRecordingBusy {
                currentTimer.invalidate(); timer = nil; token = nil
                inspect(state)
            }
        }
        timer = scheduled
        RunLoop.main.add(scheduled, forMode: .common)
    }

    private static func inspect(_ state: TrialState) {
        // Post-recording audio mixing may complete after the capture state has been cleared.
        DispatchQueue.global(qos: .userInitiated).async {
            var urls = [URL]()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if state.segmented, let data = try? Data(contentsOf: URL(fileURLWithPath: state.basePath + ".recording.json")),
               let manifest = try? decoder.decode(RecordingManifest.self, from: data) {
                let directory = URL(fileURLWithPath: state.basePath).deletingLastPathComponent()
                urls = manifest.segments.map { directory.appendingPathComponent($0.file) }
            } else {
                let raw = URL(fileURLWithPath: state.initialPath)
                let triple = raw.pathExtension == raw.deletingPathExtension().pathExtension
                    && raw.pathExtension == raw.deletingPathExtension().deletingPathExtension().pathExtension
                let final = triple ? raw.deletingPathExtension().deletingPathExtension() : raw
                if triple {
                    let deadline = Date().addingTimeInterval(60)
                    while !FileManager.default.fileExists(atPath: final.path) && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
                urls = [FileManager.default.fileExists(atPath: final.path) ? final : raw]
            }
            var lines = [String]()
            var valid = [URL]()
            for url in urls {
                do {
                    let info = try VideoFileInspection.inspect(url: url)
                    let mbPerHour = Double(info.bytes) / 1_000_000 * 3600 / info.durationSeconds
                    lines.append("\(url.lastPathComponent)\n\(info.width) × \(info.height) · \(String(format: "%.2f", info.durationSeconds)) s · \(info.audioTrackCount) audio track(s)\n\(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file)) · measured \(String(format: "%.1f", mbPerHour)) MB/hour equivalent")
                    for track in info.tracks {
                        lines.append("\(track.mediaType): starts \(String(format: "%.3f", track.startSeconds)) s, duration \(String(format: "%.3f", track.durationSeconds)) s")
                    }
                    valid.append(url)
                } catch { lines.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            let report = lines.isEmpty ? "The trial did not produce a finalized recording." : lines.joined(separator: "\n\n")
            DispatchQueue.main.async {
                AppDelegate.shared.createNewWindow(view: RecordingTrialResultsView(report: report, urls: valid),
                    title: "Recording Trial", random: true, only: false)
            }
        }
    }

    private static func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Recording Trial"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private final class TrialState {
        let requestedAt = Date()
        let duration: Double
        var stream: SCStream?
        var initialPath = ""
        var basePath = ""
        var segmented = false
        init(duration: Double) { self.duration = duration }
    }
}

private struct RecordingTrialResultsView: View {
    let report: String
    let urls: [URL]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording Trial").font(.title2).bold()
            Text("Measured from the finalized file. A short trial does not measure long-session stability or prove that speech has no gaps.")
                .font(.caption).foregroundColor(.secondary)
            ScrollView { Text(report).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                if let url = urls.first {
                    Button("Play recording") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                    Button("Compress a copy…") { VideoCompressionView.show(sourceURL: url) }
                }
            }
        }.padding(20).frame(width: 600, height: 460)
    }
}
