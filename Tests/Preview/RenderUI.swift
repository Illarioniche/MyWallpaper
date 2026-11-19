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
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.language = .russian
        preferences.restoreOnLaunch = false
        preferences.wallpaperEnabled = false
        if CommandLine.arguments.count > 2 {
            let video = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            preferences.videoBookmark = try video.bookmarkData(options: [],
                                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let loginItems = LoginItemController(service: PreviewLoginService(), notificationCenter: NotificationCenter())
        let currentResponse = try updateResponse(version: "0.4.0")
        let updates = UpdateController(currentVersion: "0.4.0", defaults: defaults,
                                       transport: { _ in currentResponse })
        await updates.checkNow()
        guard case .upToDate = updates.state else {
            throw PreviewFailure(message: "The current-version fixture was not accepted.")
        }
        let model = WallpaperModel(preferences: preferences, loginItems: loginItems,
                                   powerMonitor: PreviewPowerMonitor(), updates: updates)
        defer {
            model.shutDown()
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
        defer { emptyDefaults.removePersistentDomain(forName: emptyDomain) }
        let emptyPreferences = WallpaperPreferences(defaults: emptyDefaults)
        emptyPreferences.language = .russian
        emptyPreferences.restoreOnLaunch = false
        emptyPreferences.wallpaperEnabled = false
        let emptyLoginItems = LoginItemController(service: PreviewLoginService(), notificationCenter: NotificationCenter())
        let emptyUpdates = UpdateController(currentVersion: "0.4.0", defaults: emptyDefaults,
                                            transport: { _ in currentResponse })
        await emptyUpdates.checkNow()
        let emptyModel = WallpaperModel(preferences: emptyPreferences, loginItems: emptyLoginItems,
                                        powerMonitor: PreviewPowerMonitor(), updates: emptyUpdates)
        defer {
            emptyModel.shutDown()
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
        try await renderUpdateStates(output: output, sizes: sizes)
        try await renderLoginStates(output: output)
        try await renderLocalizedAudioStates(model: model, output: output)
    }

    @MainActor
    private static func renderLocalizedAudioStates(model: WallpaperModel, output: URL) async throws {
        let size = NSSize(width: 820, height: 616)
        let themes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]
        model.language = .english
        for (theme, scheme) in themes {
            for section in AppSection.allCases {
                let name = "ui-en-\(section.rawValue)-\(theme)-compact.png"
                try await capture(model, section: section, scheme: scheme,
                                  size: size, to: output.appendingPathComponent(name))
            }
        }

        // A non-default level remains available while muted. These models have
        // no wallpaper surfaces, so neither state can play video or produce sound.
        model.volume = 0.35
        for (code, language) in [("ru", AppLanguage.russian), ("en", AppLanguage.english)] {
            model.language = language
            for isMuted in [true, false] {
                model.isMuted = isMuted
                guard !model.hasWallpaper, !model.isPlaying, abs(model.volume - 0.35) < 0.000_001 else {
                    throw PreviewFailure(message: "The audio preview changed playback or its saved level.")
                }
                for (theme, scheme) in themes {
                    let state = isMuted ? "muted" : "unmuted"
                    let name = "ui-audio-\(code)-\(state)-\(theme)-compact.png"
                    try await capture(model, section: .general, scheme: scheme,
                                      size: size, to: output.appendingPathComponent(name))
                }
            }
        }
    }

    @MainActor
    private static func renderUpdateStates(output: URL, sizes: [(suffix: String, size: NSSize)]) async throws {
        for scenario in PreviewUpdateScenario.allCases {
            let response = try updateResponse(version: scenario == .available ? "1.0.0" : "0.4.0")
            let domain = "MyWallpaperUIUpdatesPreview.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: domain) else {
                throw PreviewFailure(message: "Cannot create isolated update preferences.")
            }
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.language = .russian
            preferences.restoreOnLaunch = false
            preferences.wallpaperEnabled = false
            let gate = PreviewUpdateGate()
            let updates = UpdateController(currentVersion: "0.4.0", defaults: defaults, transport: { _ in
                switch scenario {
                case .available, .latest: return response
                case .offline: throw URLError(.notConnectedToInternet)
                case .checking: return await gate.response()
                }
            })
            let loginItems = LoginItemController(service: PreviewLoginService(), notificationCenter: NotificationCenter())
            let model = WallpaperModel(preferences: preferences, loginItems: loginItems,
                                       powerMonitor: PreviewPowerMonitor(), updates: updates)
            defer {
                model.shutDown()
            }
            let checkTask = Task { await updates.checkNow() }
            if scenario == .checking {
                await gate.waitUntilRequested()
            } else {
                await checkTask.value
            }
            do {
                switch (scenario, updates.state) {
                case (.available, .available(let release)):
                    guard release.downloadURL != nil, release.checksumURL != nil else {
                        throw PreviewFailure(message: "The available-update fixture has no download links.")
                    }
                case (.latest, .upToDate), (.offline, .failed), (.checking, .checking): break
                default: throw PreviewFailure(message: "Unexpected update fixture state: \(scenario.rawValue).")
                }
                for variant in sizes {
                    for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                        let name = "ui-updates-\(scenario.rawValue)-\(theme)\(variant.suffix).png"
                        try await capture(model, section: .updates, scheme: scheme,
                                          size: variant.size, to: output.appendingPathComponent(name))
                        if scenario == .available {
                            let bannerName = "ui-update-banner-wallpaper-\(theme)\(variant.suffix).png"
                            try await capture(model, section: .wallpaper, scheme: scheme,
                                              size: variant.size, to: output.appendingPathComponent(bannerName))
                        }
                    }
                }
            } catch {
                await gate.finish(with: response)
                await checkTask.value
                throw error
            }
            await gate.finish(with: response)
            await checkTask.value
        }
    }

    @MainActor
    private static func renderLoginStates(output: URL) async throws {
        let response = try updateResponse(version: "0.4.0")
        for scenario in PreviewLoginScenario.allCases {
            let domain = "MyWallpaperUILoginPreview.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: domain) else {
                throw PreviewFailure(message: "Cannot create isolated login preferences.")
            }
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.language = .russian
            preferences.restoreOnLaunch = false
            preferences.wallpaperEnabled = false
            let service = PreviewLoginService(
                status: scenario == .notFound ? .notFound : scenario == .readOnly ? .unavailable : .disabled,
                availability: scenario == .readOnly ? .readOnlyVolume : .available
            )
            let loginItems = LoginItemController(service: service, notificationCenter: NotificationCenter())
            let updates = UpdateController(currentVersion: "0.4.0", defaults: defaults, transport: { _ in response })
            await updates.checkNow()
            let model = WallpaperModel(preferences: preferences, loginItems: loginItems,
                                       powerMonitor: PreviewPowerMonitor(), updates: updates)
            defer { model.shutDown() }
            if scenario == .registrationError { model.setLaunchAtLogin(true) }
            guard loginItems.canToggle == (scenario != .readOnly),
                  scenario != .registrationError || loginItems.errorMessage != nil else {
                throw PreviewFailure(message: "Unexpected login fixture state: \(scenario.rawValue).")
            }
            let destination = output.appendingPathComponent("ui-login-\(scenario.rawValue)-light-compact.png")
            try await capture(model, section: .general, scheme: .light,
                              size: NSSize(width: 820, height: 616), to: destination)
        }
    }

    private static func updateResponse(version: String) throws -> UpdateHTTPResponse {
        let releaseURL = "https://github.com/Illarioniche/MyWallpaper/releases"
        let filename = "MyWallpaper-\(version)-universal.dmg"
        let payload: [String: Any] = [
            "tag_name": "v\(version)",
            "name": "MyWallpaper \(version)",
            "body": "Новая версия MyWallpaper готова к загрузке.\n\nУлучшено управление обоями и исправлены ошибки.",
            "draft": false,
            "prerelease": false,
            "html_url": "\(releaseURL)/tag/v\(version)",
            "assets": [filename, "\(filename).sha256"].map { name in
                ["name": name, "state": "uploaded", "browser_download_url": "\(releaseURL)/download/v\(version)/\(name)"]
            }
        ]
        return UpdateHTTPResponse(data: try JSONSerialization.data(withJSONObject: payload), statusCode: 200,
                                  finalURL: GitHubUpdateTransport.endpoint)
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

private enum PreviewUpdateScenario: String, CaseIterable, Sendable {
    case available
    case latest
    case offline
    case checking
}

private enum PreviewLoginScenario: String, CaseIterable {
    case notFound = "not-found"
    case readOnly = "read-only"
    case registrationError = "registration-error"
}

/// Suspends one mock response until every checking-state image has been captured.
/// No timing assumptions or network requests are involved.
private actor PreviewUpdateGate {
    private var responseContinuation: CheckedContinuation<UpdateHTTPResponse, Never>?
    private var requestContinuation: CheckedContinuation<Void, Never>?

    func response() async -> UpdateHTTPResponse {
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
            requestContinuation?.resume()
            requestContinuation = nil
        }
    }

    func waitUntilRequested() async {
        guard responseContinuation == nil else { return }
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func finish(with response: UpdateHTTPResponse) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
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
    let status: LoginItemStatus
    let availability: LoginItemAvailability

    init(status: LoginItemStatus = .disabled, availability: LoginItemAvailability = .available) {
        self.status = status
        self.availability = availability
    }

    func register() throws { throw PreviewFailure(message: "macOS отклонила регистрацию.") }
    func unregister() throws { throw PreviewFailure(message: "Login mutation is disabled in UI preview.") }
    func openSystemSettings() {}
}
