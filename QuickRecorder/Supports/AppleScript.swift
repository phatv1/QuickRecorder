//
//  AppleScript.swift
//  QuickRecorder
//
//  Created by apple on 2024/9/23.
//

import Foundation
import AppKit
import ScreenCaptureKit

class selectScreen: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingBusy {
            createAlert(title: "Error".local, message: "Already recording!".local, button1: "OK".local).runModal()
            return nil
        }
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                closeAllWindow()
                if var index = self.evaluatedArguments!["index"] as? Int {
                    guard let screens = SCContext.availableContent?.displays else { return }
                    index -= 1
                    closeAllWindow()
                    if index >= screens.count || index < 0 {
                        createAlert(title: "Error".local, message: "Invalid screen number!".local, button1: "OK".local).runModal()
                        return
                    } else {
                        let screen = screens[index]
                        AppDelegate.shared.createCountdownPanel(screen: screen) {
                            AppDelegate.shared.prepRecord(type: "display", screens: screen, windows: nil, applications: nil)
                        }
                    }
                } else {
                    closeAllWindow()
                    AppDelegate.shared.createNewWindow(view: ScreenSelector(), title: "Screen Selector".local)
                }
            }
        }
        return nil
    }
}

class selectArea: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingBusy {
            createAlert(title: "Error".local, message: "Already recording!".local, button1: "OK".local).runModal()
            return nil
        }
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                closeAllWindow()
                DispatchQueue.main.async {
                    AppDelegate.shared.showAreaSelector(size: NSSize(width: 600, height: 450))
                    var currentDisplay = SCContext.getSCDisplayWithMouse()
                    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .rightMouseDown, .leftMouseDown, .otherMouseDown]) { event in
                        let display = SCContext.getSCDisplayWithMouse()
                        if display != currentDisplay {
                            currentDisplay = display
                            closeAllWindow()
                            AppDelegate.shared.showAreaSelector(size: NSSize(width: 600, height: 450))
                        }
                    }
                }
            }
        }
        return nil
    }
}

class selectApps: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingBusy {
            createAlert(title: "Error".local, message: "Already recording!".local, button1: "OK".local).runModal()
            return nil
        }
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                closeAllWindow()
                if let name = self.evaluatedArguments!["name"] as? String {
                    guard let app = SCContext.availableContent?.applications.first(where: { $0.applicationName == name }) else {
                        createAlert(title: "Error".local, message: "No such application!".local, button1: "OK".local).runModal()
                        return
                    }
                    closeAllWindow()
                    guard let screens = SCContext.availableContent?.displays else { return }
                    guard let windows = SCContext.availableContent?.windows.filter({
                        guard let title = $0.title else { return false }
                        return !title.contains("Item-0")
                        && title != "Window"
                        && $0.frame.width > 40
                        && $0.frame.height > 40
                    }) else { return }
                    var s = [SCDisplay]()
                    for screen in screens {
                        for w in windows {
                            if NSIntersectsRect(screen.frame, w.frame) { if !s.contains(screen) { s.append(screen) }}
                        }
                    }
                    if s.isEmpty {
                        createAlert(title: "Error".local, message: "This application has no windows!".local, button1: "OK".local).runModal()
                        return
                    }
                    if s.count != 1 {
                        AppDelegate.shared.createNewWindow(view: AppSelector(), title: "App Selector".local)
                        createAlert(title: "Error".local, message: "This app exists in multiple screens, please select it manually!".local, button1: "OK".local).runModal()
                    } else {
                        AppDelegate.shared.createCountdownPanel(screen: s.first!) {
                            AppDelegate.shared.prepRecord(type: "application", screens: s.first!, windows: nil, applications: [app])
                        }
                    }
                } else {
                    closeAllWindow()
                    AppDelegate.shared.createNewWindow(view: AppSelector(), title: "App Selector".local)
                }
            }
        }
        return nil
    }
}

class selectWindows: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingBusy {
            createAlert(title: "Error".local, message: "Already recording!".local, button1: "OK".local).runModal()
            return nil
        }
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                closeAllWindow()
                if let title = self.evaluatedArguments!["title"] as? String {
                    var windows = [SCWindow]()
                    guard let w = SCContext.availableContent?.windows.filter({ $0.title == title }) else { return }
                    windows = w
                    if let app = self.evaluatedArguments!["app"] as? String {
                        guard let w = SCContext.availableContent?.windows.filter({ $0.title == title && $0.owningApplication?.applicationName == app }) else { return }
                        windows = w
                    }
                    closeAllWindow()
                    if windows.isEmpty {
                        createAlert(title: "Error".local, message: "No such window!".local, button1: "OK".local).runModal()
                        return
                    }
                    if windows.count > 1 {
                        AppDelegate.shared.createNewWindow(view: WinSelector(), title: "Window Selector".local)
                        createAlert(title: "Error".local, message: "Duplicate window exists, please select it manually!".local, button1: "OK".local).runModal()
                        return
                    }
                    let window = windows.first!
                    guard let screens = SCContext.availableContent?.displays else { return }
                    var s = [SCDisplay]()
                    for screen in screens {
                        if NSIntersectsRect(screen.frame, window.frame) { if !s.contains(screen) { s.append(screen) }}
                    }
                    if s.isEmpty {
                        createAlert(title: "Error".local, message: "Unable to find the screen this window belongs to!".local, button1: "OK".local).runModal()
                        return
                    }
                    if let display = SCContext.getSCDisplayWithMouse() {
                        if s.contains(display) {
                            AppDelegate.shared.createCountdownPanel(screen: display) {
                                AppDelegate.shared.prepRecord(type: "window" , screens: s.first!, windows: [window], applications: nil)
                            }
                        } else {
                            AppDelegate.shared.createCountdownPanel(screen: s.first!) {
                                AppDelegate.shared.prepRecord(type: "window" , screens: s.first!, windows: [window], applications: nil)
                            }
                        }
                    }
                } else {
                    closeAllWindow()
                    AppDelegate.shared.createNewWindow(view: WinSelector(), title: "Window Selector".local)
                }
            }
        }
        return nil
    }
}

class recordAudio: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingBusy {
            createAlert(title: "Error".local, message: "Already recording!".local, button1: "OK".local).runModal()
            return nil
        }
        SCContext.updateAvailableContent {
            DispatchQueue.main.async {
                let m = UserDefaults.standard.bool(forKey: "recordMic")
                if let mic = self.evaluatedArguments!["mic"] as? Bool {
                    UserDefaults.standard.set(mic, forKey: "recordMic")
                }
                closeAllWindow()
                AppDelegate.shared.prepRecord(type: "audio", screens: SCContext.getSCDisplayWithMouse(), windows: nil, applications: nil)
                UserDefaults.standard.set(m, forKey: "recordMic")
            }
        }
        return nil
    }
}

class setPreferences: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if SCContext.isRecordingBusy {
            scriptErrorNumber = -2700
            scriptErrorString = "Recording settings cannot change while recording or finalizing."
            return nil
        }
        let arguments = evaluatedArguments ?? [:]
        do {
            var settings: [String: Any] = [:]
            if let name = arguments["profile"] as? String {
                guard let profile = try RecordingOptions.profiles().first(where: { $0.name == name }),
                      let snapshot = try PropertyListSerialization.propertyList(from: profile.settingsData, options: [], format: nil) as? [String: Any] else {
                    throw RecordingOptionsError.profile("Recording profile not found: \(name)")
                }
                settings.merge(snapshot.filter { RecordingOptions.profileSettingKeys.contains($0.key) }) { _, new in new }
            }
            if let name = arguments["preset"] as? String {
                guard let preset = RecordingPreset(rawValue: name) else {
                    throw RecordingOptionsError.profile("Unknown preset. Choose \(RecordingPreset.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                settings.merge(preset.settings) { _, new in new }
            }
            for key in RecordingOptions.profileSettingKeys {
                if let value = arguments[key] { settings[key] = value }
            }
            if let hires = arguments["hires"] as? Bool { settings["highRes"] = hires ? 2 : 1 }
            if let fps = arguments["fps"] as? NSNumber { settings["frameRate"] = fps.doubleValue }
            if let cursor = arguments["cursor"] as? Bool { settings["showMouse"] = cursor }
            if let sound = arguments["sound"] as? Bool { settings["recordWinSound"] = sound }
            if let microphone = arguments["microphone"] as? Bool { settings["recordMic"] = microphone }
            if let quality = arguments["quality"] as? Int {
                guard (1...3).contains(quality) else { throw RecordingOptionsError.invalid(["Quality must be 1, 2 or 3."]) }
                settings["videoQuality"] = quality == 1 ? 0.3 : (quality == 2 ? 0.7 : 1.0)
            }
            if let micname = arguments["micname"] as? String {
                guard SCContext.getMicrophone().map({ $0.localizedName }).contains(micname) || micname == "default" else {
                    throw RecordingOptionsError.invalid(["Microphone not found: \(micname)"])
                }
                settings["micDevice"] = micname
            }
            if let hdr = arguments["hdr"] as? Bool {
                if #available(macOS 15.0, *) { settings["recordHDR"] = hdr }
                else if hdr { throw RecordingOptionsError.invalid(["HDR requires macOS 15 or later."]) }
            }
            let saveName = (arguments["saveProfile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let deleteName = arguments["deleteProfile"] as? String
            let saved = try RecordingOptions.profiles()
            if let name = saveName {
                guard !name.isEmpty else { throw RecordingOptionsError.profile("Enter a profile name.") }
                guard !saved.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw RecordingOptionsError.profile("A profile with that name already exists.") }
            }
            let deletion = deleteName.flatMap { name in saved.first(where: { $0.name == name }) }
            if let name = deleteName, deletion == nil { throw RecordingOptionsError.profile("Recording profile not found: \(name)") }
            try RecordingOptions.apply(settings)
            if let name = saveName { try RecordingOptions.saveProfile(name: name) }
            if let profile = deletion { try RecordingOptions.deleteProfile(id: profile.id) }
        } catch {
            scriptErrorNumber = -2700
            scriptErrorString = error.localizedDescription
        }
        return nil
    }
}
