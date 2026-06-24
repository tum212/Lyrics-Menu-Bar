// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LyricsMenuBar",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "LyricsMenuBar",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/LyricsMenuBar/Info.plist"])
            ]
        ),
    ]
)
