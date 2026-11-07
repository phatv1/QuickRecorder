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

// Fork: the capture target Proofly records unattended. `pick target` opens the main panel; whatever the user
// starts next (screen, area, app, window) is saved here instead of recorded. `record default` replays it.
struct DefaultTarget: Codable {
    struct Win: Codable { var id: CGWindowID; var title: String; var app: String; var bundleID: String }
    var type: String
    var displayID: CGDirectDisplayID
    var displayName: String
    var area: [Double]?
    var windows: [Win]
    var bundleIDs: [String]
    var appNames: [String]

    private static let key = "defaultTarget"
    // ponytail: pick mode just times out, so a cancelled pick can't swallow a manual recording much later.
    private static var pickUntil = Date.distantPast
    static var picking: Bool { Date() < pickUntil }

    static func pick() {
        pickUntil = Date() + 300
        // Same as QR's own show-panel hotkey: the panel stays hidden unless the app is activated.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true); _ = AppDelegate.shared.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) }
    }
    static func save(type: String, display: SCDisplay?, windows: [SCWindow]?, apps: [SCRunningApplication]?) {
        pickUntil = .distantPast
        closeAllWindow()
        guard let display else { return }
        let area = SCContext.screenArea.map { [$0.origin.x, $0.origin.y, $0.width, $0.height].map(Double.init) }
        let t = DefaultTarget(type: type, displayID: display.displayID, displayName: display.nsScreen?.localizedName ?? "",
            area: type == "area" ? area : nil,
            windows: (windows ?? []).map { Win(id: $0.windowID, title: $0.title ?? "", app: $0.owningApplication?.applicationName ?? "",
                                               bundleID: $0.owningApplication?.bundleIdentifier ?? "") },
            bundleIDs: (apps ?? []).map(\.bundleIdentifier), appNames: (apps ?? []).map(\.applicationName))
        if let data = try? JSONEncoder().encode(t) { ud.set(data, forKey: key) }
        SCContext.showNotification(title: "Recording Target Saved", body: "Saved as the default. Nothing was recorded.", id: "quickrecorder.target.saved")
    }

    /// Records the saved target (the main display if none) right away, no panel or countdown.
    static func record() {
        pickUntil = .distantPast
        guard !SCContext.isRecordingBusy else { return }
        SCContext.updateAvailableContent { DispatchQueue.main.async {
            guard let content = SCContext.availableContent else { return }
            let main = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
            guard let t = ud.data(forKey: key).flatMap({ try? JSONDecoder().decode(DefaultTarget.self, from: $0) }) else {
                return AppDelegate.shared.prepRecord(type: "display", screens: main, windows: nil, applications: nil)
            }
            let display = content.displays.first { $0.displayID == t.displayID }
                ?? content.displays.first { $0.nsScreen?.localizedName == t.displayName } ?? main
            // Window IDs change when the app relaunches, so fall back to title + app.
            let windows = t.windows.compactMap { w in
                content.windows.first { $0.windowID == w.id }
                    ?? content.windows.first { $0.title == w.title && $0.owningApplication?.bundleIdentifier == w.bundleID }
            }
            let apps = content.applications.filter { t.bundleIDs.contains($0.bundleIdentifier) }
            if t.type.hasPrefix("window") && windows.isEmpty || t.type == "application" && apps.isEmpty {
                return SCContext.showNotification(title: "Recording Not Started",
                    body: "The default window or app is not open. Open it, or pick another target.", id: "quickrecorder.target.missing")
            }
            if let a = t.area, a.count == 4 { SCContext.screenArea = NSRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
            AppDelegate.shared.prepRecord(type: t.type, screens: display, windows: windows.isEmpty ? nil : windows,
                                          applications: apps.isEmpty ? nil : apps)
        }}
    }
}

class pickTarget: NSScriptCommand { override func performDefaultImplementation() -> Any? { DefaultTarget.pick(); return nil } }
class recordDefault: NSScriptCommand { override func performDefaultImplementation() -> Any? { DefaultTarget.record(); return nil } }
