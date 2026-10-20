//
//  RecordingResume.swift
//  QuickRecorder
//
//  Fork: restarts a recording that a crash or force-quit interrupted.
//  The state lives in UserDefaults while capture runs; stopRecording() (including a normal
//  quit) clears it, so finding it at launch means the app died mid-recording.
//  Disable with: defaults write <bundle id> autoResumeRecording -bool false
//

import AppKit
import ScreenCaptureKit

struct RecordingResume: Codable {
    var type: String
    var displayID: CGDirectDisplayID
    var windowIDs: [CGWindowID]
    var bundleIDs: [String]
    var area: [Double]?
    var attempts: Int

    private static let key = "activeRecording"
    /// A recording that crashes again before running this long counts toward the retry limit.
    private static let stableSeconds = 60.0
    private static let maxAttempts = 3
    private static var resumeAttempts = 0

    static func recordingStarted() {
        let types: [StreamType: String] = [.screen: "display", .window: "window", .windows: "windows",
                                           .application: "application", .screenarea: "area", .systemaudio: "audio"]
        guard let streamType = SCContext.streamType, let type = types[streamType],
              let display = SCContext.screen else { return }
        let area = SCContext.screenArea.map { [$0.origin.x, $0.origin.y, $0.width, $0.height].map(Double.init) }
        var state = RecordingResume(type: type, displayID: display.displayID,
                                    windowIDs: SCContext.window?.map(\.windowID) ?? [],
                                    bundleIDs: SCContext.application?.map(\.bundleIdentifier) ?? [],
                                    area: type == "area" ? area : nil, attempts: resumeAttempts)
        resumeAttempts = 0
        state.save()
        guard state.attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + stableSeconds) {
            guard var current = load(), current.attempts == state.attempts else { return }
            current.attempts = 0
            current.save()
        }
    }

    static func clear() { ud.removeObject(forKey: key) }

    static func resumeIfNeeded() {
        guard let state = load() else { return }
        clear()
        guard ud.object(forKey: "autoResumeRecording") as? Bool ?? true else { return }
        guard state.attempts < maxAttempts else {
            SCContext.showNotification(title: "Recording Not Resumed",
                body: "The recording stopped unexpectedly \(maxAttempts) times in a row. Start it again manually.",
                id: "quickrecorder.resume.gaveup")
            return
        }
        SCContext.updateAvailableContent {
            DispatchQueue.main.async { state.resume() }
        }
    }

    private func resume() {
        guard !SCContext.isRecordingBusy, let content = SCContext.availableContent,
              let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
        let windows = content.windows.filter { windowIDs.contains($0.windowID) }
        let apps = content.applications.filter { bundleIDs.contains($0.bundleIdentifier) }
        if (type == "window" || type == "windows") && windows.isEmpty || type == "application" && apps.isEmpty {
            SCContext.showNotification(title: "Recording Not Resumed",
                body: "The interrupted recording's window or app is no longer open. The partial file is kept in the save folder.",
                id: "quickrecorder.resume.missing")
            return
        }
        if let area, area.count == 4 { SCContext.screenArea = NSRect(x: area[0], y: area[1], width: area[2], height: area[3]) }
        RecordingResume.resumeAttempts = attempts + 1
        SCContext.showNotification(title: "Recording Resumed",
            body: "QuickRecorder quit unexpectedly while recording. The partial file is kept in the save folder; a new file has started.",
            id: "quickrecorder.resume.started")
        AppDelegate.shared.prepRecord(type: type, screens: display, windows: windows.isEmpty ? nil : windows,
                                      applications: apps.isEmpty ? nil : apps)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(self) { ud.set(data, forKey: RecordingResume.key) }
    }

    private static func load() -> RecordingResume? {
        ud.data(forKey: key).flatMap { try? JSONDecoder().decode(RecordingResume.self, from: $0) }
    }
}
