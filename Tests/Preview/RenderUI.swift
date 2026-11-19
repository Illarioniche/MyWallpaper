import AppKit
import Combine
import SwiftUI

/// UI-only rendering. Windows stay unordered; video is used solely for a thumbnail.
@main
enum RenderUI {
    @MainActor
    static func main() async {
        do {
            try await render()
        } catch {
            print("UI rendering failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func render() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                         ? CommandLine.arguments[1] : ".build/verification", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let domain = "MyWallpaperUIPreview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw PreviewFailure(message: "Cannot create isolated preferences.")
        }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.restoreOnLaunch = false
        preferences.wallpaperEnabled = false
        if CommandLine.arguments.count > 2 {
            let video = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            preferences.videoBookmark = try video.bookmarkData(options: [],
                                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let loginItems = LoginItemController(service: PreviewLoginService(), notificationCenter: NotificationCenter())
        let model = WallpaperModel(preferences: preferences, loginItems: loginItems,
                                   powerMonitor: PreviewPowerMonitor())
        defer {
            model.shutDown()
            defaults.removePersistentDomain(forName: domain)
        }
        if preferences.videoBookmark != nil {
            model.restore()
            let deadline = Date().addingTimeInterval(15)
            while model.thumbnail == nil && model.errorMessage == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard model.thumbnail != nil else {
                throw PreviewFailure(message: model.errorMessage ?? "Timed out creating the video thumbnail.")
            }
        }
        guard !model.hasWallpaper else { throw PreviewFailure(message: "UI preview unexpectedly enabled wallpaper.") }

        // Keep the empty state independent of the optional video thumbnail.
        let emptyDomain = "MyWallpaperUIEmptyPreview.\(UUID().uuidString)"
        guard let emptyDefaults = UserDefaults(suiteName: emptyDomain) else {
            throw PreviewFailure(message: "Cannot create isolated empty-state preferences.")
        }
        let emptyPreferences = WallpaperPreferences(defaults: emptyDefaults)
        emptyPreferences.restoreOnLaunch = false
        emptyPreferences.wallpaperEnabled = false
        let emptyLoginItems = LoginItemController(service: PreviewLoginService(), notificationCenter: NotificationCenter())
        let emptyModel = WallpaperModel(preferences: emptyPreferences, loginItems: emptyLoginItems,
                                        powerMonitor: PreviewPowerMonitor())
        defer {
            emptyModel.shutDown()
            emptyDefaults.removePersistentDomain(forName: emptyDomain)
        }

        let sizes: [(suffix: String, size: NSSize)] = [
            ("", NSSize(width: 980, height: 736)),
            ("-compact", NSSize(width: 820, height: 616))
        ]
        for variant in sizes {
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                for section in AppSection.allCases {
                    let destination = output.appendingPathComponent("ui-\(section.rawValue)-\(theme)\(variant.suffix).png")
                    try await capture(model, section: section, scheme: scheme,
                                      size: variant.size, to: destination)
                }
                let emptyDestination = output.appendingPathComponent("ui-empty-\(theme)\(variant.suffix).png")
                try await capture(emptyModel, section: .wallpaper, scheme: scheme,
                                  size: variant.size, to: emptyDestination)
            }
        }
    }

    @MainActor
    private static func capture(_ model: WallpaperModel, section: AppSection, scheme: ColorScheme,
                                size: NSSize, to destination: URL) async throws {
        guard !model.hasWallpaper else { throw PreviewFailure(message: "UI preview unexpectedly enabled wallpaper.") }
        let navigation = AppNavigation()
        navigation.section = section
        let bounds = NSRect(origin: .zero, size: size)
        let root = ControlView(model: model, navigation: navigation)
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .active)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        // Never order this window onscreen and never capture any display.
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard !window.isVisible,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw PreviewFailure(message: "Hidden-window bitmap rendering is unavailable.")
        }
        hosting.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewFailure(message: "Cannot encode the hidden UI view.")
        }
        try png.write(to: destination)
        print(destination.path)
    }
}

private struct PreviewFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class PreviewPowerMonitor: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}

@MainActor
private final class PreviewLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { throw PreviewFailure(message: "Login mutation is disabled in UI preview.") }
    func unregister() throws { throw PreviewFailure(message: "Login mutation is disabled in UI preview.") }
    func openSystemSettings() {}
}
