# Fork notes

Fork of [fun-ed/QuickRecorder](https://github.com/fun-ed/QuickRecorder) that adds low-resource recording
(see `docs/low-resource-recording-research.vi.md`) and a build path that needs only Command Line Tools.

## Build without Xcode

```bash
./build-cli.sh                      # -> cli-build/dist/QuickRecorder Fork <version>.dmg
APP_NAME=QuickRecorder BUNDLE_ID=com.lihaoyun6.QuickRecorder ./build-cli.sh   # replace the upstream app instead
ARCH=x86_64 ./build-cli.sh
```

The version is read from `MARKETING_VERSION` in `project.pbxproj`. `cli-build/` holds a SwiftPM package
(`App` symlinks to `QuickRecorder/`); the script generates an asset-catalog shim and assembles the `.app` by hand.

## Staying mergeable with upstream

```bash
git fetch upstream && git merge upstream/main
```

- Fork features live in new files; upstream files only get small hooks.
- `project.pbxproj` only gains references to the 9 new source files (IDs `A0CE2026102…`). It is the most likely
  merge-conflict spot. If it conflicts, take upstream's version and re-add those entries.
- Version, `CHANGELOG.md`, and `appcast.xml` are not touched.
- The fork's identity (name, bundle ID, `SUEnableAutomaticChecks = false`) exists only in the Info.plist that
  `build-cli.sh` generates. Without it, Sparkle would replace the fork with an upstream build.
- If upstream adds an asset, source folder, or dependency, check `cli-build/Package.swift` and `build-cli.sh`.

## Limitations of the CLI build

- KeyboardShortcuts 2.x instead of 3.x, because 3.x needs swift-tools 6.2 (Xcode 26).
- Assets are shipped as loose `.tiff` and `.pdf` files instead of `Assets.car`. Dark-appearance image variants are dropped.
- Signing is ad-hoc without hardened runtime: library validation rejects ad-hoc Sparkle. On first launch, use right-click → Open.
- Sparkle doesn't check for updates automatically. Update by pulling from upstream and rebuilding.
- The `.qma` UTI is still `com.lihaoyun6.QuickRecorder.qma`, shared with the upstream app.
- The single-instance check (`QuickRecorderApp.swift`) is hardcoded to the upstream bundle ID, so the fork and upstream can run at the same time.

## Crash protection and auto-resume

- **Fragments for all SDR recordings** (`SCContext.createVideoWriter`): `movieFragmentInterval` is
  `recordingFragmentSeconds` (2 s), including with audio. HDR stays off (-16341). Upstream limits fragments to
  screen-only recordings (see CLAUDE.md); the audio stall it hit came from inputs going idle at a fragment boundary.
- **Video heartbeat** (`SCContext.appendVideoHeartbeat`, driven by the 1 s timer in `record()`): during a static
  screen, ScreenCaptureKit sends no frames, so fragments never close and a kill loses the whole file. The timer
  re-appends the last frame, retimed to now, once 2 s pass without a frame. Cost: about 1–2 MB per hour.
- **Auto-resume** (`RecordingResume.swift`): the capture target is saved in UserDefaults `activeRecording` while
  recording, and `stopRecording()` (including a normal quit) clears it. If it's still there at launch, the app died
  mid-recording, so it starts a new recording of the same target and posts a notification. The partial file is kept.
  It gives up after 3 resumes that each crash within 60 s. Disable with
  `defaults write com.phatv1.QuickRecorder autoResumeRecording -bool false`.
- Not covered: reboot or logout (no launch at login), a window/app target whose window ID changed, the `.qma` path.

Verified 2026-10-20 (screen + system audio, HEVC, 1 fps, static screen): `kill -9` after 51 s left a playable
46 s file; relaunch resumed into a new file within 1 s; a normal stop after 49 s gave 49.08 s with no drops.
Re-run this check after changing the writer or the timer.
