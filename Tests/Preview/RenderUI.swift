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
        if CommandLine.arguments.contains("--updates-only") {
            try await renderSeamlessUpdateStates(output: output)
            return
        }
        let domain = "MyWallpaperUIPreview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw PreviewFailure(message: "Cannot create isolated preferences.")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.language = .russian
        preferences.restoreOnLaunch = false
        preferences.wallpaperEnabled = false
        preferences.globalPowerRules = .init()
        preferences.currentWallpaperUsesGlobalPowerRules = true
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
        let libraryFixtures = output.appendingPathComponent("ScreenSaverPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: libraryFixtures) }
        let template = output.deletingLastPathComponent().appendingPathComponent("MyWallpaper.saver")
        let wallpapers = WallpaperLibraryController(library: WallpaperLibrary(
            rootURL: libraryFixtures.appendingPathComponent("Wallpapers/Saved")))
        let syncStore = ScreenSaverSyncStore(rootURL: libraryFixtures.appendingPathComponent("Sync/Saved"))
        let syncInstallationDirectory = libraryFixtures.appendingPathComponent("InstalledScreenSavers")
        let syncInstallation = ScreenSaverSyncInstallation(directories: [syncInstallationDirectory])
        if CommandLine.arguments.count > 2 {
            let video = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            for name in ["Ночной сад", "Тихий берег", "Aurora — northern lights over the mountains"] {
                var options = WallpaperLibraryOptions()
                options.volume = 0.35
                options.syncSystemWallpaper = true
                if name == "Тихий берег" {
                    options.usesGlobalPowerRules = false
                    options.animateOnBattery = true
                }
                guard let entry = await wallpapers.addVideo(video, options: options),
                      let renamed = await wallpapers.rename(entry, name: name) else {
                    throw PreviewFailure(message: "Could not create the isolated wallpaper library fixture.")
                }
                preferences.activeWallpaperID = renamed.id
            }
        }
        let model = WallpaperModel(preferences: preferences, loginItems: loginItems,
                                   powerMonitor: PreviewPowerMonitor(), updates: updates,
                                   screenSaver: ScreenSaverController(templateURL: template,
                                    library: ScreenSaverLibrary(rootURL: libraryFixtures.appendingPathComponent("Saved")),
                                    openInstaller: { _ in false }), wallpaperLibrary: wallpapers,
                                   screenSaverSync: ScreenSaverSyncController(
                                    store: syncStore, templateURL: template,
                                    installationLookup: { syncInstallation.installedBundleURL(syncRootURL: $0) },
                                    openInstaller: { _ in false }))
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
        if let video = model.selectedURL {
            model.screenSaver.selectVideo(video)
            let deadline = Date().addingTimeInterval(15)
            while model.screenSaver.isPreparing && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard model.screenSaver.thumbnail != nil else {
                throw PreviewFailure(message: "Could not prepare the screen saver preview.")
            }
            if model.screenSaver.hasTemplate {
                for name in ["Северное сияние", "Лунный берег"] {
                    model.screenSaver.name = name
                    await model.screenSaver.saveToLibrary()
                    guard model.screenSaver.failure == nil else {
                        throw PreviewFailure(message: "Could not create the isolated screen saver library fixture.")
                    }
                }
            }
        }
        await model.screenSaver.reloadLibrary()

        try await renderReadmeScreenshots(model: model, output: output)

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
                                        powerMonitor: PreviewPowerMonitor(), updates: emptyUpdates,
                                        screenSaver: ScreenSaverController(templateURL: template,
                                         library: ScreenSaverLibrary(rootURL: libraryFixtures.appendingPathComponent("Empty")),
                                         openInstaller: { _ in false }),
                                        wallpaperLibrary: WallpaperLibraryController(library: WallpaperLibrary(
                                            rootURL: libraryFixtures.appendingPathComponent("Wallpapers/Empty"))),
                                        screenSaverSync: ScreenSaverSyncController(
                                            store: ScreenSaverSyncStore(rootURL: libraryFixtures.appendingPathComponent("Sync/Empty")),
                                            templateURL: template, openInstaller: { _ in false }))
        await emptyModel.screenSaver.reloadLibrary()
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
                try await capture(emptyModel, section: .screenSaver, scheme: scheme, size: variant.size,
                                  to: output.appendingPathComponent("ui-screenSaver-empty-\(theme)\(variant.suffix).png"))
            }
        }
        try await renderUpdateStates(output: output, sizes: sizes, libraryRoot: libraryFixtures)
        try await renderSeamlessUpdateStates(output: output)
        try await renderLoginStates(output: output, libraryRoot: libraryFixtures)
        try await renderLocalizedAudioStates(model: model, output: output)
        try await renderWallpaperLibrary(model: model, output: output)
        try await renderScreenSaverSync(model: model, output: output, store: syncStore,
                                       installationDirectory: syncInstallationDirectory, template: template)
        if let video = model.selectedURL {
            model.screenSaver.beginCreating()
            model.screenSaver.selectVideo(video)
            let deadline = Date().addingTimeInterval(15)
            while model.screenSaver.isPreparing && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            for language in [AppLanguage.russian, .english] {
                model.language = language
                for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                    try await capture(model, section: .screenSaver, scheme: scheme,
                                      size: NSSize(width: 820, height: 616),
                                      to: output.appendingPathComponent("ui-screenSaver-create-\(language.rawValue)-\(theme).png"))
                }
            }
        }
    }

    @MainActor
    private static func renderScreenSaverSync(model: WallpaperModel, output: URL, store: ScreenSaverSyncStore,
                                              installationDirectory: URL, template: URL) async throws {
        guard let video = model.selectedURL else { return }
        model.syncScreenSaver = true
        model.synchronizeScreenSaver()
        await model.screenSaverSync.waitForSynchronization()
        guard model.screenSaverSync.snapshot != nil, model.screenSaverSync.failure == nil else {
            throw PreviewFailure(message: "Could not prepare the isolated linked screen saver preview.")
        }
        for (code, language) in [("ru", AppLanguage.russian), ("en", .english)] {
            model.language = language
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                try await capture(model, section: .screenSaver, scheme: scheme,
                                  size: NSSize(width: 820, height: 616),
                                  to: output.appendingPathComponent("ui-saver-sync-ready-\(code)-\(theme).png"))
            }
        }
        if model.screenSaverSync.hasTemplate {
            // Simulate installation in the isolated preview fixture only.
            let installer = try await Task.detached { try store.prepareInstaller(templateURL: template) }.value
            try FileManager.default.createDirectory(at: installationDirectory, withIntermediateDirectories: true)
            let installed = installationDirectory.appendingPathComponent(installer.lastPathComponent)
            try FileManager.default.copyItem(at: installer, to: installed)
            await model.screenSaverSync.refreshInstallation()
            guard model.screenSaverSync.isInstalled else {
                throw PreviewFailure(message: "The linked screen saver installation fixture was not detected.")
            }
            for (code, language) in [("ru", AppLanguage.russian), ("en", .english)] {
                model.language = language
                for (theme, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                    try await capture(model, section: .screenSaver, scheme: scheme,
                                      size: NSSize(width: 820, height: 616),
                                      to: output.appendingPathComponent("ui-saver-sync-installed-\(code)-\(theme).png"))
                }
            }
            try FileManager.default.removeItem(at: installed)
            await model.screenSaverSync.refreshInstallation()
            guard !model.screenSaverSync.isInstalled else {
                throw PreviewFailure(message: "A removed linked screen saver still appears installed.")
            }
            model.language = .russian
            try await capture(model, section: .screenSaver, scheme: .dark,
                              size: NSSize(width: 820, height: 616),
                              to: output.appendingPathComponent("ui-saver-sync-removed-ru-dark.png"))
        }
        let missing = video.deletingLastPathComponent().appendingPathComponent("missing-preview-video.mp4")
        model.screenSaverSync.synchronize(videoURL: missing, name: "Unavailable preview", options: .init())
        await model.screenSaverSync.waitForSynchronization()
        guard model.screenSaverSync.failure != nil else {
            throw PreviewFailure(message: "The linked screen saver error fixture did not fail.")
        }
        model.language = .english
        try await capture(model, section: .screenSaver, scheme: .light,
                          size: NSSize(width: 820, height: 616),
                          to: output.appendingPathComponent("ui-saver-sync-error-en-light.png"))
        model.screenSaverSync.dismissFailure()
        model.syncScreenSaver = false
        guard !model.hasWallpaper && !model.isPlaying else {
            throw PreviewFailure(message: "The linked screen saver preview unexpectedly enabled desktop playback.")
        }
    }

    @MainActor
    private static func renderReadmeScreenshots(model: WallpaperModel, output: URL) async throws {
        guard let active = model.wallpaperLibrary.entries.first(where: { $0.id == model.activeWallpaperID }),
              let exception = model.wallpaperLibrary.entries.first(where: { !$0.options.usesGlobalPowerRules }) else { return }
        let originalLanguage = model.language
        let originalOptions = model.currentWallpaperOptions
        let originalEntries = model.wallpaperLibrary.entries
        var editorOptions = originalOptions
        editorOptions.syncSystemWallpaper = false
        guard await model.updateWallpaper(active, options: editorOptions) else {
            throw PreviewFailure(message: "Could not prepare the README editor fixture.")
        }

        for (code, language) in [("ru", AppLanguage.russian), ("en", AppLanguage.english)] {
            model.language = language
            for entry in originalEntries {
                let name: String
                if entry.id == active.id {
                    name = "Aurora"
                } else if entry.id == exception.id {
                    name = code == "ru" ? "Aurora — свой режим" : "Aurora — custom rules"
                } else {
                    name = code == "ru" ? "Aurora — тихий вечер" : "Aurora — quiet evening"
                }
                guard await model.wallpaperLibrary.rename(entry, name: name) != nil else {
                    throw PreviewFailure(message: "Could not localize the README library fixture.")
                }
            }
            guard let current = model.wallpaperLibrary.entries.first(where: { $0.id == active.id }),
                  let custom = model.wallpaperLibrary.entries.first(where: { $0.id == exception.id }) else {
                throw PreviewFailure(message: "The README library fixture is incomplete.")
            }
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                try await capture(model, section: .wallpaper, scheme: scheme,
                                  size: NSSize(width: 980, height: 736),
                                  to: output.appendingPathComponent("readme-wallpaper-\(code)-\(theme).png"))
                try await captureView(WallpaperOptionsSheet(model: model, library: model.wallpaperLibrary,
                                      entry: current, onOpenPower: {}),
                                      scheme: scheme, size: NSSize(width: 560, height: 560),
                                      to: output.appendingPathComponent("readme-wallpaper-editor-\(code)-\(theme).png"))
                try await capture(model, section: .power, scheme: scheme,
                                  size: NSSize(width: 820, height: 616),
                                  to: output.appendingPathComponent("readme-power-\(code)-\(theme).png"))
                try await captureView(WallpaperOptionsSheet(model: model, library: model.wallpaperLibrary,
                                      entry: custom, onOpenPower: {}),
                                      scheme: scheme, size: NSSize(width: 560, height: 560), scrollToBottom: true,
                                      to: output.appendingPathComponent("readme-wallpaper-power-exception-\(code)-\(theme).png"))
            }
        }
        for entry in originalEntries {
            guard await model.wallpaperLibrary.rename(entry, name: entry.name) != nil else {
                throw PreviewFailure(message: "Could not restore the UI verification fixture.")
            }
        }
        guard await model.updateWallpaper(active, options: originalOptions), !model.hasWallpaper && !model.isPlaying else {
            throw PreviewFailure(message: "The README render changed playback or could not restore its fixture.")
        }
        model.language = originalLanguage
    }

    @MainActor
    private static func renderWallpaperLibrary(model: WallpaperModel, output: URL) async throws {
        guard let entry = model.wallpaperLibrary.entries.first else { return }
        for (code, language) in [("ru", AppLanguage.russian), ("en", AppLanguage.english)] {
            model.language = language
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                try await capture(model, section: .wallpaper, scheme: scheme,
                                  size: NSSize(width: 820, height: 616),
                                  to: output.appendingPathComponent("ui-wallpaper-library-\(code)-\(theme)-compact.png"))
                try await captureView(WallpaperOptionsSheet(model: model, library: model.wallpaperLibrary, entry: entry, onOpenPower: {}),
                                      scheme: scheme, size: NSSize(width: 560, height: 560),
                                      to: output.appendingPathComponent("ui-wallpaper-options-\(code)-\(theme)-compact.png"))
                try await captureView(WallpaperOptionsSheet(model: model, library: model.wallpaperLibrary, entry: entry, onOpenPower: {}),
                                      scheme: scheme, size: NSSize(width: 560, height: 560), scrollToBottom: true,
                                      to: output.appendingPathComponent("ui-wallpaper-inherited-power-\(code)-\(theme).png"))
                if let exception = model.wallpaperLibrary.entries.first(where: { !$0.options.usesGlobalPowerRules }) {
                    try await captureView(WallpaperOptionsSheet(model: model, library: model.wallpaperLibrary, entry: exception, onOpenPower: {}),
                                          scheme: scheme, size: NSSize(width: 560, height: 560), scrollToBottom: true,
                                          to: output.appendingPathComponent("ui-wallpaper-custom-power-\(code)-\(theme).png"))
                }
            }
        }
        guard !model.hasWallpaper && !model.isPlaying else {
            throw PreviewFailure(message: "The wallpaper library preview unexpectedly enabled playback.")
        }
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
                    try await captureView(WallpaperOptionsSheet(model: model, library: model.wallpaperLibrary,
                                          entry: model.wallpaperLibrary.entries.first(where: { $0.id == model.activeWallpaperID }), onOpenPower: {}),
                                          scheme: scheme, size: NSSize(width: 560, height: 560), scrollToBottom: true,
                                          to: output.appendingPathComponent(name))
                }
            }
        }
    }

    @MainActor
    private static func renderUpdateStates(output: URL, sizes: [(suffix: String, size: NSSize)], libraryRoot: URL) async throws {
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
                                       powerMonitor: PreviewPowerMonitor(), updates: updates,
                                       wallpaperLibrary: WallpaperLibraryController(library: WallpaperLibrary(
                                           rootURL: libraryRoot.appendingPathComponent("Wallpapers/Updates-\(scenario.rawValue)"))),
                                       screenSaverSync: ScreenSaverSyncController(
                                           store: ScreenSaverSyncStore(rootURL: libraryRoot.appendingPathComponent("Sync/Updates-\(scenario.rawValue)")),
                                           templateURL: nil, openInstaller: { _ in false }))
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
    private static func renderSeamlessUpdateStates(output: URL) async throws {
        let domain = "MyWallpaperUIInstallerPreview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw PreviewFailure(message: "Missing preview preferences.") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let response = try updateResponse(version: "0.11.0")
        let installation = UpdateInstallationController(currentBuild: "12", serviceFactory: { _, _ in PreviewInstallationService() })
        installation.prepareForRelaunch = { _ in }
        let updates = UpdateController(currentVersion: "0.10.0", defaults: defaults,
                                       transport: { _ in response }, installation: installation)
        await updates.checkNow()
        for (code, language) in [("ru", AppLanguage.russian), ("en", AppLanguage.english)] {
            let localizer = AppLocalizer(language: language)
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                try await captureView(WhatsNewView(release: WhatsNewRelease.bundled[0], localizer: localizer, onClose: {}),
                                      scheme: scheme, size: NSSize(width: 540, height: 570),
                                      to: output.appendingPathComponent("ui-whats-new-\(code)-\(theme).png"))
                try await captureView(updatePreview(updates, localizer: localizer),
                                      scheme: scheme, size: NSSize(width: 720, height: 700),
                                      to: output.appendingPathComponent("ui-update-install-\(code)-\(theme).png"))
            }
        }
        updates.installAvailableRelease()
        guard let id = installation.activeSessionID else { throw PreviewFailure(message: "Missing preview installation session.") }
        installation.downloading(cancellation: {}, sessionID: id)
        installation.receivedExpectedLength(25_000_000, sessionID: id)
        installation.receivedData(12_000_000, sessionID: id)
        try await captureView(updatePreview(updates, localizer: .russian), scheme: .dark,
                              size: NSSize(width: 720, height: 700),
                              to: output.appendingPathComponent("ui-update-downloading-ru-dark.png"))
        installation.fail(UpdateInstallFailure(message: "Не удалось установить обновление. Текущая версия продолжает работать."), sessionID: id)
        try await captureView(updatePreview(updates, localizer: AppLocalizer(language: .english)),
                              scheme: .light, size: NSSize(width: 720, height: 700),
                              to: output.appendingPathComponent("ui-update-failed-en-light.png"))
    }

    @MainActor
    private static func updatePreview(_ updates: UpdateController, localizer: AppLocalizer) -> some View {
        ScrollView {
            UpdateSettingsPane(updates: updates, localizer: localizer)
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .frame(width: 720, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @MainActor
    private static func renderLoginStates(output: URL, libraryRoot: URL) async throws {
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
                                       powerMonitor: PreviewPowerMonitor(), updates: updates,
                                       wallpaperLibrary: WallpaperLibraryController(library: WallpaperLibrary(
                                           rootURL: libraryRoot.appendingPathComponent("Wallpapers/Login-\(scenario.rawValue)"))),
                                       screenSaverSync: ScreenSaverSyncController(
                                           store: ScreenSaverSyncStore(rootURL: libraryRoot.appendingPathComponent("Sync/Login-\(scenario.rawValue)")),
                                           templateURL: nil, openInstaller: { _ in false }))
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
        try await captureView(ControlView(model: model, navigation: navigation), scheme: scheme, size: size, to: destination)
    }

    @MainActor
    private static func captureView<Content: View>(_ content: Content, scheme: ColorScheme,
                                                  size: NSSize, scrollToBottom: Bool = false, to destination: URL) async throws {
        let bounds = NSRect(origin: .zero, size: size)
        let root = content
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
        if scrollToBottom {
            func findScrollView(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { findScrollView($0) }.first
            }
            guard let scroll = findScrollView(hosting), let document = scroll.documentView else {
                throw PreviewFailure(message: "The editor preview did not expose its scrollable content.")
            }
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
        }
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

@MainActor
private final class PreviewInstallationService: UpdateInstallationService {
    func start() throws {}
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
