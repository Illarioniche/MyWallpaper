import AppKit

/// Shortcuts to the app's settings sections; wallpaper parameters have one editor.
@MainActor
final class SettingsMenuController: NSObject, NSMenuDelegate {
    private let model: WallpaperModel
    var onOpenSettings: (() -> Void)?
    var onOpenPower: (() -> Void)?
    var onOpenUpdates: (() -> Void)?
    var onOpenScreenSaver: (() -> Void)?

    init(model: WallpaperModel) { self.model = model }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: model.localizer.text("Настройки"))
        menu.autoenablesItems = false
        menu.delegate = self
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(model.localizer.text("Открыть настройки…"), action: #selector(openSettings), to: menu)
        add(model.localizer.text("Общие правила питания…"), action: #selector(openPower), to: menu)
        add(model.localizer.text("Заставка (Beta)…"), action: #selector(openScreenSaver), to: menu)
        menu.addItem(.separator())
        let updateTitle = model.updates.offeredRelease.map { model.localizer.format("Доступна версия %@…", $0.version) }
            ?? (model.updates.isChecking ? model.localizer.text("Проверяем обновления…") : model.localizer.text("Проверить обновления…"))
        let update = add(updateTitle, action: #selector(checkUpdates), to: menu)
        update.isEnabled = !model.updates.isChecking && !model.updates.installation.isBusy
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openPower() { onOpenPower?() }
    @objc private func openScreenSaver() { onOpenScreenSaver?() }
    @objc private func checkUpdates() {
        onOpenUpdates?()
        if model.updates.offeredRelease == nil {
            Task { await model.updates.checkNow() }
        }
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }
}
