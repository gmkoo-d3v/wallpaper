// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacWallpaperEngine",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacWallpaperEngine", targets: ["MacWallpaperEngine"])
    ],
    targets: [
        .executableTarget(
            name: "MacWallpaperEngine",
            path: "Sources"
        )
    ]
)
