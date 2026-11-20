import AppKit
import Combine
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct UnifiedWallpaperSettingsModelTests {
    @Test
    func legacyCurrentAndSavedOptionsRemainIndependentUntilExplicitSaveAcrossRelaunch() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create(options: .init(volume: 0.8))
        try removeInheritanceMarker(entry, fixture: fixture)
        let originalMetadata = try Data(contentsOf: fixture.metadata(entry.id))
        try await withPreferences { preferences, defaults in
            preferences.activeWallpaperID = entry.id
            preferences.volume = 0.2
            preferences.scaling = .fit
            preferences.animateOnBattery = true
            preferences.pauseWhenCovered = false
            let expectedPower = WallpaperPowerRules(animateOnBattery: true, pauseWhenCovered: false)
            let model = makeModel(fixture, preferences: preferences, defaults: defaults)
            model.restore()
            try await waitForSelection(model)
            #expect(model.hasLegacyCurrentSettings)
            #expect(model.effectivePowerRules == expectedPower && model.globalPowerRules == expectedPower)
            #expect(abs(model.volume - 0.2) < 0.0001 && model.scaling == .fit)
            #expect(model.editorOptions(for: entry).volume == model.volume)
            #expect(try Data(contentsOf: fixture.metadata(entry.id)) == originalMetadata)
            await model.toggleCurrentWallpaperMute()
            #expect(!model.isMuted && !preferences.isMuted)
            #expect(model.hasLegacyCurrentSettings && preferences.legacyCurrentWallpaperID == entry.id)
            #expect(try Data(contentsOf: fixture.metadata(entry.id)) == originalMetadata,
                    "Quick mute must not promote all pending current settings into the saved preset.")
            // The global policy changes without rewriting this legacy current
            // exception or the saved card. A second launch must not seed globals
            // from the different effective cache again.
            model.animateOnBattery = false
            model.shutDown()
            let restored = makeModel(fixture, preferences: preferences, defaults: defaults)
            defer { restored.shutDown() }
            restored.restore()
            try await waitForSelection(restored)
            #expect(restored.hasLegacyCurrentSettings && preferences.legacyCurrentWallpaperID == entry.id)
            #expect(!restored.globalPowerRules.animateOnBattery && restored.effectivePowerRules.animateOnBattery)
            #expect(abs(restored.volume - 0.2) < 0.0001 && restored.scaling == .fit)
            #expect(!restored.isMuted, "The legacy current mute choice must survive relaunch independently of the preset.")
            #expect(try Data(contentsOf: fixture.metadata(entry.id)) == originalMetadata)
            let base = restored.editorOptions(for: entry)
            var edited = base
            edited.scaling = .fill
            #expect(await restored.updateWallpaper(entry, options: edited, originalOptions: base))
            #expect(!restored.hasLegacyCurrentSettings && preferences.legacyCurrentWallpaperID == nil)
            #expect(abs(restored.volume - 0.2) < 0.0001, "Saving just scaling must preserve the current pre-upgrade volume.")
            #expect(try fixture.library.entry(for: entry.id).options == restored.currentWallpaperOptions)
        }
    }

    @Test
    func failedLoadAndFailedSaveKeepPendingLegacySettingsAndPresets() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create(options: .init(volume: 0.8))
        try await withPreferences { preferences, defaults in
            preferences.activeWallpaperID = entry.id
            preferences.volume = 0.2
            let model = makeModel(fixture, preferences: preferences, defaults: defaults)
            defer { model.shutDown() }
            model.restore()
            try await waitForSelection(model)
            let current = model.currentWallpaperOptions
            let selected = model.selectedURL
            model.selectVideo(fixture.root.appendingPathComponent("missing.mp4"))
            try await eventually { !model.isLoading }
            #expect(model.hasLegacyCurrentSettings && model.selectedURL == selected)
            #expect(model.currentWallpaperOptions == current)
            #expect(try fixture.library.entry(for: entry.id).options == entry.options)
            let metadata = fixture.metadata(entry.id)
            let originalMetadata = try Data(contentsOf: metadata)
            try Data("Broken metadata: writes must fail without altering live settings.".utf8).write(to: metadata)
            var edited = current
            edited.volume = 0.7
            #expect(!(await model.updateWallpaper(entry, options: edited)))
            #expect(model.hasLegacyCurrentSettings && model.currentWallpaperOptions == current)
            #expect(preferences.legacyCurrentWallpaperID == entry.id)
            try originalMetadata.write(to: metadata)
        }
    }

    @Test
    func explicitOverridesAndInheritanceNeverReplaceGlobalRulesAndSurviveRelaunch() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        try await withPreferences { preferences, defaults in
            preferences.globalPowerRules = .init()
            preferences.activeWallpaperID = entry.id
            let model = makeModel(fixture, preferences: preferences, defaults: defaults)
            model.restore()
            try await waitForSelection(model)
            #expect(!model.hasLegacyCurrentSettings && model.activeWallpaperUsesGlobalPowerRules)
            model.animateOnBattery = true
            #expect(model.effectivePowerRules.animateOnBattery)
            let globals = model.globalPowerRules
            var options = model.editorOptions(for: entry)
            options.usesGlobalPowerRules = false
            options.powerRules = .init(animateOnExternalPower: false, animateOnBattery: false,
                                       pauseInLowPowerMode: false, pauseWhenCovered: false)
            #expect(await model.updateWallpaper(entry, options: options))
            #expect(model.globalPowerRules == globals)
            #expect(model.effectivePowerRules == options.powerRules)
            model.pauseWhenCovered = false
            model.pauseInLowPowerMode = false
            #expect(model.effectivePowerRules == options.powerRules)
            let expectedGlobals = model.globalPowerRules
            model.shutDown()
            let restored = makeModel(fixture, preferences: preferences, defaults: defaults)
            defer { restored.shutDown() }
            restored.restore()
            try await waitForSelection(restored)
            #expect(restored.globalPowerRules == expectedGlobals)
            #expect(restored.effectivePowerRules == options.powerRules)
            #expect(!restored.activeWallpaperUsesGlobalPowerRules)
            var inherited = restored.editorOptions(for: entry)
            inherited.usesGlobalPowerRules = true
            #expect(await restored.updateWallpaper(entry, options: inherited))
            #expect(restored.effectivePowerRules == expectedGlobals)
            #expect(restored.activeWallpaperUsesGlobalPowerRules)
            restored.animateOnExternalPower = false
            #expect(!restored.effectivePowerRules.animateOnExternalPower)
            #expect(try fixture.library.entry(for: entry.id).options.usesGlobalPowerRules)
        }
    }

    @Test
    func staleEditorPreservesQuickMuteAndGlobalChangesWhenSavingOnlyScaling() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        try await withPreferences { preferences, defaults in
            preferences.globalPowerRules = .init()
            preferences.activeWallpaperID = entry.id
            let model = makeModel(fixture, preferences: preferences, defaults: defaults)
            defer { model.shutDown() }
            model.restore()
            try await waitForSelection(model)
            let original = model.editorOptions(for: entry)
            var draft = original
            draft.scaling = .fit
            await model.toggleCurrentWallpaperMute()
            model.animateOnBattery = true
            #expect(!model.isMuted && model.effectivePowerRules.animateOnBattery)
            #expect(await model.updateWallpaper(entry, options: draft, originalOptions: original))
            #expect(!model.isMuted && model.scaling == .fit)
            #expect(model.activeWallpaperUsesGlobalPowerRules && model.effectivePowerRules.animateOnBattery)
            let saved = try fixture.library.entry(for: entry.id).options
            #expect(!saved.isMuted && saved.scaling == .fit && saved.usesGlobalPowerRules)
        }
    }

    @Test
    func externalEditorRejectsAChangedSelectionAndKeepsSettingsUntilSave() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        try await withPreferences { preferences, defaults in
            preferences.globalPowerRules = .init()
            preferences.videoBookmark = try fixture.video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let model = makeModel(fixture, preferences: preferences, defaults: defaults)
            defer { model.shutDown() }
            model.restore()
            try await waitForSelection(model)
            let original = model.currentWallpaperOptions
            var draft = original
            draft.scaling = .fit
            #expect(!(await model.updateCurrentWallpaper(options: draft, originalOptions: original,
                expectedURL: fixture.root.appendingPathComponent("other.mov"))))
            #expect(model.currentWallpaperOptions == original)
            #expect(await model.updateCurrentWallpaper(options: draft, originalOptions: original, expectedURL: model.selectedURL))
            #expect(model.scaling == .fit && preferences.scaling == .fit)
            #expect(model.activeWallpaperID == nil && model.wallpaperLibrary.entries.isEmpty)
            var custom = model.currentWallpaperOptions
            custom.usesGlobalPowerRules = false
            custom.powerRules = .init(animateOnExternalPower: false, animateOnBattery: true,
                                      pauseInLowPowerMode: false, pauseWhenCovered: false)
            #expect(await model.updateCurrentWallpaper(options: custom, expectedURL: model.selectedURL))
            model.shutDown()
            let restored = makeModel(fixture, preferences: preferences, defaults: defaults)
            defer { restored.shutDown() }
            restored.restore()
            try await waitForSelection(restored)
            #expect(restored.currentWallpaperOptions == custom)
            #expect(!restored.activeWallpaperUsesGlobalPowerRules)
            #expect(restored.globalPowerRules == WallpaperPowerRules())
        }
    }

    @Test
    func linkedSaverUsesEffectivePermanentRulesAndIgnoresUnrelatedGlobalChanges() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        try await withPreferences { preferences, defaults in
            preferences.globalPowerRules = .init()
            preferences.activeWallpaperID = entry.id
            let model = makeModel(fixture, preferences: preferences, defaults: defaults)
            defer { model.shutDown() }
            model.restore()
            try await waitForSelection(model)
            model.syncScreenSaver = true
            await model.screenSaverSync.waitForSynchronization()
            var options = model.editorOptions(for: entry)
            options.usesGlobalPowerRules = false
            options.powerRules = .init(animateOnExternalPower: false, animateOnBattery: true,
                                       pauseInLowPowerMode: false, pauseWhenCovered: false)
            #expect(await model.updateWallpaper(entry, options: options))
            await model.screenSaverSync.waitForSynchronization()
            let overridden = try #require(model.screenSaverSync.snapshot)
            #expect(overridden.animateOnBattery && !overridden.animateOnExternalPower && !overridden.pauseInLowPowerMode)
            await model.toggleCurrentWallpaperMute()
            #expect(!model.isMuted && !model.screenSaverSync.isSynchronizing,
                    "Quick mute must save audio without republishing the linked saver.")
            var desktopOnly = model.currentWallpaperOptions
            desktopOnly.pauseWhenCovered = true
            desktopOnly.volume = 0.25
            desktopOnly.target = .main
            #expect(await model.updateWallpaper(entry, options: desktopOnly))
            #expect(!model.screenSaverSync.isSynchronizing && model.screenSaverSync.snapshot == overridden,
                    "Desktop-only editor changes must not republish the linked saver.")
            model.animateOnBattery = true
            model.animateOnExternalPower = false
            #expect(!model.screenSaverSync.isSynchronizing)
            #expect(model.screenSaverSync.snapshot == overridden)
            options.usesGlobalPowerRules = true
            #expect(await model.updateWallpaper(entry, options: options))
            await model.screenSaverSync.waitForSynchronization()
            let inherited = try #require(model.screenSaverSync.snapshot)
            #expect(inherited.pauseInLowPowerMode && inherited.animateOnBattery && !inherited.animateOnExternalPower)
            #expect(model.globalPowerRules.pauseWhenCovered)
        }
    }

    private func removeInheritanceMarker(_ entry: WallpaperLibraryEntry, fixture: WallpaperLibraryFixture) throws {
        let url = fixture.metadata(entry.id)
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var savedEntry = try #require(metadata["entry"] as? [String: Any])
        var options = try #require(savedEntry["options"] as? [String: Any])
        options.removeValue(forKey: "usesGlobalPowerRules")
        savedEntry["options"] = options
        metadata["entry"] = savedEntry
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: url)
    }

    private func makeModel(_ fixture: WallpaperLibraryFixture, preferences: WallpaperPreferences,
                           defaults: UserDefaults) -> WallpaperModel {
        WallpaperModel(preferences: preferences,
            loginItems: LoginItemController(service: UnifiedSettingsLogin(), notificationCenter: NotificationCenter()),
            powerMonitor: UnifiedSettingsPower(),
            updates: UpdateController(currentVersion: "0.8.0", defaults: defaults, transport: { _ in
                Issue.record("Unified settings tests must not check updates."); throw URLError(.cancelled)
            }), systemWallpaperSync: UnifiedSettingsDesktop(),
            wallpaperLibrary: WallpaperLibraryController(library: fixture.library, prepareVideo: { _ in fixture.poster }),
            screenSaverSync: ScreenSaverSyncController(store: .init(rootURL: fixture.root.appendingPathComponent("Sync")),
                templateURL: nil, prepareVideo: { _ in fixture.poster }, installationLookup: { _ in nil },
                openInstaller: { _ in Issue.record("Tests must not open installers."); return false }))
    }

    private func withPreferences(_ body: @MainActor (WallpaperPreferences, UserDefaults) async throws -> Void) async throws {
        let domain = "UnifiedWallpaperSettingsModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.restoreOnLaunch = false
        preferences.wallpaperEnabled = false
        try await body(preferences, defaults)
    }

    private func waitForSelection(_ model: WallpaperModel) async throws {
        try await eventually { model.selectedURL != nil && !model.isWorkingWithWallpapers }
        #expect(model.errorMessage == nil)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "Timed out waiting for settings operation.")
    }
}

@MainActor private final class UnifiedSettingsLogin: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { Issue.record("Tests must not change login items.") }
    func unregister() throws { Issue.record("Tests must not change login items.") }
    func openSystemSettings() { Issue.record("Tests must not open System Settings.") }
}
@MainActor private final class UnifiedSettingsPower: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}
@MainActor private final class UnifiedSettingsDesktop: SystemWallpaperSyncing {
    func synchronize(image: CGImage, name: String, target: DisplayTarget, scaling: VideoScaling) async throws {
        Issue.record("Metadata tests must not change system wallpaper.")
    }
}
