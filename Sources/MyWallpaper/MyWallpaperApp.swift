import AppKit
import Combine
import SwiftUI

@main
enum MyWallpaperApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.applicationIconImage = AppIconArtwork.image(size: 512)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = WallpaperModel()
    private let navigation = AppNavigation()
    private var statusItem: NSStatusItem?
    private var controlWindow: NSWindow?
    private var whatsNewWindow: NSWindow?
    private let whatsNew = WhatsNewController()
    private let updateRelaunch = UpdateRelaunchState()
    private var openedFile = false
    private var launchedAtLogin = false
    private lazy var settings = SettingsMenuController(model: model)
    private var updateTimer: Timer?
    private var updateCheckTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LoginItemController.wasLaunchedAtLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = launchedAtLogin || LoginItemController.wasLaunchedAtLogin()
        buildMainMenu()
        settings.onOpenSettings = { [weak self] in self?.showSettings() }
        settings.onOpenPower = { [weak self] in
            self?.navigation.section = .power
            self?.showWindow()
        }
        settings.onOpenUpdates = { [weak self] in self?.showUpdates() }
        settings.onOpenScreenSaver = { [weak self] in
            self?.navigation.section = .screenSaver
            self?.showWindow()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = AppIconArtwork.menuBarImage()
        item.button?.toolTip = model.localizer.text("MyWallpaper — живые обои")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        configureUpdateInstallation()
        startUpdateChecks()
        let restoredSession = updateRelaunch.consume(
            currentVersion: model.updates.currentVersion,
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        if !openedFile { model.restore(afterUpdate: restoredSession) }
        if restoredSession?.windowWasVisible ?? !launchedAtLogin { showWindow() }
        if whatsNew.recordLaunch(wasUpdated: restoredSession != nil) { showWhatsNew() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch model.updates.installation.state {
        case .checking, .downloading: model.updates.installation.cancel()
        default: break
        }
        let waitingForSave = hasPendingWork
        guard waitingForSave || model.updates.installation.state.requiresPreparationBeforeQuit else { return .terminateNow }
        // Finish pending library operations before quitting, including cleanup
        // of staging folders when a large video is still being copied.
        navigation.section = model.updates.installation.isBusy ? .updates
            : (model.screenSaver.isWorking || model.screenSaverSync.isWorking ? .screenSaver : .wallpaper)
        showWindow()
        if terminationTask == nil {
            terminationTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.waitForPendingWork(includingUpdatePreparation: true) }
                catch { return }
                self.terminationTask = nil
                let mayTerminate = !waitingForSave || (self.model.screenSaver.failure == nil
                    && self.model.wallpaperLibrary.failure == nil && self.model.screenSaverSync.failure == nil)
                // Sparkle may retain the staged installer after a refused quit.
                // Keep its receipt for Retry Restart; an actual installer abort clears it.
                sender.reply(toApplicationShouldTerminate: mayTerminate)
            }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedFile = true
        navigation.section = .wallpaper
        model.importWallpaper(url)
        showWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if statusItem != nil { checkForUpdatesAutomatically() }
        Task { await model.screenSaverSync.refreshInstallation() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateRelaunch.finalize(UpdatePlaybackSnapshot(
            wallpaperWasActive: model.hasWallpaper, userPaused: model.userPaused,
            temporarilyAnimating: model.isTemporarilyAnimating, powerSource: model.powerSource.rawValue,
            windowWasVisible: controlWindow?.isVisible == true))
        updateTimer?.invalidate()
        updateCheckTask?.cancel()
        terminationTask?.cancel()
        subscriptions.removeAll()
        model.shutDown()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "MyWallpaper", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        if let release = model.updates.offeredRelease {
            let update = addItem(model.localizer.format("Доступна версия %@…", release.version), action: #selector(showUpdates), to: menu)
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(.separator())
        }
        addItem(model.localizer.text("Открыть MyWallpaper…"), action: #selector(showWindow), to: menu)
        addItem(model.localizer.text("Выбрать видео…"), action: #selector(chooseVideo), key: "o", to: menu)
        let playback = addItem(model.hasWallpaper ? model.playbackButtonTitle : model.localizer.text("Включить обои"),
                              action: #selector(togglePlayback), to: menu)
        playback.isEnabled = !model.isLoading && model.selectedURL != nil
        let stop = addItem(model.localizer.text("Выключить обои"), action: #selector(stopWallpaper), to: menu)
        stop.isEnabled = model.hasWallpaper || model.isLoading
        let mute = addItem(model.localizer.text("Без звука"), action: #selector(toggleMute), to: menu)
        mute.state = model.isMuted ? .on : .off
        mute.isEnabled = model.selectedURL != nil && !model.isLoading && !model.isWorkingWithWallpapers
            && !model.wallpaperLibrary.isWorking
        let configure = addItem(model.localizer.text("Настроить текущие обои…"), action: #selector(configureWallpaper), to: menu)
        configure.isEnabled = model.selectedURL != nil && !model.isLoading && !model.isWorkingWithWallpapers
            && !model.wallpaperLibrary.isWorking
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: model.localizer.text("Настройки"), action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.submenu = settings.makeMenu()
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        addItem(model.localizer.text("Завершить MyWallpaper"), action: #selector(quit), key: "q", to: menu)
    }

    @objc private func showWindow() {
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "MyWallpaper"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 820, height: 640)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = NSHostingView(rootView: ControlView(model: model, navigation: navigation)
                .padding(.top, 24).background(Color(nsColor: .windowBackgroundColor)))
            window.center()
            window.setFrameAutosaveName("MyWallpaperControls")
            controlWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseVideo() {
        if navigation.section == .screenSaver {
            model.screenSaver.chooseVideo(localizer: model.localizer)
        } else {
            navigation.section = .wallpaper
            model.chooseVideo()
        }
    }
    @objc private func togglePlayback() { model.togglePlayback() }
    @objc private func stopWallpaper() { model.stop() }
    @objc private func toggleMute() { Task { await model.toggleCurrentWallpaperMute() } }
    @objc private func configureWallpaper() {
        guard model.selectedURL != nil, !model.isLoading, !model.isWorkingWithWallpapers,
              !model.wallpaperLibrary.isWorking else { return }
        if navigation.wallpaperEditor == nil {
            let entry = model.wallpaperLibrary.entries.first { $0.id == model.activeWallpaperID }
            navigation.configureWallpaper(entry)
        }
        showWindow()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        navigation.section = .general
        showWindow()
    }

    @objc private func showUpdates() {
        navigation.section = .updates
        showWindow()
    }

    @objc private func showWhatsNew() {
        guard let release = whatsNew.release else { return }
        if whatsNewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 530),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = model.localizer.text("Что нового")
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: WhatsNewWindowContent(model: model, release: release) { [weak self] in
                self?.whatsNewWindow?.performClose(nil)
            })
            window.center()
            whatsNewWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        whatsNewWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === whatsNewWindow else { return }
        whatsNew.dismiss()
    }

    private var hasPendingWork: Bool {
        model.isLoading || model.isSyncingSystemWallpaper || model.screenSaver.isWorking
            || model.isWorkingWithWallpapers || model.wallpaperLibrary.isWorking || model.screenSaverSync.isWorking
    }

    private func waitForPendingWork(includingUpdatePreparation: Bool = false) async throws {
        while hasPendingWork || (includingUpdatePreparation && model.updates.installation.state.requiresPreparationBeforeQuit) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    private func configureUpdateInstallation() {
        model.updates.onShowWhatsNew = { [weak self] in self?.showWhatsNew() }
        model.updates.installation.openUpdates = { [weak self] in self?.showUpdates() }
        model.updates.installation.prepareForRelaunch = { [weak self] target in
            guard let self else { throw CancellationError() }
            let savingSaver = self.model.screenSaver.isWorking
            let savingWallpaper = self.model.isWorkingWithWallpapers || self.model.wallpaperLibrary.isWorking
            let savingSync = self.model.screenSaverSync.isWorking
            try await self.waitForPendingWork()
            guard !(savingSaver && self.model.screenSaver.failure != nil),
                  !(savingWallpaper && self.model.wallpaperLibrary.failure != nil),
                  !(savingSync && self.model.screenSaverSync.failure != nil) else {
                throw UpdateInstallFailure(message: "Не удалось сохранить коллекцию. Проверь сообщение об ошибке и повтори обновление.")
            }
            self.updateRelaunch.prepare(
                sourceVersion: self.model.updates.currentVersion,
                sourceBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                targetVersion: target.version, targetBuild: target.build)
        }
        model.updates.installation.installationDidAbort = { [weak self] in self?.updateRelaunch.cancel() }
    }

    @objc private func checkForUpdates() {
        showUpdates()
        Task { await model.updates.checkNow() }
    }

    private func startUpdateChecks() {
        model.$language.dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.buildMainMenu()
                    self?.refreshUpdateIndicator()
                    self?.whatsNewWindow?.title = self?.model.localizer.text("Что нового") ?? "MyWallpaper"
                }
            }
            .store(in: &subscriptions)
        model.updates.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshUpdateIndicator() }
            }
            .store(in: &subscriptions)
        model.updates.$automaticChecksEnabled
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in self?.checkForUpdatesAutomatically() }
            }
            .store(in: &subscriptions)
        // A lightweight hourly wake-up; the controller persists the 24-hour limit.
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdatesAutomatically() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        refreshUpdateIndicator()
        checkForUpdatesAutomatically()
    }

    private func checkForUpdatesAutomatically() {
        guard updateCheckTask == nil else { return }
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { self.updateCheckTask = nil }
            await self.model.updates.checkAutomaticallyIfNeeded()
        }
    }

    private func refreshUpdateIndicator() {
        let release = model.updates.offeredRelease
        statusItem?.button?.image = AppIconArtwork.menuBarImage(hasUpdate: release != nil)
        statusItem?.button?.toolTip = release.map { model.localizer.format("MyWallpaper — доступна версия %@", $0.version) }
            ?? model.localizer.text("MyWallpaper — живые обои")
        statusItem?.button?.setAccessibilityLabel(statusItem?.button?.toolTip)
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        addItem(model.localizer.text("О MyWallpaper"), action: #selector(showWindow), to: appMenu)
        addItem(model.localizer.text("Настройки…"), action: #selector(showSettings), key: ",", to: appMenu)
        addItem(model.localizer.text("Проверить обновления…"), action: #selector(checkForUpdates), to: appMenu)
        addItem(model.localizer.text("Что нового"), action: #selector(showWhatsNew), to: appMenu)
        appMenu.addItem(.separator())
        addItem(model.localizer.text("Завершить MyWallpaper"), action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: model.localizer.text("Файл"))
        addItem(model.localizer.text("Выбрать видео…"), action: #selector(chooseVideo), key: "o", to: fileMenu)
        addItem(model.localizer.text("Настроить текущие обои…"), action: #selector(configureWallpaper), to: fileMenu)
        fileMenu.addItem(withTitle: model.localizer.text("Закрыть окно"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        NSApp.mainMenu = menu
    }
}

@MainActor
private struct WhatsNewWindowContent: View {
    @ObservedObject var model: WallpaperModel
    let release: WhatsNewRelease
    let onClose: () -> Void

    var body: some View {
        WhatsNewView(release: release, localizer: model.localizer, onClose: onClose)
            .environment(\.locale, model.localizer.locale)
    }
}
