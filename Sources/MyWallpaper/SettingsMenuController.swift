import AppKit

/// Fast access to the same settings shown in the app's sidebar sections.
@MainActor
final class SettingsMenuController: NSObject, NSMenuDelegate {
    private let model: WallpaperModel
    var onError: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenUpdates: (() -> Void)?

    init(model: WallpaperModel) { self.model = model }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Настройки")
        menu.autoenablesItems = false
        menu.delegate = self
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.loginItems.refresh()
        menu.removeAllItems()
        add("Открыть настройки…", action: #selector(openSettings), to: menu)
        let updateTitle = model.updates.availableRelease.map { "Доступна версия \($0.version)…" }
            ?? (model.updates.isChecking ? "Проверяем обновления…" : "Проверить обновления…")
        let update = add(updateTitle, action: #selector(checkUpdates), to: menu)
        update.isEnabled = !model.updates.isChecking
        menu.addItem(.separator())
        let launch = add("Запускать при входе в macOS", action: #selector(toggleLogin), to: menu)
        switch model.loginItems.status {
        case .enabled: launch.state = .on
        case .disabled, .notFound: launch.state = .off
        case .requiresApproval:
            launch.state = .mixed
            let pending = NSMenuItem(title: "Автозапуск ожидает разрешения macOS", action: nil, keyEquivalent: "")
            pending.isEnabled = false
            menu.addItem(pending)
            add("Разрешить в настройках macOS…", action: #selector(openLoginSettings), to: menu)
        case .unavailable:
            launch.isEnabled = false
        }
        launch.toolTip = model.loginItems.statusDetail
        // Pending approval can still be cancelled from this menu.
        if model.loginItems.status != .requiresApproval { launch.isEnabled = model.loginItems.canToggle }
        if model.loginItems.status == .notFound || model.loginItems.status == .unavailable
            || model.loginItems.errorMessage != nil {
            add("Настройки входа macOS…", action: #selector(openLoginSettings), to: menu)
        }
        check("Восстанавливать обои при запуске", value: model.restoreOnLaunch,
              action: #selector(toggleRestore), to: menu)
        menu.addItem(.separator())
        check("Живые обои от сети", value: model.animateOnExternalPower,
              action: #selector(toggleExternalPower), to: menu)
        check("Живые обои от батареи", value: model.animateOnBattery,
              action: #selector(toggleBattery), to: menu)
        check("Пауза, когда рабочий стол скрыт", value: model.pauseWhenCovered,
              action: #selector(toggleCovered), to: menu)
            .toolTip = "На каждом экране отдельно. Проверка примерно раз в секунду; небольшие зазоры у краёв не учитываются."
        check("Пауза в режиме энергосбережения", value: model.pauseInLowPowerMode,
              action: #selector(toggleLowPower), to: menu)
        check("Без звука", value: model.isMuted, action: #selector(toggleMute), to: menu)
        menu.addItem(.separator())

        let display = NSMenuItem(title: "Экран", action: nil, keyEquivalent: "")
        let screens = NSMenu(title: "Экран")
        screens.autoenablesItems = false
        for target in DisplayTarget.allCases {
            let item = check(target.title, value: model.target == target, action: #selector(selectDisplay(_:)), to: screens)
            item.representedObject = target.rawValue
        }
        display.submenu = screens
        menu.addItem(display)

        let scaling = NSMenuItem(title: "Масштаб", action: nil, keyEquivalent: "")
        let sizes = NSMenu(title: "Масштаб")
        sizes.autoenablesItems = false
        for mode in VideoScaling.allCases {
            let item = check(mode.title, value: model.scaling == mode, action: #selector(selectScaling(_:)), to: sizes)
            item.representedObject = mode.rawValue
            item.toolTip = mode == .fill ? "Заполнить экран, обрезав края кадра" : "Показать весь кадр с полями"
        }
        scaling.submenu = sizes
        menu.addItem(scaling)
    }

    @objc private func toggleLogin() {
        model.loginItems.refresh()
        let status = model.loginItems.status
        model.setLaunchAtLogin(status != .enabled && status != .requiresApproval)
        if model.loginItems.errorMessage != nil { onError?() }
    }

    @objc private func openLoginSettings() { model.loginItems.openSystemSettings() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func checkUpdates() {
        onOpenUpdates?()
        if model.updates.availableRelease == nil {
            Task { await model.updates.checkNow() }
        }
    }
    @objc private func toggleExternalPower() { model.animateOnExternalPower.toggle() }
    @objc private func toggleBattery() { model.animateOnBattery.toggle() }
    @objc private func toggleRestore() { model.restoreOnLaunch.toggle() }
    @objc private func toggleCovered() { model.pauseWhenCovered.toggle() }
    @objc private func toggleLowPower() { model.pauseInLowPowerMode.toggle() }
    @objc private func toggleMute() { model.isMuted.toggle() }

    @objc private func selectDisplay(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let target = DisplayTarget(rawValue: value) else { return }
        model.target = target
    }

    @objc private func selectScaling(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let scaling = VideoScaling(rawValue: value) else { return }
        model.scaling = scaling
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func check(_ title: String, value: Bool, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = add(title, action: action, to: menu)
        item.state = value ? .on : .off
        return item
    }
}
