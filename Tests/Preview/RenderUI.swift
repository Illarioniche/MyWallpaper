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

        let navigation = AppNavigation()
        for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for section in ["wallpaper", "general", "power"] {
                switch section {
                case "general": navigation.section = .general
                case "power": navigation.section = .power
                default: navigation.section = .wallpaper
                }
                let bounds = NSRect(x: 0, y: 0, width: 940, height: 696)
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
                let destination = output.appendingPathComponent("ui-\(section)-\(theme).png")
                try png.write(to: destination)
                print(destination.path)
            }
        }
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
