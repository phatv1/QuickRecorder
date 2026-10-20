# CLAUDE.md (繁體中文版)

此檔案為 Claude Code (claude.ai/code) 在此程式碼庫中工作時提供指引。

## 專案概述

QuickRecorder 是一個使用 SwiftUI 建構的輕量級、高效能 macOS 螢幕錄製工具。支援錄製螢幕、視窗、應用程式、行動裝置和系統音訊，具備音訊回送錄製、滑鼠高亮、螢幕放大鏡和 HDR 影片擷取等功能。

**核心技術：**
- SwiftUI 使用者介面
- ScreenCaptureKit (SCStreamKit) 螢幕錄製
- AVFoundation 影片編碼與相機擷取
- VideoToolbox 硬體加速編碼

**系統需求：** macOS 12.3 以上

## 建置指令

需要完整的 Xcode（僅有命令列工具不夠）。Scheme：`QuickRecorder`。

- **開發建置並執行：** `./build.sh`。Debug 建置、不簽章，複製到
  `/Applications/QuickRecorder-Dev.app` 後在前景執行（日誌輸出到 stdout）。
- **發布 DMG：** `./build-release.sh`。arm64 Release 建置、ad-hoc 簽章，輸出在
  `build-release/`（已列入 gitignore）。DMG 路徑與磁碟區名稱中的版本字串 `1.8.1` 是
  **寫死的**。發版時要與 `QuickRecorder.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION`、
  `CHANGELOG.md`、`appcast.xml` 一起更新。
  內嵌的 framework（Sparkle）必須以 ad-hoc 重新簽署，否則 hardened runtime 會在啟動時以
  Team ID 不符拒絕載入。腳本已處理這一步。
- **僅編譯檢查：** `xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- **除錯日誌：** `SCContext.swift` 中的 `debugLog(...)` 寫入 `/tmp/qr-debug.log`
  （也可從 App 的 Help 選單開啟）。

專案沒有 XCTest target。`verify_filename_logic.swift` 是獨立腳本
（`swift verify_filename_logic.swift`），模擬三重副檔名的檔名處理邏輯。
錄影行為以手動方式驗證：用目標設定錄一段，再用 `ffprobe` 檢查檔案（長度應與實際時間相符）。

`CLAUDE.md` 是本檔的英文版，修改時請保持同步。

## 相依套件

此專案使用 Swift Package Manager，包含以下相依套件：

- **Sparkle**（2.10.0 以上，同一 major）：自動更新框架。更新來源為 `QuickRecorder/Info.plist`
  的 `SUFeedURL`（指向本 repo 的 `appcast.xml`）
- **KeyboardShortcuts**（3.1.0 以上，同一 major）：全域鍵盤快捷鍵處理。
  需要 swift-tools 6.2（Xcode 26 以上）
- **SwiftLAME**（固定 revision `45d1b02`，即上游 `main` / tag `0.1.0`）：MP3 編碼支援
- **AECAudioStream**（`main` 分支）：音訊回音消除 (AEC) 支援
- **MatrixColorSelector**（`main` 分支）：自訂顏色選擇器 UI

版本需求寫在 `QuickRecorder.xcodeproj/project.pbxproj`（`XCRemoteSwiftPackageReference`），
鎖定版本在 `QuickRecorder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。
修改需求後執行
`xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -resolvePackageDependencies`。
每次依賴變更都記錄在 `CHANGELOG.md`。

## 架構

### 核心元件

**錄製引擎 (`RecordEngine.swift`)：**
- 入口點：`prepRecord(type:screens:windows:applications:fastStart:)`
- 根據錄製類型（螢幕/視窗/應用程式/區域/音訊）設定 `SCContentFilter`
- 設定 `SCStreamConfiguration`，包含解析度、幀率、編解碼器設定
- 管理系統和麥克風的音訊錄製
- 透過 `SCStreamDelegate` 和 `SCStreamOutput` 處理主要錄製迴圈

**螢幕擷取上下文 (`SCContext.swift`)：**
- 錄製會話的集中式狀態管理
- 管理 `SCStream`、`AVAssetWriter` 和音訊引擎
- 關鍵方法：
  - `updateAvailableContent()`：重新整理可用的顯示器/視窗/應用程式
  - `stopRecording()`：清理和檔案完成處理
  - `pauseRecording()`：使用時間戳管理切換暫停/繼續
  - `mixAudioTracks()`：合併獨立的麥克風和系統音訊軌道

**AV 上下文 (`AVContext.swift`)：**
- 簡報者模式的相機覆蓋錄製
- 透過 AVCaptureSession 錄製行動裝置 (iDevice)
- 管理裝置錄製的 `AVCaptureMovieFileOutput`

**應用程式委派 (`QuickRecorderApp.swift`)：**
- SwiftUI 應用程式生命週期管理
- 全域狀態（視窗、權限、設定）
- 鍵盤快捷鍵註冊
- 滑鼠游標和螢幕放大鏡覆蓋
- 使用 Sparkle 更新器進行版本檢查

### 視圖模型 (ViewModel/)

UI 元件按功能組織：
- `ContentView.swift`：主錄製面板
- `SettingsView.swift`：偏好設定/設定 UI
- `StatusBar.swift`：選單列狀態顯示
- `AreaSelector.swift`：區域錄製的範圍選擇
- `ScreenSelector.swift`、`WinSelector.swift`、`AppSelector.swift`：擷取目標選擇器
- `CameraOverlayer.swift`：macOS 12/13 的相機覆蓋視窗
- `QmaPlayer.swift`：多軌音訊 (.qma) 播放器/編輯器
- `VideoEditor.swift`：錄製後修剪介面

### 錄製流程

1. 使用者選擇錄製目標（螢幕/視窗/應用程式/區域）
2. `prepRecord()` 建立 `SCContentFilter`，包含：
   - 包含/排除的視窗和應用程式
   - 背景處理（桌布/純色/透明）
   - 桌面檔案可見性、選單列包含設定
3. `record()` 設定 `SCStreamConfiguration`：
   - 解析度（透過 `highRes` 設定進行 Retina 縮放）
   - 幀率（預設 60fps，可設定）
   - 編解碼器（H.264/H.265/HEVC with Alpha）
   - 音訊設定（取樣率、聲道數）
4. `SCStream` 啟動，將幀委派給 `stream(_:didOutputSampleBuffer:of:)`
5. 影片幀 → `AVAssetWriterInput` (vwInput)
6. 系統音訊 → `AVAssetWriterInput` (awInput)
7. 麥克風 → 獨立的 `AVAssetWriterInput` (micInput)
8. 停止時：完成寫入器、選擇性混合音訊軌道、顯示預覽

### 特殊功能

**簡報者覆蓋 (macOS 14+)：**
- 使用 ScreenCaptureKit 的內建簡報者覆蓋 API
- 透過 `presenterOverlayContentRect` 附件偵測覆蓋狀態變更
- 實作安全延遲 (`poSafeDelay`) 以避免擷取轉場幀

**音訊回音消除：**
- 透過 `AECAudioStream` 函式庫提供選用的 AEC
- 處理麥克風輸入以移除系統音訊干擾
- 可設定的閃避等級（最小/中等/最大）

**HDR 錄製 (macOS 15+)：**
- 使用 `SCStreamConfiguration.captureHDRStreamLocalDisplay` 預設
- 在 BT.2100 PQ 色彩空間中擷取
- 匯出螢幕截圖時使用 +1 EV 調整以獲得正確亮度

**多軌音訊 (.qma)：**
- 用於獨立系統/麥克風音訊軌道的自訂封裝格式
- 包含 `info.json`，含有格式中繼資料和音量設定
- 允許在 `QmaPlayer` 中獨立混音

**暫停/繼續：**
- 跨暫停期間追蹤累積時間偏移 (`timeOffset`)
- 透過 `adjustTime(sample:by:)` 調整 CMTime 時間戳以保持連續性

## 重要檔案路徑

- **主要原始碼：** `QuickRecorder/`
  - 核心：`QuickRecorderApp.swift`、`RecordEngine.swift`、`SCContext.swift`、`AVContext.swift`
  - 視圖：`ViewModel/*.swift`
  - 工具程式：`Supports/*.swift`
- **權限設定：** `QuickRecorder/QuickRecorder.entitlements`（相機、麥克風存取）
- **本地化：** `Base.lproj/`、`zh-Hans.lproj/`、`zh-Hant.lproj/`、`it.lproj/`
- **資源：** `QuickRecorder/Assets.xcassets/`

## 常用設定 (@AppStorage 鍵值)

設定透過 `@AppStorage` 包裝器儲存在 UserDefaults 中：
- `encoder`：影片編解碼器 (h264/h265)
- `videoFormat`：容器格式 (mp4/mov)
- `audioFormat`：音訊編解碼器 (aac/alac/flac/opus/mp3)
- `frameRate`：錄製幀率（預設：60）
- `videoQuality`：品質倍數 (0.3/0.7/1.0)
- `highRes`：Retina 縮放（2 = retina，1 = 非 retina）
- `recordWinSound`：擷取系統音訊
- `recordMic`：擷取麥克風
- `remuxAudio`：將麥克風+系統合併為單一軌道
- `highlightMouse`：顯示滑鼠高亮覆蓋
- `showMouse`：在錄製中包含游標
- `background`：視窗錄製背景（桌布/透明/純色）
- `saveDirectory`：輸出資料夾路徑

## macOS 版本處理

程式碼庫針對多個 macOS 版本，使用條件編譯：
- `isMacOS12`、`isMacOS14`、`isMacOS15`：全域版本旗標
- `@available(macOS 14.0, *)`：簡報者覆蓋、`filter.pointPixelScale`
- `@available(macOS 15, *)`：HDR 錄製預設
- `#if compiler(>=6.0)`：Swift 6 特定功能

新增功能時，請檢查版本可用性並為舊版 macOS 提供後備方案。

## 權限

QuickRecorder 需要多項系統權限：
- **螢幕錄製**：ScreenCaptureKit 的主要權限（首次執行時請求）
- **麥克風**：啟用 `recordMic` 時需要
- **相機**：相機覆蓋或裝置錄製時需要

權限檢查位於 `SCContext.swift`：
- `requestPermissions()`：螢幕錄製（拒絕時顯示警告）
- `performMicCheck()`：麥克風（非同步檢查）
- `requestCameraPermission()`：相機存取

## 已知限制

- 非沙盒應用程式（無計畫發布至 App Store）
- H.264 硬體編碼器有解析度限制（不支援時會提示切換至 H.265）
- macOS 12 不支援：系統音訊擷取 (`recordWinSound`)、預覽視窗
- 某些功能（簡報者覆蓋、HDR）需要較新的 macOS 版本

## 錄影檔案完整性（v1.7.2 起，v1.7.4 更新）

### Fragmented MP4 保護（v1.7.4 後縮小範圍）

> **Fork：** 此 fork 對所有 SDR writer（含音訊）啟用 2 秒 fragment，並以影片 heartbeat 讓 fragment
> 持續關閉。已於 2026-10-20 驗證；見 `docs/FORK.md` →「Crash protection」。以下內容描述的是 upstream。

`RecordEngine.swift` 只在 **`recordMic` 與 `recordWinSound` 都關閉，且 `recordHDR == false`** 時，
才在主要 `AVAssetWriter` 啟用 `movieFragmentInterval = 1.0s`，也就是沒有音訊的純螢幕錄影
（判斷位於 `initVideo`）。此模式下 moov atom 每秒寫入一次，App 被強制結束或當機時，
檔案仍可播放（最多損失最後 1 秒）。

另外，純音訊 `.qma` 路徑在只有單一 mic input 的 writer（`filePath2`）上設定
`movieFragmentInterval = 0.5s`。這條路徑尚未對照下述的停滯問題檢查。

**為何有音訊 input 就跳過（v1.7.4 根因）：** AVAssetWriter 的 fragmented 模式要求每個 input
在每個 fragment 邊界都保持 ready。SCStream 以各自獨立、速率不同的 callback 送出 video 與
audio sample buffer。第一個 1s fragment 之後，`awInput.isReadyForMoreMediaData` 會永久回傳
false，後續 audio sample 被靜默丟棄（沒有日誌、沒有錯誤），writer 實際上不再接受新資料。
對三個 v1.7.3 失敗檔執行 ffprobe，不論實際錄多久，都只有相同的 47 個 AAC frame
（=1.0s @ 48kHz），符合「第一個 fragment 後停滯」的特徵。

**為何 HDR 跳過：** HDR 使用的 HEVC Main10 搭配 fragmented MP4 會觸發
`VTVideoEncoderMalfunctionErr (-16341)`。問題由 commit `a6c645e` 引入，v1.7.2 再次修正。

**迭代歷史（不要重蹈覆轍）：**
- v1.7.1（`a6c645e`）：完全停用 `movieFragmentInterval`，失去保護
- v1.7.2（`81b8523`）：重新啟用，只跳過 HDR，導致含音訊的 5 分鐘錄影損壞
- v1.7.3（`83c8b64`）：跳過多軌音訊（mic+sys+remux，3 個 input），2 個 input 的情況仍損壞
- v1.7.4：只要有任何音訊 input 就跳過，這是唯一驗證可行的範圍

修改影片編碼路徑時，除非已確認目前路徑原本就受保護，**不要**再無條件停用
`movieFragmentInterval`。若找到讓 fragment 在有音訊 input 時也能運作的方法，視為新功能：
開一個 TODO，並寫真正的驗證測試（在該設定下錄製 30 秒以上，ffprobe 長度 ≥ 實際時間）。

### 孤兒錄影檔清理

`QuickRecorderApp.swift::cleanupOrphanRecordings()` 在 `applicationDidFinishLaunching` 時執行。
它掃描 `saveDirectory` 中的 `.mp4.mp4.mp4` / `.mov.mov.mov` / `.mp4.mp4` / `.mov.mov` 檔案
（`recordMic + recordWinSound + remuxAudio` 全開時，多軌音訊混音流程使用的暫存標記），
並以 macOS 通知告知使用者，**不會**自動刪除。

### `.mp4.mp4.mp4` 三重副檔名（刻意設計）

`remuxAudio + recordMic + recordWinSound` 全部開啟時，`RecordEngine.swift:381` 會寫入
`<basename>.mp4.mp4.mp4` 作為暫存檔。`SCContext.mixAudioTracks()` 再去掉兩個副檔名，
產生最終的 `<basename>.mp4`。若 App 在 `mixAudioTracks()` 執行期間結束
（它透過 `AVAssetExportSession` 非同步執行），暫存檔會留在磁碟上。

### 利於復原的建議編碼組合

| 設定 | 建議值 | 原因 |
|------|--------|------|
| `encoder` | `h264` | GOP 短，fragment 復原乾淨 |
| `videoFormat` | `mp4` | Fragmented MP4 在此容器最穩定 |
| `recordHDR` | `false` | 避免 -16341，保持 fragmented MP4 啟用 |
| `withAlpha` | `false` | Alpha 強制使用 HEVC+MOV，難以復原 |
| `videoQuality` | `1.0`（高） | 位元率高，自足的影格較多 |
| `frameRate` | `60` | 每秒可復原的資料較多 |
| `remuxAudio` | `false`（選用） | 避免 `.mp4.mp4.mp4` 暫存檔風險 |

以上也是專案預設值（見 `QuickRecorderApp.swift` 的 `applicationWillFinishLaunching`），
唯一例外是 `remuxAudio`，在 macOS 13 以上預設為 `true`。
