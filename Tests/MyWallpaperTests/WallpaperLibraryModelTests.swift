import AppKit
import Combine
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct WallpaperLibraryModelTests {
    @Test
    func legacyWallpaperRemainsExternalUntilExplicitlySaved() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let bookmark = try fixture.video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await withModel(fixture: fixture, configure: { $0.videoBookmark = bookmark }) { model, preferences in
            model.restore()
            #expect(model.selectedURL?.resolvingSymlinksInPath() == fixture.video.resolvingSymlinksInPath())
            #expect(model.activeWallpaperID == nil && preferences.activeWallpaperID == nil)
            #expect(!model.hasWallpaper && !model.isPlaying)
            #expect(!FileManager.default.fileExists(atPath: fixture.library.rootURL.path))
            #expect(preferences.videoBookmark == bookmark)
        }
    }

    @Test
    func managedRestoreUsesOwnedCopyAndPreservesCurrentUnsavedSettingsWithoutPlaying() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create(options: .init(scaling: .fill, volume: 0.8))
        let copiedVideo = try fixture.library.videoURL(for: entry.id)
        let oldBookmark = try fixture.video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.removeItem(at: fixture.video)
        try await withModel(fixture: fixture, configure: {
            $0.activeWallpaperID = entry.id
            $0.videoBookmark = oldBookmark
            $0.volume = 0.2
            $0.scaling = .fit
        }) { model, preferences in
            model.restore()
            try await eventually { model.selectedURL == copiedVideo && !model.isWorkingWithWallpapers }
            #expect(model.activeWallpaperID == entry.id && model.thumbnail != nil)
            #expect(model.volume == preferences.volume && abs(model.volume - 0.2) < 0.0001)
            #expect(model.scaling == .fit && model.currentWallpaperOptions != entry.options)
            #expect(!model.hasWallpaper && !model.isPlaying && !model.isLoading)
            #expect(try fixture.library.entry(for: entry.id).options == entry.options)
        }
    }

    @Test
    func editingInactiveEntryDoesNotSwitchWallpaperOrCurrentSettings() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let selected = try fixture.create(name: "Selected")
        let edited = try fixture.create(name: "Other")
        let options = WallpaperLibraryOptions(target: .main, scaling: .fit, isMuted: false, volume: 0.35,
            animateOnExternalPower: false, animateOnBattery: true, pauseInLowPowerMode: false,
            pauseWhenCovered: false, syncSystemWallpaper: true)
        try await withModel(fixture: fixture, configure: { $0.activeWallpaperID = selected.id }) { model, _ in
            model.restore()
            try await eventually { model.selectedURL != nil && !model.isWorkingWithWallpapers }
            let before = model.currentWallpaperOptions
            let beforeURL = model.selectedURL
            #expect(await model.updateWallpaper(edited, options: options))
            #expect(model.activeWallpaperID == selected.id && model.selectedURL == beforeURL)
            #expect(model.currentWallpaperOptions == before)
            #expect(try fixture.library.entry(for: edited.id).options == options)
            #expect(!model.hasWallpaper && !model.isSyncingSystemWallpaper)
        }
    }

    @Test
    func savingSelectedEntrySettingsUpdatesPreferencesAndKeepsItsIdentityOnRename() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        try await withModel(fixture: fixture, configure: { $0.activeWallpaperID = entry.id }) { model, preferences in
            model.restore()
            try await eventually { model.selectedURL != nil && !model.isWorkingWithWallpapers }
            model.volume = 0.35
            model.scaling = .fit
            model.animateOnBattery = true
            let current = model.currentWallpaperOptions
            #expect(try fixture.library.entry(for: entry.id).options == entry.options,
                    "Live controls do not silently overwrite the saved library preset.")
            #expect(await model.updateWallpaper(entry, options: current))
            #expect(try fixture.library.entry(for: entry.id).options == current)
            #expect(model.currentWallpaperOptions == current)
            #expect(preferences.volume == current.volume && preferences.scaling == .fit)
            var editorOptions = current
            editorOptions.volume = 0.37
            #expect(await model.updateWallpaper(entry, options: editorOptions))
            #expect(model.currentWallpaperOptions == (try fixture.library.entry(for: entry.id).options),
                    "Applying a saved slider value must not immediately mark the preset as modified.")
            let beforeURL = model.selectedURL
            #expect(await model.renameWallpaper(entry, name: "New name"))
            #expect(model.selectedWallpaperName == "New name")
            #expect(model.activeWallpaperID == entry.id && model.selectedURL == beforeURL)
            #expect(!model.hasWallpaper && !model.isWorkingWithWallpapers)
        }
    }

    @Test
    func deletingSelectedEntryClearsRestorationButPreservesOtherEntriesAndOriginal() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let selected = try fixture.create(name: "Selected")
        let kept = try fixture.create(name: "Keep")
        let bookmark = try fixture.video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await withModel(fixture: fixture, configure: {
            $0.activeWallpaperID = selected.id
            $0.videoBookmark = bookmark
        }) { model, preferences in
            model.restore()
            try await eventually { model.selectedURL != nil && !model.isWorkingWithWallpapers }
            #expect(await model.deleteWallpaper(selected))
            #expect(model.activeWallpaperID == nil && model.selectedURL == nil && model.thumbnail == nil)
            #expect(preferences.activeWallpaperID == nil && preferences.videoBookmark == nil)
            #expect(!preferences.wallpaperEnabled && !model.hasWallpaper && !model.isLoading)
            #expect(try fixture.library.list().entries == [kept])
            #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
            model.restore()
            await Task.yield()
            #expect(model.selectedURL == nil && !model.isWorkingWithWallpapers)
        }
    }

    @Test
    func failedDeletionKeepsSelectionAndRestorationPreferences() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let selected = try fixture.create()
        let bookmark = try fixture.video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await withModel(fixture: fixture, configure: {
            $0.activeWallpaperID = selected.id
            $0.videoBookmark = bookmark
        }) { model, preferences in
            model.restore()
            try await eventually { model.selectedURL != nil && !model.isWorkingWithWallpapers }
            let beforeURL = model.selectedURL
            try Data("invalid metadata".utf8).write(to: fixture.metadata(selected.id))
            #expect(!(await model.deleteWallpaper(selected)))
            #expect(model.activeWallpaperID == selected.id && model.selectedURL == beforeURL)
            #expect(preferences.activeWallpaperID == selected.id && preferences.videoBookmark == bookmark)
            #expect(model.wallpaperLibrary.failure != nil && !model.isWorkingWithWallpapers)
            #expect(FileManager.default.fileExists(atPath: try #require(beforeURL).path))
        }
    }

    @Test
    func missingManagedEntryDoesNotFallBackToUnrelatedExternalBookmark() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let missingID = UUID()
        let bookmark = try fixture.video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await withModel(fixture: fixture, configure: {
            $0.activeWallpaperID = missingID
            $0.videoBookmark = bookmark
        }) { model, _ in
            model.restore()
            try await eventually { model.errorMessage != nil && !model.isWorkingWithWallpapers }
            #expect(model.selectedURL == nil && !model.hasWallpaper && !model.isLoading)
        }
    }

    @Test
    func stopDuringManagedRestorationPreventsLateSelection() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        try await withModel(fixture: fixture, configure: { $0.activeWallpaperID = entry.id }) { model, preferences in
            model.restore()
            model.stop()
            try await eventually { model.wallpaperLibrary.hasLoadedLibrary && !model.isWorkingWithWallpapers }
            #expect(model.selectedURL == nil && !model.hasWallpaper && !preferences.wallpaperEnabled)
        }
    }

    private func withModel(fixture: WallpaperLibraryFixture,
                           configure: (WallpaperPreferences) throws -> Void,
                           body: @MainActor (WallpaperModel, WallpaperPreferences) async throws -> Void) async throws {
        let domain = "WallpaperLibraryModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.restoreOnLaunch = false
        preferences.wallpaperEnabled = false
        try configure(preferences)
        let updates = UpdateController(currentVersion: "0.7.0", defaults: defaults, transport: { _ in
            Issue.record("Library model tests must not request updates.")
            throw URLError(.cancelled)
        })
        let model = WallpaperModel(preferences: preferences,
            loginItems: LoginItemController(service: LibraryModelLoginService(), notificationCenter: NotificationCenter()),
            powerMonitor: LibraryModelPowerMonitor(), updates: updates,
            systemWallpaperSync: LibraryModelSystemWallpaperSpy(),
            wallpaperLibrary: WallpaperLibraryController(library: fixture.library, prepareVideo: { _ in fixture.poster }))
        defer { model.shutDown() }
        try await body(model, preferences)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "Timed out waiting for the library model operation.")
    }
}

@MainActor
private final class LibraryModelSystemWallpaperSpy: SystemWallpaperSyncing {
    func synchronize(image: CGImage, name: String, target: DisplayTarget, scaling: VideoScaling) async throws {
        Issue.record("Library metadata tests must not change the system desktop.")
    }
}

@MainActor
private final class LibraryModelPowerMonitor: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}

@MainActor
private final class LibraryModelLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { Issue.record("Tests must not change login items.") }
    func unregister() throws { Issue.record("Tests must not change login items.") }
    func openSystemSettings() { Issue.record("Tests must not open System Settings.") }
}
