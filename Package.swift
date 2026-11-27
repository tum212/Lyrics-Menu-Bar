// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LyricsMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "CLyricsCore",
            path: "Sources/CLyricsCore"
        ),
        .executableTarget(
            name: "LyricsMenuBar",
            dependencies: ["CLyricsCore"],
            path: "Sources/LyricsMenuBar",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Lrust/target/universal",
                    "-llyrics_core",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/LyricsMenuBar/Info.plist"
                ]),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreHaptics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
    ]
)
