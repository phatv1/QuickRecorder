//
//  SCContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AVFAudio
import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications
import SwiftLAME
import SwiftUI
import AECAudioStream

// Debug logging to file for troubleshooting recording issues
private var debugLogInitialized = false
private let debugLogPath = "/tmp/qr-debug.log"
func debugLog(_ message: String) {
    let logFileURL = URL(fileURLWithPath: debugLogPath)

    // On first call, clear old log
    if !debugLogInitialized {
        debugLogInitialized = true
        try? FileManager.default.removeItem(at: logFileURL)
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let timestamp = dateFormatter.string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    // Also print to console
    print("[DEBUGLOG] \(message)")

    // Append to file
    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: debugLogPath) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

class SCContext {
    static var trimingList = [URL]()
    // Capture, timestamp normalization and every writer mutation share this queue.
    static let mediaQueueKey = DispatchSpecificKey<Void>()
    static let mediaQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "QuickRecorder.media", qos: .userInitiated)
        queue.setSpecific(key: mediaQueueKey, value: ())
        return queue
    }()
    static var recordingOptions = RecordingOptions()
    static var timeline = RecordingTimeline()
    static var acceptsMedia = false
    static var stoppingRecording = false
    static var startingRecording = false
    static var recordingFailure: Error?
    static var postProcessingCount = 0
    static var stopCleanupDone = false
    static var recordingOutputSize = CGSize.zero
    static var framePolicy = RecordingFramePolicy(options: RecordingOptions())
    static var adaptiveCapture: RecordingAdaptiveCapture?
    static var previewThumbnail: NSImage?
    static var lastVideoSample: CMSampleBuffer?
    static var pendingVideoSample: CMSampleBuffer?
    static var segmentSeedSample: CMSampleBuffer?
    static var pendingVideoRetryScheduled = false
    static var pendingVideoRetries = 0
    static var stoppedAt = CMTime.zero
    static var lastVideoTime: CMTime?
    static var lastAudioTime: CMTime?
    static var audioDroppedBuffers = 0
    static var videoDroppedFrames = 0
    static var systemConverter: RecordingAudioConverter?
    static var microphoneConverter: RecordingAudioConverter?
    static var liveMixer: RecordingAudioMixer?
    static var audioPending: [CMSampleBuffer] = []
    static var microphonePending: [CMSampleBuffer] = []
    static var segmentManifest: RecordingManifest?
    static var segmentBasePath = ""
    static var segmentStart = CMTime.zero
    static var segmentIndex = 0
    static var segmentVideoSettings: [String: Any] = [:]
    static var segmentFileType = AVFileType.mp4
    static var segmentFinishes = DispatchGroup()
    static var segmentTimer: DispatchSourceTimer?
    static let microphoneGate = DispatchSemaphore(value: 64)
    static var aecNextPTS: CMTime?
    static let aecTimestampLock = NSLock()
    static let droppedAudioLock = NSLock()
    static var microphoneEnqueueDrops = 0
    static var firstFrame: CMSampleBuffer? // Legacy preview call sites; no capture surface is retained here.
    static var autoStop = 0
    static var recordCam = ""
    static var recordDevice = ""
    static var captureSession: AVCaptureSession!
    static var previewSession: AVCaptureSession!
    static var frameCache: CMSampleBuffer?
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    static var isSkipFrame = false
    static var sessionStarted = false  // Track if AVAssetWriter session was started
    static var isMicMuted = false
    static var lastPTS: CMTime?
    static var timeOffset = CMTimeMake(value: 0, timescale: 0)
    static var screenArea: NSRect?
    static let audioEngine = AVAudioEngine()
    static let AECEngine = AECAudioStream(sampleRate: 48000)
    static var backgroundColor: CGColor = CGColor.black
    static var filePath: String!
    static var filePath1: String!
    static var filePath2: String!
    static var audioFile: AVAudioFile?
    static var audioFile2: AVAudioFile?
    static var vW: AVAssetWriter!
    static var vwInput, awInput, micInput: AVAssetWriterInput!
    static var startTime: Date?
    static var timePassed: TimeInterval = 0
    static var stream: SCStream!
    static var screen: SCDisplay?
    static var window: [SCWindow]?
    static var application: [SCRunningApplication]?
    static var streamType: StreamType?
    static var availableContent: SCShareableContent?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]
    
    static func updateAvailableContentSync() -> SCShareableContent? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent? = nil

        updateAvailableContent { content in
            result = content
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }
    
    private static func updateAvailableContent(completion: @escaping (SCShareableContent?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [self] content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.updateAvailableContent() {_ in}
                    }
                default:
                    print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                completion(nil) // 在错误情况下返回 nil
                return
            }

            availableContent = content
            if let displays = content?.displays, !displays.isEmpty {
                completion(content) // 返回成功获取的 content
            } else {
                print("There needs to be at least one display connected!".local)
                completion(nil) // 如果没有显示器连接，则返回 nil
            }
        }
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined: requestPermissions()
                default: print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                return
            }
            availableContent = content
            assert(availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected!".local)
            completion()
        }
    }
    
    static func getSelf() -> SCRunningApplication? {
        return SCContext.availableContent!.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }
    
    static func getSelfWindows() -> [SCWindow]? {
        return SCContext.availableContent!.windows.filter( {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != "Mouse Pointer".local
            && title != "Screen Magnifier".local
            && title != "Camera Overlayer".local
            && title != "iDevice Overlayer".local
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).map({ $0.owningApplication }) {
            if !apps.contains(app!) { apps.append(app!) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return apps
    }
    
    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        var windows = [SCWindow]()
        windows = availableContent!.windows.filter {
            guard let app =  $0.owningApplication,
                  let title = $0.title else {//, !title.isEmpty else {
                return false
            }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
        }
        if isOnScreen { windows = windows.filter({$0.isOnScreen == true}) }
        if hideSelf && ud.bool(forKey: "hideSelf") { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return windows
    }
    
    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon!.size = NSSize(width: 69, height: 69)
        return icon
    }
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func getSCDisplayWithMouse() -> SCDisplay? {
        if let displays = availableContent?.displays {
            for display in displays {
                if let currentDisplayID = getScreenWithMouse()?.displayID {
                    if display.displayID == currentDisplayID {
                        return display
                    }
                }
            }
        }
        return nil
    }
    
    static func getFilePath(capture: Bool = false) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        return ud.string(forKey: "saveDirectory")! + (capture ? "/Capturing at ".local : "/Recording at ".local) + dateFormatter.string(from: Date())
    }
    
    static func updateAudioSettings(format: String = ud.string(forKey: "audioFormat") ?? "", rate: Int? = nil) -> [String : Any] {
        let options = recordingOptions
        var audioSettings: [String: Any] = [AVSampleRateKey: rate ?? options.audioSampleRate,
            AVNumberOfChannelsKey: options.audioChannels]
        switch format {
        case AudioFormat.mp3.rawValue, AudioFormat.aac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        case AudioFormat.alac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case AudioFormat.flac.rawValue: audioSettings[AVFormatIDKey] = kAudioFormatFLAC
        case AudioFormat.opus.rawValue:
            audioSettings[AVFormatIDKey] = ud.string(forKey: "videoFormat") != VideoFormat.mp4.rawValue ? kAudioFormatOpus : kAudioFormatMPEG4AAC
        default: audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        }
        if let codec = audioSettings[AVFormatIDKey] as? AudioFormatID,
           codec == kAudioFormatMPEG4AAC || codec == kAudioFormatOpus {
            audioSettings[AVEncoderBitRateKey] = options.audioBitrateKbps * 1000
            switch options.audioBitrateMode {
            case "constant": audioSettings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
            case "variable": audioSettings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_VariableConstrained
            default: audioSettings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_LongTermAverage
            }
        }
        return audioSettings
    }

    static func onMediaQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: mediaQueueKey) != nil { return try body() }
        return try mediaQueue.sync(execute: body)
    }

    static func noteRecordingActivity() {
        mediaQueue.async { if recordingOptions.adaptiveFrameRate { framePolicy.noteActivity(); adaptiveCapture?.refresh() } }
    }

    static func normalizedSample(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        let offset = CMTimeAdd(timeline.origin, timeline.pauseOffset)
        guard let result = recordingRetimedSample(sample, offset: offset),
              result.presentationTimeStamp.isNumeric, result.presentationTimeStamp >= .zero else { return nil }
        return result
    }

    static func getBackgroundColor() -> CGColor {
        guard let color = ud.string(forKey: "background") else { return CGColor.black  }
        if color == BackgroundType.wallpaper.rawValue { return CGColor.black }
        switch color {
            case "clear": backgroundColor = CGColor.clear
            case "black": backgroundColor = CGColor.black
            case "white": backgroundColor = CGColor.white
            case "gray": backgroundColor = NSColor.systemGray.cgColor
            case "yellow": backgroundColor = NSColor.systemYellow.cgColor
            case "orange": backgroundColor = NSColor.systemOrange.cgColor
            case "green": backgroundColor = NSColor.systemGreen.cgColor
            case "blue": backgroundColor = NSColor.systemBlue.cgColor
            case "red": backgroundColor = NSColor.systemRed.cgColor
            default: backgroundColor = ud.cgColor(forKey: "userColor") ?? CGColor.black
        }
        return backgroundColor
    }
    
    static func performMicCheck() async {
        guard ud.bool(forKey: "recordMic") == true else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        ud.setValue(false, forKey: "recordMic")
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs permission to record your microphone.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    
    private static func requestPermissions() {
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs screen recording permissions, even if you only intend on recording audio.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            NSApp.terminate(self)
        }
    }
    
    static func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized, .restricted, .notDetermined:
            break
        case .denied:
            DispatchQueue.main.async {
                let alert = createAlert(title: "Permission Required",
                                                           message: "QuickRecorder needs this permission to record your camera or mobile device.",
                                                           button1: "Open Settings",
                                                           button2: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        @unknown default:
            break
        }
    }
    
    static func getWallpaper(_ display: SCDisplay) -> NSImage? {
        guard let screen = display.nsScreen else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        do {
            var wallpaper: NSImage?
            try wallpaper = NSImage(data: Data(contentsOf: url))
            if let w = wallpaper { return w }
        } catch {
            print("load wallpaper error: \(error)")
        }
        return nil
    }
    
    static func getRecordingSize() -> String {
        do {
            let fileAttr = try fd.attributesOfItem(atPath: filePath)
            let byteFormat = ByteCountFormatter()
            byteFormat.allowedUnits = [.useMB]
            byteFormat.countStyle = .file
            return byteFormat.string(fromByteCount: fileAttr[FileAttributeKey.size] as! Int64)
        } catch {
            print(String(format: "failed to fetch file for size indicator: %@".local, error.localizedDescription))
        }
        return "Unknown".local
    }
    
    static func getRecordingLength() -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        if isPaused { return formatter.string(from: timePassed) ?? "Unknown".local }
        timePassed = Date.now.timeIntervalSince(startTime ?? Date.now)
        return formatter.string(from: timePassed) ?? "Unknown".local
    }
    
    static func isCameraRunning() -> Bool {
        var preview = false
        var capture = false
        if let session = previewSession { preview = session.isRunning }
        if let session = captureSession { capture = session.isRunning }
        return (preview || capture)
    }
    
    static func pauseRecording() {
        onMediaQueue {
            guard acceptsMedia else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            isPaused.toggle()
            if isPaused { timeline.pause(at: now) }
            else { timeline.resume(at: now); framePolicy.reset() }
            timeOffset = timeline.pauseOffset
            timePassed = timeline.elapsed(at: now).seconds
            startTime = Date.now.addingTimeInterval(-timePassed)
        }
        PopoverState.shared.isPaused = isPaused
    }

    static var isRecordingBusy: Bool {
        onMediaQueue { stream != nil || startingRecording || stoppingRecording || acceptsMedia }
    }

    static func reserveRecordingStart() -> Bool {
        onMediaQueue {
            guard stream == nil, !startingRecording, !stoppingRecording, !acceptsMedia else { return false }
            startingRecording = true
            return true
        }
    }

    static func finishRecordingStart(succeeded: Bool) {
        onMediaQueue {
            startingRecording = false
            if !succeeded && stream == nil && !stoppingRecording {
                streamType = nil
                screen = nil
                window = nil
                application = nil
                audioFile = nil
            }
        }
    }

    static var needsPostRecordingAudioMix: Bool {
        ud.bool(forKey: "recordMic") && ud.bool(forKey: "recordWinSound") && ud.bool(forKey: "remuxAudio")
            && !recordingOptions.mixAudioLive && recordingOptions.segmentDurationSeconds == 0
    }

    static func stopRecording() {
        let shouldStop = onMediaQueue { () -> Bool in
            guard !stoppingRecording, stream != nil || acceptsMedia else { return false }
            stoppingRecording = true
            stopCleanupDone = false
            stoppedAt = timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock()))
            acceptsMedia = false
            adaptiveCapture?.invalidate()
            adaptiveCapture = nil
            segmentTimer?.cancel()
            segmentTimer = nil
            return true
        }
        guard shouldStop else { return }
        RecordingResume.clear()
        if ud.bool(forKey: "preventSleep") { SleepPreventer.shared.allowSleep() }
        let capturedStream = stream
        stream = nil
        Task {
            if let capturedStream {
                do { try await capturedStream.stopCapture() }
                catch { debugLog("stopCapture: \(error)") }
            }
            // Producers are stopped before the serial queue is drained and inputs close.
            if ud.bool(forKey: "recordMic") {
                AudioRecorder.shared.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.stop()
                if ud.bool(forKey: "enableAEC") { try? AECEngine.stopAudioUnit() }
            }
            mediaQueue.async {
                if let mixer = liveMixer {
                    for sample in mixer.finish() { routeAudio(sample, microphone: false) }
                }
                finishMediaWriter(at: stoppedAt, attempts: 50)
            }
        }
    }

    private static func finishMediaWriter(at end: CMTime, attempts: Int) {
        drainAudioQueues()
        guard sessionStarted, let writer = vW, writer.status == .writing else {
            segmentFinishes.notify(queue: .main) { completeStoppedRecording() }
            return
        }
        let videoSamples = terminalVideoSamples(at: end, includePending: true)
        var audio: [RecordingWriterFinalizer.AudioTrack] = []
        if let input = awInput { audio.append(.init(input: input, samples: audioPending)) }
        if let input = micInput { audio.append(.init(input: input, samples: microphonePending)) }
        audioPending.removeAll(); microphonePending.removeAll(); pendingVideoSample = nil; segmentSeedSample = nil
        let path = filePath ?? ""
        let begin = segmentStart
        RecordingWriterFinalizer.finish(writer: writer, video: vwInput, videoSamples: videoSamples,
            audio: audio, end: CMTimeMaximum(.zero, end - begin), on: mediaQueue) { result in
            switch result {
            case .success: recordCompletedSegment(path: path, start: begin, end: end)
            case .failure(let error): recordingFailure = error; debugLog("Finalizing failed: \(error)")
            }
            segmentFinishes.notify(queue: .main) { completeStoppedRecording() }
        }
    }

    private static func completeStoppedRecording() {
        debugLog("Recording finalized: dropped video=\(videoDroppedFrames), audio=\(audioDroppedBuffers + microphoneEnqueueDrops), policySkipped=\(framePolicy.skippedFrames)")
        if let writer = vW, writer.status == .failed {
            showNotification(title: "Failed to save file".local, body: writer.error?.localizedDescription ?? "Unknown writer error", id: "quickrecorder.writer.error")
        }
        if let failure = recordingFailure {
            showNotification(title: "Recording Incomplete", body: failure.localizedDescription, id: "quickrecorder.incomplete")
        }
        if needsPostRecordingAudioMix && streamType != .systemaudio && recordingFailure == nil {
            let thumbnail = previewThumbnail
            let wantsPreview = ud.bool(forKey: "showPreview")
            postProcessingCount += 1
            mixAudioTracks(videoURL: filePath.url) { result in
                DispatchQueue.main.async {
                    defer { finishPostProcessing() }
                    switch result {
                    case .success(let url):
                        if wantsPreview { showPreview(path: url.path, image: thumbnail) }
                        else { showNotification(title: "Recording Completed".local, body: url.path, id: "quickrecorder.completed") }
                    case .failure(let error):
                        debugLog("Audio mixing failed: \(error)")
                        showNotification(title: "Failed to save file".local, body: error.localizedDescription, id: "quickrecorder.mix.error")
                    }
                }
            }
        }

        autoStop = 0
        lastPTS = nil
        recordCam = ""
        recordDevice = ""
        isMagnifierEnabled = false
        isMicMuted = false
        PopoverState.shared.isMicMuted = false
        mousePointer.orderOut(nil)
        screenMagnifier.orderOut(nil)
        AppDelegate.shared.stopGlobalMouseMonitor()
        if let window = NSApp.windows.first(where: { $0.title == "Area Overlayer".local }) { window.close() }
        DispatchQueue.main.async {
            controlPanel.close()
            if isCameraRunning() {
                if camWindow.isVisible { camWindow.close() }
                if deviceWindow.isVisible { deviceWindow.close() }
                if let preview = previewSession { preview.stopRunning() }
                if let capture = captureSession { capture.stopRunning() }
            }
        }
        
        audioFile = nil // close audio file
        audioFile2 = nil // close audio file2
        if streamType == .systemaudio {
            if ud.string(forKey: "audioFormat") == AudioFormat.mp3.rawValue && !ud.bool(forKey: "recordMic") {
                let sourceAudioURL = filePath1.url
                let outPutUrl = (String(filePath.dropLast(4)) + ".mp3").url
                postProcessingCount += 1
                Task {
                    defer { DispatchQueue.main.async { finishPostProcessing() } }
                    do {
                        try await m4a2mp3(inputUrl: sourceAudioURL, outputUrl: outPutUrl)
                        try? fd.removeItem(at: sourceAudioURL)
                        if !ud.bool(forKey: "showPreview") {
                            let title = "Recording Completed".local
                            let body = String(format: "File saved to: %@".local, outPutUrl.path.removingPercentEncoding!)
                            let id = "quickrecorder.completed.\(UUID().uuidString)"
                            showNotification(title: title, body: body, id: id)
                        } else {
                            DispatchQueue.main.async { showPreview(path: outPutUrl.path, image: NSImage(named: "audioIcon")) }
                        }
                    } catch {
                        showNotification(title: "Failed to save file".local, body: "\(error.localizedDescription)", id: "quickrecorder.error.\(UUID().uuidString)")
                    }
                }
            } else {
                if ud.bool(forKey: "remuxAudio") && ud.bool(forKey: "recordMic") {
                    let fileURL = filePath.url
                    let document = try? qmaPackageHandle.load(from: fileURL)
                    if let document = document {
                        let audioPlayerManager = AudioPlayerManager()
                        audioPlayerManager.loadAudioFiles(format: document.info.format, package: fileURL, encoder: document.info.encoder, saveMP3: document.info.exportMP3)
                        audioPlayerManager.sysVol = document.info.sysVol
                        audioPlayerManager.micVol = document.info.micVol
                        let exportMP3 = document.info.exportMP3
                        let format = exportMP3 ? "mp3" : document.info.format
                        let saveURL = fileURL.deletingPathExtension().appendingPathExtension(format)
                        postProcessingCount += 1
                        audioPlayerManager.saveFile(saveURL, saveAsMP3: exportMP3) { finishPostProcessing() }
                    }
                } else {
                    if !ud.bool(forKey: "showPreview") {
                        let title = "Recording Completed".local
                        let body = String(format: "File saved to: %@".local, filePath)
                        let id = "quickrecorder.completed.\(UUID().uuidString)"
                        showNotification(title: title, body: body, id: id)
                    } else {
                        showPreview(path: filePath, image: NSImage(named: "qmaIcon"))
                    }
                }
            }
        }
        
        isPaused = false
        hideMousePointer = false
        window = nil
        screen = nil
        startTime = nil
        AppDelegate.shared.presenterType = "OFF"
        updateStatusBar()
        
        if !needsPostRecordingAudioMix && streamType != .systemaudio {
            if let vW = vW {
                if vW.status != .completed {
                    streamType = nil
                    stopCleanupDone = true
                    finishStopIfReady()
                    return
                }
            }
            if recordingFailure == nil && !ud.bool(forKey: "showPreview") {
                let title = "Recording Completed".local
                let body = String(format: "File saved to: %@".local, filePath)
                let id = "quickrecorder.completed.\(UUID().uuidString)"
                showNotification(title: title, body: body, id: id)
            } else {
                showPreview(path: filePath)
            }
            trimVideo()
        }
        
        streamType = nil
        firstFrame = nil
        lastVideoSample = nil
        pendingVideoSample = nil
        segmentSeedSample = nil
        systemConverter = nil
        microphoneConverter = nil
        liveMixer = nil
        sessionStarted = false
        stopCleanupDone = true
        finishStopIfReady()
    }

    static func finishPostProcessing() {
        postProcessingCount = max(0, postProcessingCount - 1)
        finishStopIfReady()
    }

    private static func finishStopIfReady() {
        if stopCleanupDone && postProcessingCount == 0 { onMediaQueue { stoppingRecording = false } }
    }
    
    static func showPreview(path: String, image: NSImage? = nil) {
        if !ud.bool(forKey: "showPreview") { return }
        var previewImage: NSImage?
        let previewURL = fd.temporaryDirectory.appendingPathComponent("qr-preview.jpg")
        if image == nil { previewThumbnail?.saveToFile(previewURL, type: .jpeg) }
        
        if let i = image { previewImage = i } else { previewImage = NSImage(contentsOf: previewURL) }
        if let previewImage = previewImage, let screen = getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFront(self)
        }
    }
    
    static func m4a2mp3(inputUrl: URL, outputUrl: URL) async throws {
        let progress = Progress()
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(Int32(ud.integer(forKey: "audioQuality"))),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress // optional
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }
    
    static func trimVideo() {
        if ud.bool(forKey: "trimAfterRecord") {
            let fileURL = filePath.url
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: fileURL), title: fileURL.lastPathComponent, only: false)
        }
    }
    
    static func getCameras() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
            deviceTypes.append(.continuityCamera)
        } else {
            deviceTypes.append(.externalUnknown)
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getMicrophone() -> [AVCaptureDevice] {
        var discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        }
        return discoverySession.devices.filter({ !$0.localizedName.contains("CADefaultDeviceAggregate") })
    }
    
    static func getiDevice() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = []
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        } else {
            deviceTypes.append(.externalUnknown)
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .muxed, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getCurrentMic() -> AVCaptureDevice? {
        let deviceName = ud.string(forKey: "micDevice")
        return getMicrophone().first(where: { $0.localizedName == deviceName })
    }

    static func toggleMicrophoneMute() {
        guard streamType != nil && ud.bool(forKey: "recordMic") && streamType != .idevice else { return }
        isMicMuted.toggle()
        PopoverState.shared.isMicMuted = isMicMuted
    }
    
    /*static func getChannelCount() -> Int? {
        if let device = getCurrentMic() {
            if let channels = device.formats.first?.formatDescription.audioChannelLayout?.numberOfChannels {
                return channels
            }
            
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let channelCount = audioStreamBasicDescription.mChannelsPerFrame
                return max(2, Int(channelCount))
            }
        }
        return getDefaultChannelCount()
    }
    
    static func getDefaultChannelCount() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取通道数
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // 查询流配置信息
        var streamConfig: UnsafeMutableAudioBufferListPointer?
        propertySize = 0
        
        // 先获取属性大小
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr else {
            print("Failed to get size for stream configuration")
            return nil
        }
        
        // 分配内存以存储音频流配置
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferList.deallocate() }
        
        let configStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        guard configStatus == noErr else {
            print("Failed to get stream configuration")
            return nil
        }
        
        streamConfig = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // 计算通道总数
        var totalChannels = 0
        for buffer in streamConfig! {
            totalChannels += Int(buffer.mNumberChannels)
        }
        return max(2, totalChannels)
    }*/
    
    static func getSampleRate() -> Int? {
        if let device = getCurrentMic() {
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let sampleRate = audioStreamBasicDescription.mSampleRate
                return Int(sampleRate)
            }
        }
        return getDefaultSampleRate()
    }
    
    static func getDefaultSampleRate() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // 获取默认音频输入设备
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // 获取采样率
        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout.size(ofValue: sampleRate))
        
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let sampleRateStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &sampleRate
        )
        
        guard sampleRateStatus == noErr else {
            print("Failed to get sample rate for the default input device")
            return nil
        }
        
        return Int(sampleRate)
    }
    
    static func adjustTime(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        recordingRetimedSample(sample, offset: offset)
    }

    static func showNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification failed to send：\(error.localizedDescription)") }
        }
    }
    
    static func mixAudioTracks(videoURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        showNotification(title: "Still Processing".local, body: "Mixing audio track...".local, id: "quickrecorder.processing.\(UUID().uuidString)")
        
        let asset = AVAsset(url: videoURL)
        let audioOutputURL = videoURL.deletingPathExtension()
        let outputURL = audioOutputURL.deletingPathExtension()
        let audioOnlyComposition = AVMutableComposition()
        
        let fileEnding = videoURL.pathExtension.lowercased()
        var fileType: AVFileType?
        switch fileEnding {
        case VideoFormat.mov.rawValue: fileType = AVFileType.mov
        case VideoFormat.mp4.rawValue: fileType = AVFileType.mp4
        default: assertionFailure("loaded unknown video format".local)
        }
        
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
            return
        }
        
        for audioTrack in audioTracks {
            if let compositionAudioTrack = audioOnlyComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                    return
                }
            }
        }
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioTracks.map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.trackID = $0.trackID
            return parameters
        }
        
        guard let audioExportSession = AVAssetExportSession(asset: audioOnlyComposition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "AudioExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio export session."])))
            return
        }
        audioExportSession.outputURL = audioOutputURL
        audioExportSession.outputFileType = fileType ?? .mp4
        audioExportSession.audioMix = audioMix
        
        audioExportSession.exportAsynchronously {
            /*var exportStatus: AVAssetExportSession.Status = .unknown
            
            // Loop until export session is completed, failed, or cancelled
            while exportStatus != .completed && exportStatus != .failed && exportStatus != .cancelled {
                exportStatus = audioExportSession.status
                Thread.sleep(forTimeInterval: 0.1)
            }*/
            
            switch audioExportSession.status {
            case .completed:
                let audioAsset = AVAsset(url: audioOutputURL)
                let composition = AVMutableComposition()
                
                guard let videoTrack = asset.tracks(withMediaType: .video).first,
                      let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    completion(.failure(NSError(domain: "VideoTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get video track."])))
                    return
                }
                
                do {
                    try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "VideoTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert video track: \(error.localizedDescription)"])))
                    return
                }
                
                let audioTracks = audioAsset.tracks(withMediaType: .audio)
                guard audioTracks.count >= 1 else {
                    completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
                    return
                }
                
                for audioTrack in audioTracks {
                    if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        do {
                            try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                        } catch {
                            completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                            return
                        }
                    }
                }
                
                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    completion(.failure(NSError(domain: "ExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session."])))
                    return
                }
                
                exportSession.outputURL = outputURL
                exportSession.outputFileType = fileType ?? .mp4
                exportSession.audioMix = audioMix
                
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        let  fileManager = fd
                        try? fileManager.removeItem(atPath: videoURL.path)
                        try? fileManager.removeItem(atPath: audioOutputURL.path)
                        completion(.success(outputURL))
                    case .failed:
                        completion(.failure(exportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
                    case .cancelled:
                        completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
                    default:
                        break
                    }
                }
            case .failed:
                completion(.failure(audioExportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
            case .cancelled:
                completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
            default:
                break
            }
        }
    }

    // Helper: Create a silent CMSampleBuffer with the same format and frame count as the input
    static func makeSilentSampleBuffer(matching buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = buffer.formatDescription,
              let absd = formatDesc.audioStreamBasicDescription else { return nil }
        guard let pcmBuffer = buffer.asPCMBuffer else { return nil }
        let frameLength = pcmBuffer.frameLength
        guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
        guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        silentBuffer.frameLength = frameLength
        // Zero out the buffer (silence)
        if let floatChannelData = silentBuffer.floatChannelData {
            for channel in 0..<Int(silentBuffer.format.channelCount) {
                memset(floatChannelData[channel], 0, Int(frameLength) * MemoryLayout<Float>.size)
            }
        }
        return silentBuffer.recordingSampleBuffer(at: buffer.presentationTimeStamp)
    }

    // Helper: Create a silent CMSampleBuffer with the same format and frame count as the input AVAudioPCMBuffer
    static func makeSilentSampleBuffer(matching buffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let format = buffer.format
        let frameLength = buffer.frameLength
        guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        silentBuffer.frameLength = frameLength
        if let floatChannelData = silentBuffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memset(floatChannelData[channel], 0, Int(frameLength) * MemoryLayout<Float>.size)
            }
        }
        return silentBuffer.asSampleBuffer
    }
}

extension SCContext {
    static func createVideoWriter(path: String) throws {
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: segmentFileType)
        guard writer.canApply(outputSettings: segmentVideoSettings, forMediaType: .video) else {
            throw NSError(domain: "QuickRecorder.Encoding", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected video encoder settings are unsupported."])
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: segmentVideoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw NSError(domain: "QuickRecorder.Encoding", code: 2) }
        writer.add(video)
        var system: AVAssetWriterInput?
        var microphone: AVAssetWriterInput?
        if ud.bool(forKey: "recordWinSound") || liveMixer != nil {
            let settings = updateAudioSettings(format: liveMixer == nil ? (ud.string(forKey: "audioFormat") ?? "aac") : "aac")
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw NSError(domain: "QuickRecorder.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected audio format, sample rate or bitrate is unsupported in this container."]) }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw NSError(domain: "QuickRecorder.Audio", code: 2) }
            writer.add(input)
            system = input
        }
        if ud.bool(forKey: "recordMic") && liveMixer == nil {
            let settings = updateAudioSettings()
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw NSError(domain: "QuickRecorder.Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "The selected microphone output settings are unsupported."]) }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw NSError(domain: "QuickRecorder.Audio", code: 4) }
            writer.add(input)
            microphone = input
        }
        // Fork: crash protection for every SDR writer, including audio. The v1.7.4 audio stall
        // came from inputs going idle at a fragment boundary; this pipeline queues audio and
        // the record() timer appends a heartbeat frame during static screens so fragments
        // keep closing. HDR stays off (-16341). See docs/FORK.md.
        if !ud.bool(forKey: "recordHDR") {
            writer.movieFragmentInterval = CMTime(seconds: recordingFragmentSeconds, preferredTimescale: 1000)
        }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "QuickRecorder.Writer", code: 1) }
        writer.startSession(atSourceTime: .zero)
        vW = writer
        vwInput = video
        awInput = system
        micInput = microphone
        sessionStarted = true
    }

    static func enqueueMicrophonePCM(_ pcm: AVAudioPCMBuffer, at capturedTime: CMTime?) {
        let duration = CMTime(value: Int64(pcm.frameLength), timescale: CMTimeScale(pcm.format.sampleRate))
        let time: CMTime
        if let capturedTime { time = capturedTime }
        else {
            aecTimestampLock.lock()
            time = aecNextPTS ?? CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), duration)
            aecNextPTS = CMTimeAdd(time, duration)
            aecTimestampLock.unlock()
        }
        guard microphoneGate.wait(timeout: .now()) == .success else {
            droppedAudioLock.lock(); microphoneEnqueueDrops += 1; droppedAudioLock.unlock()
            return
        }
        guard let captured = pcm.recordingSampleBuffer(at: time) else { microphoneGate.signal(); return }
        mediaQueue.async {
            defer { microphoneGate.signal() }
            consumeAudio(captured, source: .microphone)
        }
    }

    static func consumeAudio(_ captured: CMSampleBuffer, source: RecordingAudioMixer.Source) {
        guard acceptsMedia, !isPaused, let sample = normalizedSample(captured) else { return }
        let converter = source == .system ? systemConverter : microphoneConverter
        guard let pcm = converter?.convert(sample, muted: source == .microphone && isMicMuted) else {
            audioDroppedBuffers += 1
            return
        }
        let pts = sample.presentationTimeStamp
        if streamType == .systemaudio && source == .system {
            do { try audioFile?.write(from: pcm) }
            catch { debugLog("System audio write failed: \(error)") }
            return
        }
        if let liveMixer {
            for mixed in liveMixer.append(pcm, at: pts, source: source) { routeAudio(mixed, microphone: false) }
        } else if let output = pcm.recordingSampleBuffer(at: pts) {
            routeAudio(output, microphone: source == .microphone)
        }
        drainAudioQueues()
    }

    /// Splits PCM at segment boundaries, keeping the sample clock continuous.
    static func routeAudio(_ original: CMSampleBuffer, microphone: Bool) {
        var sample = original
        if segmentManifest != nil {
            let boundary = CMTimeAdd(segmentStart, CMTime(seconds: recordingOptions.segmentDurationSeconds, preferredTimescale: 600000))
            let start = sample.presentationTimeStamp
            let rate = sample.formatDescription?.audioStreamBasicDescription?.mSampleRate ?? Double(recordingOptions.audioSampleRate)
            let end = CMTimeAdd(start, CMTime(value: Int64(sample.numSamples), timescale: CMTimeScale(rate)))
            if start >= boundary {
                rotateSegment(at: start)
            } else if end > boundary {
                let before = max(0, min(sample.numSamples, Int(((boundary - start).seconds * rate).rounded())))
                if before > 0, let first = recordingAudioSlice(sample, offset: 0, count: before) { enqueueAudio(first, microphone: microphone) }
                drainAudioQueues()
                let actualBoundary = CMTimeAdd(start, CMTime(value: Int64(before), timescale: CMTimeScale(rate)))
                rotateSegment(at: actualBoundary)
                guard before < sample.numSamples, let rest = recordingAudioSlice(sample, offset: before, count: sample.numSamples - before) else { return }
                sample = rest
            }
        }
        enqueueAudio(sample, microphone: microphone)
    }


    private static func enqueueAudio(_ sample: CMSampleBuffer, microphone: Bool) {
        let offset = streamType == .systemaudio ? CMTime.zero : segmentStart
        guard let local = recordingRetimedSample(sample, offset: offset), local.presentationTimeStamp >= .zero else { audioDroppedBuffers += 1; return }
        if microphone {
            if microphonePending.count >= 64 { microphonePending.removeFirst(); audioDroppedBuffers += 1 }
            microphonePending.append(local)
        } else {
            if audioPending.count >= 64 { audioPending.removeFirst(); audioDroppedBuffers += 1 }
            audioPending.append(local)
        }
        lastAudioTime = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
    }

    static func drainAudioQueues() {
        if let writer = vW, writer.status == .failed {
            recordingFailure = writer.error ?? NSError(domain: "QuickRecorder.Writer", code: 11)
            acceptsMedia = false
            DispatchQueue.main.async { stopRecording() }
            return
        }
        flushPendingVideo()
        while !audioPending.isEmpty, let input = awInput, input.isReadyForMoreMediaData {
            let sample = audioPending.removeFirst()
            if !input.append(sample) { audioDroppedBuffers += 1; debugLog("System audio append failed: \(String(describing: vW?.error))") }
        }
        while !microphonePending.isEmpty, let input = micInput, input.isReadyForMoreMediaData {
            let sample = microphonePending.removeFirst()
            if !input.append(sample) { audioDroppedBuffers += 1; debugLog("Microphone append failed: \(String(describing: vW?.error))") }
        }
    }

    /// Re-appends the last frame when the screen has been static, so a fragmented writer
    /// can close its fragment (a kill during a long video gap otherwise loses the whole file).
    static func appendVideoHeartbeat(at now: CMTime) {
        guard vW?.movieFragmentInterval.isValid == true, pendingVideoSample == nil, segmentSeedSample == nil,
              let last = lastVideoSample, let lastTime = lastVideoTime,
              now - lastTime >= CMTime(seconds: recordingFragmentSeconds, preferredTimescale: 600000),
              let frame = recordingRetimedSample(last, offset: last.presentationTimeStamp - now) else { return }
        consumeVideo(frame)
    }

    static func consumeVideo(_ sample: CMSampleBuffer) {
        let pts = sample.presentationTimeStamp
        if segmentManifest != nil && awInput == nil && micInput == nil && pts - segmentStart >= CMTime(seconds: recordingOptions.segmentDurationSeconds, preferredTimescale: 600000) {
            rotateSegment(at: pts)
        }
        guard lastVideoTime == nil || pts > lastVideoTime! else { return }
        if pendingVideoSample != nil { videoDroppedFrames += 1 }
        pendingVideoSample = sample
        flushPendingVideo()
    }

    static func flushPendingVideo() {
        guard let sample = segmentSeedSample ?? pendingVideoSample, let input = vwInput, vW?.status == .writing else { return }
        let isSeed = segmentSeedSample != nil
        if !isSeed, acceptsMedia, segmentManifest != nil, awInput != nil || micInput != nil,
           sample.presentationTimeStamp >= segmentStart + CMTime(seconds: recordingOptions.segmentDurationSeconds, preferredTimescale: 600000) { return }
        guard input.isReadyForMoreMediaData else {
            if !pendingVideoRetryScheduled && acceptsMedia {
                pendingVideoRetryScheduled = true
                mediaQueue.asyncAfter(deadline: .now() + 0.02) {
                    pendingVideoRetryScheduled = false
                    guard acceptsMedia else { return }
                    pendingVideoRetries += 1
                    if pendingVideoRetries > 100 {
                        debugLog("Video writer remained blocked for 2 seconds; stopping")
                        DispatchQueue.main.async { stopRecording() }
                    } else { flushPendingVideo() }
                }
            }
            return
        }
        pendingVideoRetries = 0
        let pts = sample.presentationTimeStamp
        guard let local = recordingRetimedSample(sample, offset: segmentStart) else { return }
        guard input.append(local) else {
            debugLog("Video append failed: \(String(describing: vW?.error))")
            acceptsMedia = false
            DispatchQueue.main.async { stopRecording() }
            return
        }
        if isSeed { segmentSeedSample = nil } else { pendingVideoSample = nil }
        lastVideoTime = pts
        lastPTS = pts
        // Exactly one latest frame is retained for terminal/segment stills; each new
        // frame releases its predecessor. Copying every 60-fps frame would add bandwidth.
        lastVideoSample = sample
        if previewThumbnail == nil, let pixel = sample.imageBuffer {
            let image = CIImage(cvPixelBuffer: pixel)
            let scale = min(1, 480 / image.extent.width)
            let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = CIContext().createCGImage(resized, from: resized.extent) { previewThumbnail = NSImage(cgImage: cg, size: .zero) }
        }
        if isSeed { flushPendingVideo() }
    }

    static func terminalVideoSamples(at globalTime: CMTime, includePending: Bool) -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        let pending = includePending ? pendingVideoSample : nil
        let seed = includePending ? segmentSeedSample : nil
        for candidate in [seed, pending].compactMap({ $0 }) {
            if candidate.presentationTimeStamp >= segmentStart, candidate.presentationTimeStamp < globalTime,
               let local = recordingRetimedSample(candidate, offset: segmentStart) { samples.append(local) }
        }
        guard let sample = pending ?? seed ?? lastVideoSample else { return samples }
        let previous = pending?.presentationTimeStamp ?? seed?.presentationTimeStamp ?? lastVideoTime ?? segmentStart
        let target = CMTimeMaximum(segmentStart, globalTime - recordingTerminalFrameLead)
        if target > previous,
           let terminal = recordingRetimedSample(sample, offset: sample.presentationTimeStamp - (target - segmentStart)) { samples.append(terminal) }
        return samples
    }

    static func rotateSegment(at boundary: CMTime) {
        guard segmentManifest != nil, let old = vW, old.status == .writing, boundary > segmentStart else { return }
        drainAudioQueues()
        let path = filePath ?? ""
        let oldStart = segmentStart
        let oldVideo = vwInput
        let terminal = terminalVideoSamples(at: boundary, includePending: false)
        var audio: [RecordingWriterFinalizer.AudioTrack] = []
        if let input = awInput { audio.append(.init(input: input, samples: audioPending)) }
        if let input = micInput { audio.append(.init(input: input, samples: microphonePending)) }
        audioPending.removeAll(); microphonePending.removeAll()
        segmentFinishes.enter()
        RecordingWriterFinalizer.finish(writer: old, video: oldVideo, videoSamples: terminal,
            audio: audio, end: boundary - oldStart, on: mediaQueue) { result in
            switch result {
            case .success: recordCompletedSegment(path: path, start: oldStart, end: boundary)
            case .failure(let error):
                recordingFailure = error
                debugLog("Segment finalizing failed: \(error)")
                DispatchQueue.main.async { stopRecording() }
            }
            segmentFinishes.leave()
        }
        // A failed new-writer creation must never leave the closing writer active.
        vW = nil; vwInput = nil; awInput = nil; micInput = nil
        segmentStart = boundary
        segmentIndex += 1
        let ending = segmentFileType == .mov ? "mov" : "mp4"
        filePath = String(format: "%@-%04d.%@", segmentBasePath, segmentIndex + 1, ending)
        do {
            try createVideoWriter(path: filePath)
            if let held = lastVideoSample,
               let seeded = recordingRetimedSample(held, offset: held.presentationTimeStamp - boundary) {
                // The initial still is subject to the same retry path as captured video.
                segmentSeedSample = seeded
                lastVideoTime = nil
                flushPendingVideo()
            }
        } catch {
            acceptsMedia = false
            recordingFailure = error
            debugLog("Segment rotation failed: \(error)")
            DispatchQueue.main.async { stopRecording() }
        }
    }

    static func recordCompletedSegment(path: String, start: CMTime? = nil, end: CMTime) {
        guard var manifest = segmentManifest else { return }
        let begin = start ?? segmentStart
        manifest.segments.append(RecordingSegment(file: URL(fileURLWithPath: path).lastPathComponent,
            startSeconds: begin.seconds, durationSeconds: max(0, (end - begin).seconds)))
        manifest.segments.sort { $0.startSeconds < $1.startSeconds }
        segmentManifest = manifest
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: URL(fileURLWithPath: segmentBasePath + ".recording.json"), options: .atomic)
        } catch { debugLog("Manifest write failed: \(error)") }
    }
}
