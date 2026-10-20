# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

QuickRecorder is a lightweight, high-performance screen recorder for macOS built with SwiftUI. It supports recording screens, windows, applications, mobile devices, and system audio with features like audio loopback recording, mouse highlighting, screen magnifier, and HDR video capture.

**Key Technologies:**
- SwiftUI for the user interface
- ScreenCaptureKit (SCStreamKit) for screen recording
- AVFoundation for video encoding and camera capture
- VideoToolbox for hardware-accelerated encoding

**System Requirements:** macOS 12.3+

## Build Commands

Full Xcode (not just Command Line Tools) is required. Scheme: `QuickRecorder`.

- **Dev build + run:** `./build.sh` — Debug build, unsigned, copies the app to
  `/Applications/QuickRecorder-Dev.app` and runs it in the foreground (logs to stdout).
- **Release DMG:** `./build-release.sh` — arm64 Release build, ad-hoc signed, output in
  `build-release/` (gitignored). The version string `1.8.1` is **hardcoded** in the DMG
  path and volume name; update it together with `MARKETING_VERSION` in
  `QuickRecorder.xcodeproj/project.pbxproj`, `CHANGELOG.md`, and `appcast.xml` when releasing.
  Embedded frameworks (Sparkle) must be re-signed ad-hoc, or hardened runtime rejects them
  at launch with a Team ID mismatch; the script does this.
- **Compile-only check:** `xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- **Debug log:** `debugLog(...)` in `SCContext.swift` writes to `/tmp/qr-debug.log`
  (also reachable from the app's Help menu).

There is no XCTest target. `verify_filename_logic.swift` is a standalone script
(`swift verify_filename_logic.swift`) that simulates the triple-extension file naming logic.
Recording behavior is verified manually: record in the target config, then check the file
with `ffprobe` (duration should match wall-clock time).

`CLAUDE_zh-TW.md` is a Traditional Chinese copy of this file; keep it in sync when editing.

## Dependencies

This project uses Swift Package Manager with the following dependencies:

- **Sparkle** (2.10.0+, up to next major): Auto-update framework. Feed URL is `SUFeedURL`
  in `QuickRecorder/Info.plist` (points at this repo's `appcast.xml`)
- **KeyboardShortcuts** (3.1.0+, up to next major): Global keyboard shortcut handling.
  Needs swift-tools 6.2 (Xcode 26+)
- **SwiftLAME** (pinned revision `45d1b02` = upstream `main` / tag `0.1.0`): MP3 encoding support
- **AECAudioStream** (branch `main`): Audio Echo Cancellation (AEC) support
- **MatrixColorSelector** (branch `main`): Custom color picker UI

Requirements live in `QuickRecorder.xcodeproj/project.pbxproj` (`XCRemoteSwiftPackageReference`);
pins in `QuickRecorder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
After changing a requirement, run
`xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -resolvePackageDependencies`.
Record each dependency change in `CHANGELOG.md`.

## Architecture

### Core Components

**Recording Engine (`RecordEngine.swift`):**
- Entry point: `prepRecord(type:screens:windows:applications:fastStart:)`
- Configures `SCContentFilter` based on recording type (screen/window/application/area/audio)
- Sets up `SCStreamConfiguration` with resolution, frame rate, codec settings
- Manages audio recording from system and microphone
- Handles the main recording loop via `SCStreamDelegate` and `SCStreamOutput`

**Screen Capture Context (`SCContext.swift`):**
- Centralized state management for recording sessions
- Manages `SCStream`, `AVAssetWriter`, and audio engines
- Key methods:
  - `updateAvailableContent()`: Refreshes available displays/windows/apps
  - `stopRecording()`: Cleanup and file finalization
  - `pauseRecording()`: Toggle pause/resume with timestamp management
  - `mixAudioTracks()`: Combines separate mic and system audio tracks

**AV Context (`AVContext.swift`):**
- Camera overlay recording for presenter mode
- Mobile device (iDevice) recording via AVCaptureSession
- Manages `AVCaptureMovieFileOutput` for device recording

**App Delegate (`QuickRecorderApp.swift`):**
- SwiftUI app lifecycle management
- Global state (windows, permissions, settings)
- Keyboard shortcut registration
- Mouse pointer and screen magnifier overlays
- Version checking with Sparkle updater

### View Models (ViewModel/)

UI components are organized by function:
- `ContentView.swift`: Main recording panel
- `SettingsView.swift`: Preferences/settings UI
- `StatusBar.swift`: Menu bar status display
- `AreaSelector.swift`: Region selection for area recording
- `ScreenSelector.swift`, `WinSelector.swift`, `AppSelector.swift`: Capture target pickers
- `CameraOverlayer.swift`: Camera overlay window for macOS 12/13
- `QmaPlayer.swift`: Multi-track audio (.qma) player/editor
- `VideoEditor.swift`: Post-recording trim interface

### Recording Flow

1. User selects recording target (screen/window/app/area)
2. `prepRecord()` creates `SCContentFilter` with:
   - Included/excluded windows and applications
   - Background handling (wallpaper/solid color/transparent)
   - Desktop file visibility, menu bar inclusion
3. `record()` configures `SCStreamConfiguration`:
   - Resolution (retina scaling via `highRes` setting)
   - Frame rate (defaults to 60fps, configurable)
   - Codec (H.264/H.265/HEVC with Alpha)
   - Audio settings (sample rate, channel count)
4. `SCStream` starts, delegates frames to `stream(_:didOutputSampleBuffer:of:)`
5. Video frames → `AVAssetWriterInput` (vwInput)
6. System audio → `AVAssetWriterInput` (awInput)
7. Microphone → separate `AVAssetWriterInput` (micInput)
8. On stop: finalize writers, optionally mix audio tracks, show preview

### Special Features

**Presenter Overlay (macOS 14+):**
- Uses ScreenCaptureKit's built-in presenter overlay API
- Detects overlay state changes via `presenterOverlayContentRect` attachment
- Implements safety delay (`poSafeDelay`) to avoid capturing transition frames

**Audio Echo Cancellation:**
- Optional AEC via `AECAudioStream` library
- Processes microphone input to remove system audio bleed
- Configurable ducking levels (min/mid/max)

**HDR Recording (macOS 15+):**
- Uses `SCStreamConfiguration.captureHDRStreamLocalDisplay` preset
- Captures in BT.2100 PQ color space
- Exports screenshots with +1 EV adjustment for correct brightness

**Multi-track Audio (.qma):**
- Custom package format for separate system/mic audio tracks
- Contains `info.json` with format metadata and volume settings
- Allows independent mixing in `QmaPlayer`

**Pause/Resume:**
- Tracks cumulative time offset (`timeOffset`) across pause periods
- Adjusts CMTime timestamps via `adjustTime(sample:by:)` to maintain continuity

## Important File Paths

- **Main source:** `QuickRecorder/`
  - Core: `QuickRecorderApp.swift`, `RecordEngine.swift`, `SCContext.swift`, `AVContext.swift`
  - Views: `ViewModel/*.swift`
  - Utilities: `Supports/*.swift`
- **Entitlements:** `QuickRecorder/QuickRecorder.entitlements` (camera, microphone access)
- **Localization:** `Base.lproj/`, `zh-Hans.lproj/`, `zh-Hant.lproj/`, `it.lproj/`
- **Assets:** `QuickRecorder/Assets.xcassets/`

## Common Settings (@AppStorage keys)

Settings are stored in UserDefaults with `@AppStorage` wrappers:
- `encoder`: Video codec (h264/h265)
- `videoFormat`: Container format (mp4/mov)
- `audioFormat`: Audio codec (aac/alac/flac/opus/mp3)
- `frameRate`: Recording frame rate (default: 60)
- `videoQuality`: Quality multiplier (0.3/0.7/1.0)
- `highRes`: Retina scaling (2 = retina, 1 = non-retina)
- `recordWinSound`: Capture system audio
- `recordMic`: Capture microphone
- `remuxAudio`: Merge mic+system into single track
- `highlightMouse`: Show mouse highlight overlay
- `showMouse`: Include cursor in recording
- `background`: Window recording background (wallpaper/clear/solid colors)
- `saveDirectory`: Output folder path

## macOS Version Handling

The codebase targets multiple macOS versions with conditional compilation:
- `isMacOS12`, `isMacOS14`, `isMacOS15`: Global version flags
- `@available(macOS 14.0, *)`: Presenter overlay, `filter.pointPixelScale`
- `@available(macOS 15, *)`: HDR recording preset
- `#if compiler(>=6.0)`: Swift 6 specific features

When adding features, check version availability and provide fallbacks for older macOS versions.

## Permissions

QuickRecorder requires several system permissions:
- **Screen Recording**: Primary permission for ScreenCaptureKit (requested on first run)
- **Microphone**: Required if `recordMic` is enabled
- **Camera**: Required for camera overlay or device recording

Permission checks are in `SCContext.swift`:
- `requestPermissions()`: Screen recording (shows alert if denied)
- `performMicCheck()`: Microphone (async check)
- `requestCameraPermission()`: Camera access

## Known Limitations

- Not a sandboxed app (no App Store distribution planned)
- H.264 hardware encoder has resolution limitations (prompts to switch to H.265 if unsupported)
- macOS 12 doesn't support: system audio capture (`recordWinSound`), preview window
- Some features (presenter overlay, HDR) require newer macOS versions

## Recording File Integrity (since v1.7.2, updated v1.7.4)

### Fragmented MP4 Protection (narrow scope after v1.7.4)

> **Fork:** this fork turns fragments on (2 s) for every SDR writer, including audio, and keeps
> them closing with a video heartbeat. Verified 2026-10-20; see `docs/FORK.md` → "Crash protection".
> The text below describes upstream.

`RecordEngine.swift` enables `movieFragmentInterval = 1.0s` on the main `AVAssetWriter`
**only when neither `recordMic` nor `recordWinSound` is on AND `recordHDR == false`** —
i.e. screen-only recording with no audio (the check is in `initVideo`). With fragmented MP4
active in that mode, the moov atom is written every second, so if the app is force-killed or
crashes, the file remains playable (losing at most the last 1 second).

Separately, the audio-only `.qma` path sets `movieFragmentInterval = 0.5s` on its
single-input mic writer (`filePath2`). It has not been checked against the stall described below.

**Why audio inputs are skipped (v1.7.4 root cause finding)**: AVAssetWriter's
fragmented mode requires every input to remain "ready" at each fragment boundary.
SCStream feeds video and audio sample buffers on independent callbacks at different
rates, and `awInput.isReadyForMoreMediaData` permanently returns false after the first
1s fragment — subsequent audio samples are silently dropped (no log, no error), the
writer effectively stops accepting any new media. ffprobe on three v1.7.3 failed
recordings showed identical 47 AAC frames (=1.0s @ 48kHz) regardless of actual
recording duration — pathognomonic of "first fragment then stall".

**Why HDR is skipped**: HEVC Main10 (used for HDR) triggers `VTVideoEncoderMalfunctionErr (-16341)`
when combined with fragmented MP4. Introduced in commit `a6c645e`, re-fixed in v1.7.2.

**Iteration history (don't repeat the cycle)**:
- v1.7.1 (`a6c645e`): disabled `movieFragmentInterval` entirely — lost protection
- v1.7.2 (`81b8523`): re-enabled, skip only HDR — broke 5-min recordings with audio
- v1.7.3 (`83c8b64`): skip multi-track audio (mic+sys+remux, 3 inputs) — still broken for 2-input case
- v1.7.4: skip whenever ANY audio input is present — only verified-working scope

When changing video encoding paths, **do not** unconditionally disable `movieFragmentInterval` again
unless you've verified the current path was previously protected. If you find a way to keep
fragments working with audio inputs, that's a feature — open a TODO and write a real verify
test (record ≥30s in that exact config, ffprobe duration ≥ wall-clock).

### Orphan Recording Cleanup

`QuickRecorderApp.swift::cleanupOrphanRecordings()` runs on `applicationDidFinishLaunching`.
It scans `saveDirectory` for `.mp4.mp4.mp4` / `.mov.mov.mov` / `.mp4.mp4` / `.mov.mov` files
(the temp markers used by the multi-track audio mixing flow when `recordMic + recordWinSound +
remuxAudio` are all on) and notifies the user via macOS notification — does **not** auto-delete.

### `.mp4.mp4.mp4` Triple Extension (Intentional)

When `remuxAudio + recordMic + recordWinSound` are all enabled, `RecordEngine.swift:381` writes
to `<basename>.mp4.mp4.mp4` as a temp file. `SCContext.mixAudioTracks()` then strips two
extensions to produce the final `<basename>.mp4`. If the app dies during `mixAudioTracks()`
(it's async via `AVAssetExportSession`), the temp file stays on disk.

### Recommended Codec Combo for Recovery-Friendly Recordings

| Setting | Recommended | Reason |
|---------|-------------|--------|
| `encoder` | `h264` | Short GOP, fragments recover cleanly |
| `videoFormat` | `mp4` | Fragmented MP4 most stable in this container |
| `recordHDR` | `false` | Avoids -16341, keeps fragmented MP4 active |
| `withAlpha` | `false` | Alpha forces HEVC+MOV, recovery difficult |
| `videoQuality` | `1.0` (high) | Higher bitrate = more self-contained frames |
| `frameRate` | `60` | More data per second to recover |
| `remuxAudio` | `false` (optional) | Avoids `.mp4.mp4.mp4` temp file risk |

These are also the project defaults (see `applicationWillFinishLaunching` in `QuickRecorderApp.swift`)
except for `remuxAudio` which defaults to `true` on macOS 13+.
