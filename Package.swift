// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppMixer",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "AppMixer",
            path: "AppMixer",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
