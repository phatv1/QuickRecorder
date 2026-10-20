//
//  RecordEngine.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/17.
//

import Foundation
import UserNotifications
import ScreenCaptureKit
import AVFoundation
import AVFAudio
import VideoToolbox
import AECAudioStream

extension AppDelegate {
    @objc func prepRecord(type: String, screens: SCDisplay?, windows: [SCWindow]?, applications: [SCRunningApplication]?, fastStart: Bool = false) {
        guard SCContext.reserveRecordingStart() else {
            SCContext.showNotification(title: "Recording Busy", body: "Wait for the current recording to finish saving before starting another.", id: "quickrecorder.busy")
            return
        }
        var scheduledStart = false
        defer { if !scheduledStart { SCContext.finishRecordingStart(succeeded: false) } }
        switch type {
        case "window":  SCContext.streamType = .window
        case "windows":  SCContext.streamType = .windows
        case "display": SCContext.streamType = .screen
        case "application": SCContext.streamType = .application
        case "area": SCContext.streamType = .screenarea
        case "audio":   SCContext.streamType = .systemaudio
            default: return // if we don't even know what to record I don't think we should even try
        }
        var isDirectory: ObjCBool = false
        let outputPath = saveDirectory!
        if fd.fileExists(atPath: outputPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                SCContext.streamType = nil
                _ = createAlert(title: "Failed to Record".local, message: "The output path is a file instead of a folder!".local, button1: "OK").runModal()
                return
            }
        } else {
            do {
                try fd.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                SCContext.streamType = nil
                _ = createAlert(title: "Failed to Record".local, message: "Unable to create output folder!".local, button1: "OK").runModal()
                return
            }
        }
        
        do {
            let options = RecordingOptions()
            try options.validate()
            if type == "audio" && (options.segmentDurationSeconds > 0 || options.mixAudioLive) {
                throw NSError(domain: "RecordingOptions", code: 6, userInfo: [NSLocalizedDescriptionKey: "Live mixing and segmented output are supported for screen recordings. Disable these options for audio-only recording."])
            }
            if options.segmentDurationSeconds > 0 && recordMic && recordWinSound && !options.mixAudioLive {
                throw NSError(domain: "RecordingOptions", code: 3, userInfo: [NSLocalizedDescriptionKey: "Segmented recordings with microphone and system audio require live audio mixing. Enable Mix Audio Live or disable one audio source."])
            }
            if options.rateControl == "budget" && (recordMic || recordWinSound) && (audioFormat == .alac || audioFormat == .flac) {
                throw NSError(domain: "RecordingOptions", code: 4, userInfo: [NSLocalizedDescriptionKey: "A storage budget requires a lossy audio format such as AAC."])
            }
            if withAlpha && options.capturePixelFormat == "nv12" {
                throw NSError(domain: "RecordingOptions", code: 5, userInfo: [NSLocalizedDescriptionKey: "NV12 does not preserve transparency. Select BGRA for alpha recording."])
            }
            if recordHDR && withAlpha { throw NSError(domain: "RecordingOptions", code: 1, userInfo: [NSLocalizedDescriptionKey: "HDR and alpha recording cannot be combined."]) }
            if withAlpha && (videoFormat != .mov || encoder != .h265) { throw NSError(domain: "RecordingOptions", code: 2, userInfo: [NSLocalizedDescriptionKey: "Alpha recording requires H.265 and MOV."]) }
            SCContext.recordingOptions = options
        } catch {
            _ = createAlert(title: "Invalid Recording Settings", message: error.localizedDescription, button1: "OK").runModal()
            return
        }
        // file preparation
        if let screens = screens {
            SCContext.screen = SCContext.availableContent!.displays.first(where: { $0 == screens })
        } else { SCContext.streamType = nil; return }
        
        if let windows = windows {
            SCContext.window = SCContext.availableContent!.windows.filter({ windows.contains($0) })
        } else { if SCContext.streamType == .window { SCContext.streamType = nil; return } }
        
        if let applications = applications {
            SCContext.application = SCContext.availableContent!.applications.filter({ applications.contains($0) })
        } else { if SCContext.streamType == .application { SCContext.streamType = nil; return } }
        
        let screen = SCContext.screen ?? SCContext.getSCDisplayWithMouse()!
        let qrSelf = SCContext.getSelf()
        let qrWindows = SCContext.getSelfWindows()
        let dockApp = SCContext.availableContent!.applications.first(where: { $0.bundleIdentifier.description == "com.apple.dock" })
        let wallpaper = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title != "LPSpringboard" && title != "Dock"
        })
        let desktop = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "" && title == "Desktop"
        })
        let dockWindow = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return true }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title == "Dock"
        })
        let desktopFiles = SCContext.availableContent!.windows.filter({
            $0.owningApplication?.bundleIdentifier == "com.apple.finder"
            && $0.title == "" && $0.frame == screen.frame })
        let controlCenterWindow = SCContext.availableContent!.applications.filter({ $0.bundleIdentifier == "com.apple.controlcenter" })
        let mouseWindow = SCContext.availableContent!.windows.filter({ $0.title == "Mouse Pointer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        let camLayer = SCContext.availableContent!.windows.filter({ $0.title == "Camera Overlayer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        var appBlackList = [String]()
        if let savedData = ud.data(forKey: "hiddenApps"),
           let decodedApps = try? JSONDecoder().decode([AppInfo].self, from: savedData) {
            appBlackList = (decodedApps as [AppInfo]).map({ $0.bundleID })
        }
        let excliudedApps = SCContext.availableContent!.applications.filter({ appBlackList.contains($0.bundleIdentifier) })
        
        if SCContext.streamType == .window || SCContext.streamType == .windows {
            if var includ = SCContext.window {
                if includ.count > 1 {
                    if highlightMouse { includ += mouseWindow }
                    if background.rawValue == BackgroundType.wallpaper.rawValue { if dockApp != nil { includ += wallpaper }}
                    SCContext.filter = SCContentFilter(display: screen, including: includ + camLayer)
                    if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = includeMenuBar }
                } else {
                    SCContext.streamType = .window
                    SCContext.filter = SCContentFilter(desktopIndependentWindow: includ[0])
                }
            }
        } else {
            if SCContext.streamType == .screen || SCContext.streamType == .screenarea {
                if SCContext.streamType == .screenarea {
                    if let area = SCContext.screenArea, let name = screen.nsScreen?.localizedName {
                        let a = ["x": area.origin.x, "y": area.origin.y, "width": area.width, "height": area.height]
                        ud.set([name: a], forKey: "savedArea")
                    }
                }
                var excluded = [SCRunningApplication]()
                var except = [SCWindow]()
                excluded += excliudedApps
                if hideCCenter { excluded += controlCenterWindow }
                if hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                if background.rawValue != BackgroundType.wallpaper.rawValue { if dockApp != nil {
                    except += wallpaper
                    except += desktop
                }}
                if hideDesktopFiles { except += desktopFiles }
                SCContext.filter = SCContentFilter(display: screen, excludingApplications: excluded, exceptingWindows: except)
                if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = ((SCContext.streamType == .screen || SCContext.streamType == .screenarea) && includeMenuBar) }
            }
            if SCContext.streamType == .application {
                var includ = SCContext.application!
                var except = [SCWindow]()
                if let qrSelf = qrSelf { includ.append(qrSelf) }
                let withFinder = includ.map{ $0.bundleIdentifier }.contains("com.apple.finder")
                if withFinder && hideDesktopFiles { except += desktopFiles }
                if hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                //if ud.bool(forKey: "highlightMouse") { if let qrSelf = qrSelf { includ.append(qrSelf) }}
                if background.rawValue == BackgroundType.wallpaper.rawValue { if let dock = dockApp { includ.append(dock); except += dockWindow}}
                SCContext.filter = SCContentFilter(display: screen, including: includ, exceptingWindows: except)
                if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = includeMenuBar }
            }
        }
        if SCContext.streamType == .systemaudio {
            SCContext.filter = SCContentFilter(display: screen, excludingApplications: [], exceptingWindows: [])
            do { try prepareAudioRecording() }
            catch {
                SCContext.vW?.cancelWriting()
                _ = createAlert(title: "Failed to Record", message: error.localizedDescription, button1: "OK").runModal()
                return
            }
        }
        scheduledStart = true
        Task { await record(filter: SCContext.filter!, fastStart: fastStart) }
    }

    func record(filter: SCContentFilter, fastStart: Bool = true) async {
        var started = false
        defer { SCContext.finishRecordingStart(succeeded: started) }
        let options = SCContext.recordingOptions
        SCContext.timeOffset = .zero
        SCContext.timeline.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
        SCContext.acceptsMedia = false
        SCContext.stoppingRecording = false
        SCContext.recordingFailure = nil
        SCContext.postProcessingCount = 0
        SCContext.stopCleanupDone = false
        SCContext.adaptiveCapture?.invalidate()
        SCContext.adaptiveCapture = nil
        SCContext.framePolicy = RecordingFramePolicy(options: options)
        SCContext.lastVideoSample = nil
        SCContext.pendingVideoSample = nil
        SCContext.segmentSeedSample = nil
        SCContext.pendingVideoRetryScheduled = false
        SCContext.pendingVideoRetries = 0
        SCContext.aecNextPTS = nil
        SCContext.microphoneEnqueueDrops = 0
        SCContext.lastVideoTime = nil
        SCContext.lastAudioTime = nil
        SCContext.previewThumbnail = nil
        SCContext.audioDroppedBuffers = 0
        SCContext.videoDroppedFrames = 0
        SCContext.audioPending.removeAll()
        SCContext.microphonePending.removeAll()
        SCContext.systemConverter = RecordingAudioConverter(sampleRate: options.audioSampleRate, channels: options.audioChannels)
        SCContext.microphoneConverter = RecordingAudioConverter(sampleRate: options.audioSampleRate, channels: options.audioChannels)
        SCContext.liveMixer = options.mixAudioLive && recordMic && recordWinSound && SCContext.streamType != .systemaudio
            ? RecordingAudioMixer(sampleRate: options.audioSampleRate, channels: options.audioChannels, mixesTwoSources: true) : nil
        SCContext.isPaused = false
        SCContext.isResume = false
        DispatchQueue.main.async {
            PopoverState.shared.isMicMuted = SCContext.isMicMuted
        }

        let audioOnly = SCContext.streamType == .systemaudio
        if audioOnly { SCContext.segmentManifest = nil; SCContext.segmentStart = .zero }
        
        let conf: SCStreamConfiguration
#if compiler(>=6.0)
        if recordHDR {
            if #available(macOS 15, *) {
                // TODO change here. https://developer.apple.com/videos/play/wwdc2024/10088/?time=191
                // For canonical display, it means you are capturing HDR content that is optimized for sharing with other HDR devices.
                // hdrLocalDisplay or hdrCanonicalDisplay


                conf = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
            } else { conf = SCStreamConfiguration() }
        } else { conf = SCStreamConfiguration() }
#else
        conf = SCStreamConfiguration()
#endif
        conf.width = 2
        conf.height = 2
        
        if !audioOnly {
            if #available(macOS 14.0, *) {
                conf.width = Int(filter.contentRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                conf.height = Int(filter.contentRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
            } else {
                guard let pointPixelScaleOld = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).nsScreen?.backingScaleFactor else { return }
                if SCContext.streamType == .application || SCContext.streamType == .windows || SCContext.streamType == .screen {
                    let frame = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).frame
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                if SCContext.streamType == .window {
                    let frame = SCContext.window![0].frame
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                if SCContext.streamType == .screenarea {
                    let frame = SCContext.screenArea!
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                conf.width = conf.width * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                conf.height = conf.height * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
            }
            
            if fastStart{
                conf.showsCursor = false
            } else{
                conf.showsCursor = showMouse
            }
                    

            if background.rawValue != BackgroundType.wallpaper.rawValue { conf.backgroundColor = SCContext.getBackgroundColor() }
            if !recordHDR {
                conf.pixelFormat = options.capturePixelFormat == "nv12" || (options.capturePixelFormat == "automatic" && options.resolutionMode != "source" && !withAlpha) ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
                conf.colorSpaceName = CGColorSpace.sRGB
                //if withAlpha { conf.pixelFormat = kCVPixelFormatType_32BGRA }
            } else {
                // For recording HDR in a BT2020 PQ container
                conf.colorSpaceName = CGColorSpace.itur_2100_PQ
//                https://developer.apple.com/videos/play/wwdc2022/10155/ guide on how to record 4k60
//                streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    
// Note: 420 encoding causes color bleed at edges, e.g. youtube settings icon with red logo
                // conf.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
//              dont exceed 8 frames  https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth
//                lower queuedepth has more stutter, dont go below 4 https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example/blob/main/Sources/sckrecording/main.swift
                conf.queueDepth = options.captureQueueDepth
            }
        }
        
        if #available(macOS 13, *) {
            conf.capturesAudio = recordWinSound || fastStart || audioOnly
            conf.sampleRate = options.audioSampleRate
            conf.channelCount = options.audioChannels
        }
        

        conf.queueDepth = options.captureQueueDepth
        let captureFPS = options.adaptiveFrameRate ? max(options.adaptiveActiveFPS, options.adaptiveIdleFPS) : options.frameRate
        conf.minimumFrameInterval = audioOnly ? CMTime(seconds: 3600, preferredTimescale: 600000)
            : CMTime(seconds: 1 / captureFPS, preferredTimescale: 600000)

        if SCContext.streamType == .screenarea {
            if let nsRect = SCContext.screenArea {
                let newY = SCContext.screen!.frame.height - nsRect.size.height - nsRect.origin.y
                conf.sourceRect = CGRect(x: nsRect.origin.x, y: newY, width: nsRect.size.width, height: nsRect.size.height)
                if #available(macOS 14.0, *) {
                    conf.width = Int(conf.sourceRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                    conf.height = Int(conf.sourceRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                } else {
                    guard let pointPixelScaleOld = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).nsScreen?.backingScaleFactor else { return }
                    conf.width = Int(conf.sourceRect.width) * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                    conf.height = Int(conf.sourceRect.height) * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                }
            }
        }
        
        if !audioOnly {
            do {
                let sourceSize = CGSize(width: conf.width, height: conf.height)
                SCContext.recordingOutputSize = try RecordingVideoProcessor.outputSize(sourceSize: sourceSize, options: options)
                let captureSize = try RecordingVideoProcessor.captureSize(sourceSize: sourceSize, options: options)
                conf.width = Int(captureSize.width)
                conf.height = Int(captureSize.height)
            } catch {
                SCContext.showNotification(title: "Failed to Record", body: error.localizedDescription, id: "quickrecorder.options")
                return
            }
        }

        let encoderIsH265 = (encoder.rawValue == Encoder.h265.rawValue) || recordHDR
        if !audioOnly && !encoderIsH265 {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(SCContext.recordingOutputSize.width),
                height: Int32(SCContext.recordingOutputSize.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            
            if let session { VTCompressionSessionInvalidate(session) }
            if status != noErr {
                if options.requireHardware {
                    SCContext.showNotification(title: "Hardware Encoder Required", body: "The selected H.264 resolution is not supported by the hardware encoder.", id: "quickrecorder.hardware")
                    return
                }
                let button = showAlertSyncOnMainThread(
                    level: .critical,
                    title: "Encoder Warning",
                    message: "VideoToolbox H.264 hardware encoder doesn't support the current resolution.\nContinue with a software encoder will significantly increase the CPU usage.\n\nWould you like to use H.265 instead?".local,
                    button1: "Use H.265",
                    button2: "Continue with H.264"
                )
                if button == .alertFirstButtonReturn { ud.setValue(Encoder.h265.rawValue, forKey: "encoder") }
            }
        }
        
        SCContext.stream = SCStream(filter: filter, configuration: conf, delegate: self)
        do {
            try SCContext.stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: SCContext.mediaQueue)
            if #available(macOS 13, *) { try SCContext.stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: SCContext.mediaQueue) }
            if !audioOnly {
                try initVideo(conf: conf)
            } else {
                //SCContext.startTime = Date.now
                // Audio producers start together after the writer session is ready.
            }
            SCContext.onMediaQueue {
                SCContext.timeline.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
                SCContext.startTime = Date.now
                SCContext.acceptsMedia = true
                if recordMic { startMicRecording() }
            }
            try await SCContext.stream.startCapture()
            SCContext.onMediaQueue {
                if options.adaptiveFrameRate {
                    SCContext.adaptiveCapture = RecordingAdaptiveCapture(stream: SCContext.stream, configuration: conf,
                        options: options, policy: SCContext.framePolicy, queue: SCContext.mediaQueue,
                        reportError: { debugLog("Adaptive capture update failed: \($0)") })
                }
            }
            started = true
            RecordingResume.recordingStarted()
            if !audioOnly {
                let timedSegments = options.segmentDurationSeconds > 0 && !recordMic && !recordWinSound
                SCContext.mediaQueue.async {
                    let timer = DispatchSource.makeTimerSource(queue: SCContext.mediaQueue)
                    timer.schedule(deadline: .now() + 1, repeating: 1)
                    timer.setEventHandler {
                        guard SCContext.acceptsMedia, !SCContext.isPaused else { return }
                        let elapsed = SCContext.timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock()))
                        if timedSegments && elapsed - SCContext.segmentStart >= CMTime(seconds: options.segmentDurationSeconds, preferredTimescale: 600000) {
                            SCContext.rotateSegment(at: elapsed)
                        }
                        SCContext.appendVideoHeartbeat(at: elapsed)
                    }
                    SCContext.segmentTimer = timer
                    timer.resume()
                }
            }
        } catch {
            SCContext.onMediaQueue { SCContext.acceptsMedia = false; SCContext.vW?.cancelWriting() }
            SCContext.showNotification(title: "Failed to Record", body: error.localizedDescription, id: "quickrecorder.capture.error")
            DispatchQueue.main.async { SCContext.stopRecording() }
            return
        }
        if !audioOnly { registerGlobalMouseMonitor() }
        DispatchQueue.main.async { updateStatusBar() }
        if preventSleep { SleepPreventer.shared.preventSleep(reason: "Screen recording in progress") }
    }

    func prepareAudioRecording() throws {
        SCContext.vW = nil
        SCContext.vwInput = nil
        SCContext.awInput = nil
        SCContext.micInput = nil
        SCContext.sessionStarted = false
        var fileEnding = audioFormat.rawValue
        var fileType = AVFileType.m4a
        let encorder = fileEnding == AudioFormat.mp3.rawValue ? "aac" : fileEnding
        switch fileEnding { // todo: I'd like to store format info differently
            case AudioFormat.mp3.rawValue: fallthrough
            case AudioFormat.aac.rawValue: fallthrough
            case AudioFormat.alac.rawValue: fileEnding = "m4a"
            case AudioFormat.flac.rawValue: fileEnding = "flac"; fileType = .caf
            case AudioFormat.opus.rawValue: fileEnding = "ogg"; fileType = .caf
            default: assertionFailure("loaded unknown audio format: ".local + fileEnding)
        }
        let path = SCContext.getFilePath()
        if recordMic && SCContext.streamType == .systemaudio {
            SCContext.filePath = "\(path).qma"
            SCContext.filePath1 = "\(path).qma/sys.\(fileEnding)"
            SCContext.filePath2 = "\(path).qma/mic.\(fileEnding)"
            let infoJsonURL = "\(path).qma/info.json".url
            let jsonString = "{\"format\": \"\(fileEnding)\", \"encoder\": \"\(encorder)\", \"exportMP3\": \(audioFormat.rawValue == AudioFormat.mp3.rawValue), \"sysVol\": 1.0, \"micVol\": 1.0}"
            try? fd.createDirectory(at: SCContext.filePath.url, withIntermediateDirectories: true, attributes: nil)
            try? jsonString.write(to: infoJsonURL, atomically: true, encoding: .utf8)
            
            SCContext.audioFile = try AVAudioFile(forWriting: SCContext.filePath1.url, settings: SCContext.updateAudioSettings(), commonFormat: .pcmFormatFloat32, interleaved: false)

            let settings = SCContext.updateAudioSettings()
            SCContext.vW = try AVAssetWriter.init(outputURL: SCContext.filePath2.url, fileType: fileType)
            guard SCContext.vW.canApply(outputSettings: settings, forMediaType: .audio) else { throw NSError(domain: "QuickRecorder.Audio", code: 12, userInfo: [NSLocalizedDescriptionKey: "The selected audio encoder settings are unsupported."]) }
            SCContext.micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: settings)
            SCContext.micInput.expectsMediaDataInRealTime = true
            guard SCContext.vW.canAdd(SCContext.micInput) else { throw NSError(domain: "QuickRecorder.Audio", code: 13) }
            SCContext.vW.add(SCContext.micInput)
            // Enable fragmented writing to prevent corruption on unexpected termination
            SCContext.vW.movieFragmentInterval = CMTime(seconds: 0.5, preferredTimescale: 1000)
            guard SCContext.vW.startWriting() else { throw SCContext.vW.error ?? NSError(domain: "QuickRecorder.Audio", code: 14) }
            SCContext.vW.startSession(atSourceTime: .zero)
            SCContext.sessionStarted = true
            //SCContext.audioFile2 = try AVAudioFile(forWriting: SCContext.filePath2.url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } else {
            SCContext.filePath = "\(path).\(fileEnding)"
            SCContext.filePath1 = SCContext.filePath
            SCContext.audioFile = try AVAudioFile(forWriting: SCContext.filePath.url, settings: SCContext.updateAudioSettings(), commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        return deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
    var isMainScreen: Bool {
        guard let id = self.displayID else { return false }
        return (CGDisplayIsMain(id) == 1)
    }
}

extension SCDisplay {
    var nsScreen: NSScreen? {
        return NSScreen.screens.first(where: { $0.displayID == self.displayID })
    }
}

extension AppDelegate {
    func initVideo(conf: SCStreamConfiguration) throws {
        let options = SCContext.recordingOptions
        let fileEnding = videoFormat.rawValue
        let fileType: AVFileType = videoFormat == .mov ? .mov : .mp4
        let needsPostMix = remuxAudio && recordMic && recordWinSound && !options.mixAudioLive && options.segmentDurationSeconds == 0
        SCContext.segmentBasePath = SCContext.getFilePath()
        SCContext.segmentStart = .zero
        SCContext.segmentIndex = 0
        SCContext.segmentManifest = options.segmentDurationSeconds > 0
            ? RecordingManifest(version: 1, startedAt: Date(), segments: []) : nil
        if options.segmentDurationSeconds > 0 {
            SCContext.filePath = "\(SCContext.segmentBasePath)-0001.\(fileEnding)"
        } else if needsPostMix {
            SCContext.filePath = "\(SCContext.segmentBasePath).\(fileEnding).\(fileEnding).\(fileEnding)"
        } else {
            SCContext.filePath = "\(SCContext.segmentBasePath).\(fileEnding)"
        }
        let hevc = encoder == .h265 || recordHDR
        let audioCount = (recordWinSound ? 1 : 0) + (recordMic && SCContext.liveMixer == nil ? 1 : 0)
        let width = Int(SCContext.recordingOutputSize.width)
        let height = Int(SCContext.recordingOutputSize.height)
        var compression = recordingVideoCompression(options: options, width: width, height: height,
            hevc: hevc, hdr: recordHDR, legacyQuality: videoQuality, audioTrackCount: audioCount)
        // Sparse desktop recordings need predictable seeking even when fps < 1.
        if options.keyFrameIntervalSeconds == 0 && options.frameRate < 1 { compression[AVVideoMaxKeyFrameIntervalDurationKey] = 10.0 }
        var settings: [String: Any] = [
            AVVideoCodecKey: hevc ? (withAlpha ? AVVideoCodecType.hevcWithAlpha : .hevc) : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        if options.requireHardware {
            settings[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        }
        if !recordHDR {
            settings[AVVideoColorPropertiesKey] = [AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        SCContext.segmentVideoSettings = settings
        SCContext.segmentFileType = fileType
        try SCContext.createVideoWriter(path: SCContext.filePath)
        debugLog("initVideo: fps=\(options.frameRate), output=\(width)x\(height), bitrate=\(compression[AVVideoAverageBitRateKey] ?? 0), audioTracks=\(audioCount)")
    }

    func startMicRecording() {
        if micDevice == "default" {
            if enableAEC {
                var level = AUVoiceIOOtherAudioDuckingLevel.mid
                if AECLevel == "min" { level = .min }
                else if AECLevel == "max" { level = .max }
                try? SCContext.AECEngine.startAudioStream(enableAEC: true, duckingLevel: level, audioBufferHandler: { buffer in
                    // AECAudioStream does not expose capture AVAudioTime. Anchor its first
                    // PCM block once, then advance by samples rather than callback jitter.
                    SCContext.enqueueMicrophonePCM(buffer, at: nil)
                })
            } else {
                let input = SCContext.audioEngine.inputNode
                let format = input.inputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                    let pts = time.isHostTimeValid ? CMClockMakeHostTimeFromSystemUnits(time.hostTime) : nil
                    SCContext.enqueueMicrophonePCM(buffer, at: pts)
                }
                do { try SCContext.audioEngine.start() }
                catch { debugLog("Microphone start failed: \(error)") }
            }
        } else {
            AudioRecorder.shared.setupAudioCapture()
            AudioRecorder.shared.start()
        }
    }

    func outputVideoEffectDidStart(for stream: SCStream) {
        DispatchQueue.main.async { camWindow.close() }
        print("[Presenter Overlay ON]")
        isPresenterON = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
            self.isCameraReady = true
        }
    }
    
    func outputVideoEffectDidStop(for stream: SCStream) {
        print("[Presenter Overlay OFF]")
        presenterType = "OFF"
        isPresenterON = false
        isCameraReady = false
        DispatchQueue.main.async {
            if SCContext.stream != nil { camWindow.orderFront(self) }
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if SCContext.saveFrame, let imageBuffer = sampleBuffer.imageBuffer {
            SCContext.saveFrame = false
            
            var ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let url = "\(SCContext.getFilePath(capture: true)).png".url
            if !recordHDR {
                sampleBuffer.nsImage?.saveToFile(url)
            } else {
                let context = CIContext()
                
                // Create the HEIF destination with the correct UTI
                //            if let destination = url? {
                // Specify format and color space (assuming default settings here)
                //                let format = CIFormat.rgb10
                let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
                
                // let colorSpace = ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                
                // Image exposure needs to be increased by one stop to match the original
                ciImage = ciImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.0])
                
                
                
                
                
                //                context.writeHEIF10Representation(of: ciImage, to: destination as! URL, colorSpace: colorSpace)
                do{
                    // try context.writeHEIF10Representation(of:ciImage,
                    //                                       to:url,
                    //                                       colorSpace:colorSpace,
                    //                                       options: [
                    //     kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0
                    if #available(macOS 14.0, *) {
                        try context.writePNGRepresentation(of:ciImage,
                                                           to:url,
                                                           format: .RGB10,
                                                           colorSpace:colorSpace
                        )
                    } else {
                        // Fallback on earlier versions
                        print("RGB10 PNG not supported on this macOS version")
                        try context.writePNGRepresentation(of:ciImage,
                                                           to:url,
                                                           format: .RGBA8,
                                                           colorSpace:colorSpace)
                    }
                    //        try context.writePNGRepresentation(of:outImage, to:outURL, format: .RGBA16,colorSpace:colorSpace,options:[:])
                } catch let error {
                    // Handle the error case
                    print("Error: \(error)")
                }
                //                CGImageDestinationFinalize(destination)
            }
        }
        guard SCContext.acceptsMedia, !SCContext.isPaused, sampleBuffer.isValid else { return }
        switch outputType {
        case .screen:
            guard SCContext.streamType != .systemaudio,
                  let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let rawStatus = attachments[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete else { return }
            if #available(macOS 14.2, *), let rect = attachments[.presenterOverlayContentRect] as? [String: Any],
               let x = rect["X"] as? CGFloat {
                let type = x == .infinity ? "OFF" : (x == 0 ? "Small" : "Big")
                if type != presenterType {
                    isCameraReady = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) { self.isCameraReady = true }
                    presenterType = type
                }
            }
            if isPresenterON && !isCameraReady { return }
            let shouldEncode = SCContext.framePolicy.shouldEncode(sampleBuffer)
            SCContext.adaptiveCapture?.refresh()
            guard shouldEncode, let timed = SCContext.normalizedSample(sampleBuffer) else { return }
            guard let prepared = RecordingVideoProcessor.prepare(sample: timed, options: SCContext.recordingOptions,
                outputSize: SCContext.recordingOutputSize) else {
                debugLog("Video processing failed; stopping rather than saving invalid geometry")
                DispatchQueue.main.async { SCContext.stopRecording() }
                return
            }
            SCContext.consumeVideo(prepared)
        case .audio:
            guard recordWinSound || SCContext.streamType == .systemaudio else { return }
            SCContext.consumeAudio(sampleBuffer, source: .system)
#if compiler(>=6.0)
        case .microphone: break // Existing selected-device and AEC microphone producers are used.
#endif
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { // stream error
        print("closing stream with error:\n".local, error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui".local)
        DispatchQueue.main.async {
            SCContext.stream = nil
            SCContext.stopRecording()
        }
    }
}

class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = AudioRecorder()
    private var captureSession: AVCaptureSession!
    private var audioInput: AVCaptureDeviceInput!
    private var audioDataOutput: AVCaptureAudioDataOutput!

    func setupAudioCapture() {
        captureSession = AVCaptureSession()

        // Get the default audio device (microphone)
        guard let audioDevice = SCContext.getCurrentMic() else {
            print("Unable to access microphone")
            return
        }
        
        // Create audio input
        do {
            audioInput = try AVCaptureDeviceInput(device: audioDevice)
        } catch {
            print("Unable to create audio input: \(error)")
            return
        }
        
        // Add audio input to capture session
        if captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        } else {
            print("Unable to add audio input to capture session")
            return
        }

        // Create audio data output
        audioDataOutput = AVCaptureAudioDataOutput()
        audioDataOutput.setSampleBufferDelegate(self, queue: SCContext.mediaQueue)
        
        // Add audio data output to capture session
        if captureSession.canAddOutput(audioDataOutput) {
            captureSession.addOutput(audioDataOutput)
        } else {
            print("Unable to add audio data output to capture session")
            return
        }
    }
    
    func start() {
        if let session = captureSession {
            session.startRunning()
        }
    }
    
    func stop() {
        if let session = captureSession {
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        SCContext.consumeAudio(sampleBuffer, source: .microphone)
    }
}

// https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos
// For Sonoma updated to https://developer.apple.com/forums/thread/727709
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
    
    var nsImage: NSImage? {
        return autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let ciContext = CIContext()
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                return NSImage(cgImage: cgImage, size: .zero)
            }
            return nil
        }
    }
}

// Based on https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c
extension AVAudioPCMBuffer {
    var asSampleBuffer: CMSampleBuffer? {
        let asbd = self.format.streamDescription
        var sampleBuffer: CMSampleBuffer? = nil
        var format: CMFormatDescription? = nil

        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: self.mutableAudioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
