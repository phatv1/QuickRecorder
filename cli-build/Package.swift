// swift-tools-version:5.9
// Xcode-free build of QuickRecorder (Command Line Tools only). Driven by ../build-cli.sh;
// the Xcode project stays the source of truth for upstream. `App` symlinks ../QuickRecorder.
import PackageDescription

let package = Package(
    name: "QuickRecorderCLI",
    platforms: [.macOS("12.3")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/hidden-spectrum/SwiftLAME.git", revision: "45d1b021c2bd2bbd38b9669934c0584cda0d1b6b"),
        .package(url: "https://github.com/lihaoyun6/MatrixColorSelector.git", revision: "0853e68c0c9b205ffe6a963f2a56b26e6ceca51a"),
        .package(url: "https://github.com/lihaoyun6/AECAudioStream.git", revision: "0eab971c1dd0420ee84646c71172dd66fa59117c"),
        // 3.x needs swift-tools 6.2 (Xcode 26); 2.x is API-compatible for this app (upstream used 2.4 until v1.7.1).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", "2.0.0"..<"3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "QuickRecorder",
            dependencies: ["Sparkle", "SwiftLAME", "MatrixColorSelector", "AECAudioStream", "KeyboardShortcuts"],
            path: ".",
            exclude: ["dist", "tools", "App/Assets.xcassets", "App/Base.lproj", "App/it.lproj", "App/zh-Hans.lproj", "App/zh-Hant.lproj",
                      "App/Preview Content", "App/Info.plist", "App/QuickRecorder.entitlements", "App/Supports/Scriptable.sdef"],
            sources: ["App", "Shim"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
