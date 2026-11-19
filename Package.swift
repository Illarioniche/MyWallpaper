// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyWallpaper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MyWallpaper", targets: ["MyWallpaper"])],
    targets: [
        .executableTarget(name: "MyWallpaper"),
        .testTarget(name: "MyWallpaperTests", dependencies: ["MyWallpaper"])
    ],
    swiftLanguageModes: [.v6]
)
