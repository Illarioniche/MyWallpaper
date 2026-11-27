import SwiftUI

@MainActor
struct ControlView: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var navigation: AppNavigation
    @ObservedObject private var updates: UpdateController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var dropTargeted = false

    init(model: WallpaperModel, navigation: AppNavigation = AppNavigation()) {
        self.model = model
        self.navigation = navigation
        self.updates = model.updates
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 212)
            Divider()
            VStack(spacing: 0) {
                pageHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let error = model.errorMessage { errorBanner(error) }
                        if navigation.section != .updates, let release = updates.offeredRelease {
                            UpdateAvailableBanner(version: release.version, localizer: model.localizer) { navigation.section = .updates }
                        }
                        switch navigation.section {
                        case .wallpaper: WallpaperSettingsPane(model: model, navigation: navigation)
                        case .screenSaver: ScreenSaverSettingsPane(model: model, screenSaver: model.screenSaver)
                        case .general: GeneralSettingsPane(model: model)
                        case .power: PowerSettingsPane(model: model)
                        case .updates: UpdateSettingsPane(updates: updates, localizer: model.localizer)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.canvas)
        }
        .frame(minWidth: 820, idealWidth: 980, maxWidth: .infinity,
               minHeight: 600, idealHeight: 736, maxHeight: .infinity)
        .environment(\.locale, model.localizer.locale)
        .sheet(item: $navigation.wallpaperEditor) { route in
            WallpaperOptionsSheet(model: model, library: model.wallpaperLibrary, entry: route.entry) {
                navigation.wallpaperEditor = nil
                navigation.section = .power
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            if navigation.section == .screenSaver {
                model.screenSaver.selectVideo(url)
            } else {
                navigation.section = .wallpaper
                model.importWallpaper(url)
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AppBrandIcon(size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MyWallpaper").font(.system(size: 14, weight: .semibold))
                    Text(model.localizer.text("Живые обои для Mac"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 22)
            .padding(.bottom, 28)

            List(selection: Binding<AppSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                Section(model.localizer.text("Коллекции")) {
                    ForEach([AppSection.wallpaper, .screenSaver]) { sidebarRow($0) }
                }
                Section(model.localizer.text("Настройки")) {
                    ForEach([AppSection.general, .power, .updates]) { sidebarRow($0) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 5)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.isPlaying ? Color.teal : Color.secondary)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(model.status)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.statusBackground, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityElement(children: .combine)

                Label(model.localizer.text("Всегда под рукой в строке меню"), systemImage: "menubar.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
            }
            .padding(16)
        }
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
        }
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        HStack(spacing: 11) {
            SettingsIcon(symbol: section.symbol, color: section.color, size: 28)
            Text(model.localizer.text(section.title)).font(.system(size: 13, weight: .medium))
            if section == .updates, updates.offeredRelease != nil {
                Circle().fill(Color.teal).frame(width: 6, height: 6)
                    .accessibilityLabel(model.localizer.text("Доступна новая версия"))
            }
        }
        .padding(.vertical, 5)
        .tag(section)
        .accessibilityLabel(model.localizer.text(section.title))
    }

    private var statusSymbol: String {
        if model.isLoading { return "hourglass" }
        if model.isPlaying { return "play.circle.fill" }
        return model.hasWallpaper ? "pause.circle.fill" : "circle.dotted"
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.localizer.text(navigation.section.title))
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(model.localizer.text(navigation.section.subtitle))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .padding(.top, 4)
            Text(message)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.errorMessage = nil } label: {
                Image(systemName: "xmark").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(model.localizer.text("Закрыть сообщение"))
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct WallpaperSettingsPane: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.selectedURL != nil || model.isLoading { currentWallpaper }
            WallpaperLibraryPane(model: model) { navigation.configureWallpaper($0) }
        }
    }

    private var isBusy: Bool {
        model.isLoading || model.isWorkingWithWallpapers || model.wallpaperLibrary.isWorking
    }

    private var currentWallpaper: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color.teal.opacity(0.1))
                    if let thumbnail = model.thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                            .frame(width: 128, height: 80).clipped()
                    } else {
                        Image(systemName: "photo").font(.system(size: 25)).foregroundStyle(.teal)
                    }
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
                .frame(width: 128, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text(model.localizer.text("Текущие обои"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(model.selectedWallpaperName ?? model.selectedURL?.deletingPathExtension().lastPathComponent
                         ?? model.localizer.text("Открываем видео…"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2).truncationMode(.middle)
                    Label(model.status, systemImage: model.isPlaying ? "play.circle.fill" : "pause.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.isTemporarilyAnimating {
                        Text(model.localizer.text("Анимация включена временно. Правила питания не изменены."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            Divider().padding(.horizontal, 16)
            HStack(spacing: 9) {
                Button(action: model.togglePlayback) {
                    Label(model.playbackButtonTitle, systemImage: model.playbackButtonSymbol)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading)
                Button(action: model.stop) {
                    Label(model.localizer.text("Выключить"), systemImage: "stop.fill")
                }
                .disabled(!model.hasWallpaper && !model.isLoading)
                .help(model.syncSystemWallpaper
                      ? model.localizer.text("Остановить видео; системный кадр останется.")
                      : model.localizer.text("Вернуть обычные обои macOS"))
                Spacer(minLength: 0)
                Button {
                    Task { await model.toggleCurrentWallpaperMute() }
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash" : "speaker.wave.2")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless).disabled(isBusy)
                .help(model.localizer.text(model.isMuted ? "Включить звук" : "Выключить звук"))
                .accessibilityLabel(model.localizer.text(model.isMuted ? "Включить звук" : "Выключить звук"))
                Button(model.localizer.text("Настроить…")) {
                    let entry = model.wallpaperLibrary.entries.first { $0.id == model.activeWallpaperID }
                    navigation.configureWallpaper(entry)
                }
                .disabled(isBusy || model.selectedURL == nil)
            }
            .controlSize(.regular)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

@MainActor
private struct GeneralSettingsPane: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsIntro(symbol: "slider.horizontal.3", color: .blue,
                          title: model.localizer.text("Устроено под тебя"),
                          detail: model.localizer.text("Пара настроек — и любимые обои всегда на месте."))
            SettingsGroup(title: model.localizer.text("Запуск приложения")) {
                LoginSettingsRow(model: model, loginItems: model.loginItems)
                SettingsDivider()
                SettingsToggle(title: model.localizer.text("Восстанавливать обои при запуске"),
                               detail: model.localizer.text("Открывать последнее видео в выбранном режиме."),
                               symbol: "arrow.counterclockwise", color: .blue,
                               isOn: $model.restoreOnLaunch)
            }
            SettingsGroup(title: model.localizer.text("Язык")) {
                SettingsRow(title: model.localizer.text("Язык приложения"),
                            detail: model.localizer.text("Язык меняется сразу, без перезапуска приложения."),
                            symbol: "globe", color: .blue) {
                    Picker(model.localizer.text("Язык приложения"), selection: $model.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title(using: model.localizer)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(.teal)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.localizer.text("Закрой окно — обои останутся"))
                        .font(.system(size: 12, weight: .medium))
                    Text(model.localizer.text("Управление всегда доступно в строке меню: пауза, выбор видео и настройки."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
private struct LoginSettingsRow: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var loginItems: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggle(title: model.localizer.text("Запускать при входе в macOS"),
                           detail: loginItems.statusDetail,
                           symbol: "power", color: .teal,
                           isOn: Binding(get: { loginItems.status == .enabled },
                                         set: { value in model.setLaunchAtLogin(value) }))
                .disabled(!loginItems.canToggle)
            if loginItems.status == .requiresApproval {
                HStack(spacing: 8) {
                    Label(model.localizer.text("Нужно разрешение macOS"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button(model.localizer.text("Отменить")) { model.setLaunchAtLogin(false) }
                    Button(model.localizer.text("Разрешить…"), action: loginItems.openSystemSettings)
                }
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else if loginItems.status == .notFound || loginItems.status == .unavailable
                        || loginItems.errorMessage != nil {
                HStack {
                    Spacer(minLength: 0)
                    Button(model.localizer.text("Проверить снова")) { loginItems.refresh() }
                    Button(model.localizer.text("Настройки входа macOS…")) { loginItems.openSystemSettings() }
                }
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .onAppear { loginItems.refresh() }
    }
}

@MainActor
private struct PowerSettingsPane: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                HStack(spacing: 15) {
                    SettingsIcon(symbol: sourceSymbol, color: sourceColor, size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sourceTitle).font(.system(size: 15, weight: .semibold))
                        Text(model.localizer.text("MyWallpaper учитывает источник питания автоматически."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sourceColor.opacity(0.045))
            }
            Text(model.localizer.text("Эти правила действуют для всех обоев. Для отдельного видео можно задать исключение в его настройках."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.selectedURL != nil && !model.currentWallpaperOptions.usesGlobalPowerRules {
                Label(model.localizer.text("Текущие обои используют свои правила питания. Изменения ниже не заменят это исключение."),
                      systemImage: "slider.horizontal.3")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }
            SettingsGroup(title: model.localizer.text("Режим воспроизведения")) {
                SettingsToggle(title: model.localizer.text("Живые обои от сети"),
                               detail: model.localizer.text("Анимация при подключённом питании."),
                               symbol: "powerplug.fill", color: .teal,
                               isOn: $model.animateOnExternalPower)
                SettingsDivider()
                SettingsToggle(title: model.localizer.text("Живые обои от батареи"),
                               detail: model.localizer.text("Анимация при работе от аккумулятора."),
                               symbol: "battery.100", color: .orange,
                               isOn: $model.animateOnBattery)
            }
            Text(model.localizer.text("При выключенном режиме на рабочем столе остаётся неподвижный кадр."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, -10)

            SettingsGroup(title: model.localizer.text("Экономия энергии")) {
                SettingsToggle(title: model.localizer.text("Пауза, когда рабочий стол скрыт"),
                               detail: model.localizer.text("Продолжать, когда обои снова видны."),
                               symbol: "rectangle.on.rectangle.slash", color: .blue,
                               isOn: $model.pauseWhenCovered)
                    .help(model.localizer.text("Проверяется каждый экран отдельно, примерно раз в секунду. Небольшие зазоры у краёв не учитываются."))
                SettingsDivider()
                SettingsToggle(title: model.localizer.text("Пауза в режиме энергосбережения"),
                               detail: model.localizer.text("Учитывать режим энергосбережения macOS."),
                               symbol: "leaf.fill", color: .green,
                               isOn: $model.pauseInLowPowerMode)
            }
        }
    }

    private var sourceTitle: String {
        switch model.powerSource {
        case .external: return model.localizer.text("Сейчас — питание от сети")
        case .battery: return model.localizer.text("Сейчас — питание от батареи")
        case .unknown: return model.localizer.text("Источник питания не определён")
        }
    }
    private var sourceSymbol: String {
        switch model.powerSource {
        case .external: return "powerplug.fill"
        case .battery: return "battery.100"
        case .unknown: return "questionmark"
        }
    }
    private var sourceColor: Color {
        switch model.powerSource {
        case .external: return .teal
        case .battery: return .orange
        case .unknown: return .gray
        }
    }
}

@MainActor
private struct AppBrandIcon: View {
    private static let artwork = AppIconArtwork.image(size: 128)
    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.artwork)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private enum AppColors {
    static var canvas: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
                : NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        })
    }
    static var previewSurround: Color { Color.primary.opacity(0.025) }
    static var statusBackground: Color { Color.primary.opacity(0.045) }
}

struct SettingsIntro: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 15) {
            SettingsIcon(symbol: symbol, color: color, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.50, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.25))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.25)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

private struct RowIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .shadow(color: .black.opacity(contrast == .increased ? 0 : 0.025), radius: 4, y: 2)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            SettingsCard { content }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    let symbol: String
    let color: Color
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol, color: color)
            SettingsLabel(title: title, detail: detail)
            Spacer(minLength: 4)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    let symbol: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                RowIcon(symbol: symbol, color: color)
                SettingsLabel(title: title, detail: detail)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
    }
}

private struct SettingsLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 60).padding(.trailing, 16) }
}
