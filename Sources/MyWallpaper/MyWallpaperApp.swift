import AppKit
import SwiftUI

@main
enum MyWallpaperApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = WallpaperModel()
    private let navigation = AppNavigation()
    private var statusItem: NSStatusItem?
    private var controlWindow: NSWindow?
    private var openedFile = false
    private var launchedAtLogin = false
    private lazy var settings = SettingsMenuController(model: model)

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LoginItemController.wasLaunchedAtLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = launchedAtLogin || LoginItemController.wasLaunchedAtLogin()
        buildMainMenu()
        settings.onError = { [weak self] in self?.showWindow() }
        settings.onOpenSettings = { [weak self] in self?.showSettings() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "MyWallpaper")
        item.button?.toolTip = "MyWallpaper — живые обои"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        if !openedFile { model.restore() }
        if !launchedAtLogin { showWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedFile = true
        navigation.section = .wallpaper
        model.selectVideo(url)
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutDown() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "MyWallpaper", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        addItem("Открыть MyWallpaper…", action: #selector(showWindow), to: menu)
        addItem("Выбрать видео…", action: #selector(chooseVideo), key: "o", to: menu)
        let playback = addItem(model.hasWallpaper ? model.playbackButtonTitle : "Включить обои",
                              action: #selector(togglePlayback), to: menu)
        playback.isEnabled = !model.isLoading && model.selectedURL != nil
        let stop = addItem("Выключить обои", action: #selector(stopWallpaper), to: menu)
        stop.isEnabled = model.hasWallpaper || model.isLoading
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Настройки", action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.submenu = settings.makeMenu()
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        addItem("Завершить MyWallpaper", action: #selector(quit), key: "q", to: menu)
    }

    @objc private func showWindow() {
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "MyWallpaper"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 820, height: 604)
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
        navigation.section = .wallpaper
        model.chooseVideo()
    }
    @objc private func togglePlayback() { model.togglePlayback() }
    @objc private func stopWallpaper() { model.stop() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        navigation.section = .general
        showWindow()
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
        addItem("О MyWallpaper", action: #selector(showWindow), to: appMenu)
        addItem("Настройки…", action: #selector(showSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        addItem("Завершить MyWallpaper", action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Файл")
        addItem("Выбрать видео…", action: #selector(chooseVideo), key: "o", to: fileMenu)
        fileMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        NSApp.mainMenu = menu
    }
}
