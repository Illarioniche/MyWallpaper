// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyWallpaper",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MyWallpaper", targets: ["MyWallpaper"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "MyWallpaper",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MyWallpaperTests", dependencies: ["MyWallpaper"])
    ],
    swiftLanguageModes: [.v6]
)
