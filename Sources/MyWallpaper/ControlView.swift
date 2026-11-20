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
                        if navigation.section != .updates, let release = updates.availableRelease {
                            UpdateAvailableBanner(version: release.version, localizer: model.localizer) { navigation.section = .updates }
                        }
                        switch navigation.section {
                        case .wallpaper: WallpaperSettingsPane(model: model)
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
                model.selectVideo(url)
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

            Text(model.localizer.text("Настройки"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

            List(selection: Binding<AppSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                ForEach(AppSection.allCases) { section in
                    HStack(spacing: 11) {
                        SettingsIcon(symbol: section.symbol, color: section.color, size: 28)
                        Text(model.localizer.text(section.title)).font(.system(size: 13, weight: .medium))
                        if section == .updates, updates.availableRelease != nil {
                            Circle().fill(Color.teal).frame(width: 6, height: 6)
                                .accessibilityLabel(model.localizer.text("Доступна новая версия"))
                        }
                    }
                    .padding(.vertical, 5)
                    .tag(section)
                    .accessibilityLabel(model.localizer.text(section.title))
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
            if navigation.section == .wallpaper {
                Button(action: model.chooseVideo) {
                    Label(model.localizer.text("Выбрать видео"), systemImage: "plus")
                }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                preview
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(model.thumbnail == nil ? 0.04 : 0.17), radius: 16, y: 7)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(AppColors.previewSurround)

                if model.selectedURL != nil {
                    Divider()
                    HStack(spacing: 12) {
                        RowIcon(symbol: "film", color: .teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.selectedURL?.lastPathComponent ?? model.localizer.text("Видео"))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text(model.selectedURL?.pathExtension.uppercased() ?? model.localizer.text("Видео"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(AppColors.statusBackground, in: RoundedRectangle(cornerRadius: 4))
                                Text(model.localizer.text("Текущие обои")).font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button(action: model.revealVideo) {
                            Image(systemName: "folder").frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(model.localizer.text("Показать видео в Finder"))
                        .accessibilityLabel(model.localizer.text("Показать видео в Finder"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .help(model.selectedURL?.path ?? "")
                }

                if model.selectedURL != nil || model.isLoading {
                    Divider().padding(.horizontal, 16)
                    HStack(spacing: 10) {
                        Button(action: model.togglePlayback) {
                            Label(model.playbackButtonTitle, systemImage: model.playbackButtonSymbol)
                                .frame(minWidth: 94)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isLoading)
                        Button(action: model.stop) {
                            Label(model.localizer.text("Выключить"), systemImage: "stop.fill")
                        }
                        .controlSize(.large)
                        .disabled(!model.hasWallpaper && !model.isLoading)
                        .help(model.syncSystemWallpaper
                              ? model.localizer.text("Остановить видео; системный кадр останется.")
                              : model.localizer.text("Вернуть обычные обои macOS"))
                        Spacer(minLength: 4)
                        Image(systemName: model.isMuted ? "speaker.slash" : "speaker.wave.2")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .help(model.isMuted ? model.localizer.text("Звук выключен") : model.localizer.text("Звук включён"))
                            .accessibilityLabel(model.isMuted ? model.localizer.text("Без звука") : model.localizer.text("Со звуком"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else {
                    HStack {
                        Label(model.localizer.text("MP4, MOV и другие форматы"), systemImage: "film")
                        Spacer()
                        Label(model.localizer.text("Видео с этого Mac"), systemImage: "folder")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(16)
                }
            }

            SettingsGroup(title: model.localizer.text("Оформление")) {
                SettingsRow(title: model.localizer.text("Экран"), symbol: "display.2", color: .blue) {
                    Picker(model.localizer.text("Экран"), selection: $model.target) {
                        ForEach(DisplayTarget.allCases) { Text(model.localizer.text($0.title)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                SettingsDivider()
                SettingsRow(title: model.localizer.text("Масштаб"), detail: model.localizer.text("Как видео располагается на экране."),
                            symbol: "arrow.up.left.and.arrow.down.right", color: .purple) {
                    Picker(model.localizer.text("Масштаб"), selection: $model.scaling) {
                        ForEach(VideoScaling.allCases) { Text(model.localizer.text($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 176)
                }
                SettingsDivider()
                SettingsToggle(title: model.localizer.text("Системный фон из видео"),
                               detail: model.localizer.text("Сохранять кадр видео как обои macOS. Он останется после выхода из приложения."),
                               symbol: "photo.on.rectangle", color: .teal,
                               isOn: $model.syncSystemWallpaper)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.localizer.text("Применяется к текущему рабочему столу на выбранных экранах. macOS может отключить показ на всех пространствах Spaces."))
                    if model.isSyncingSystemWallpaper {
                        ProgressView(model.localizer.text("Обновляем системный фон…"))
                            .controlSize(.small)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 60).padding(.trailing, 16).padding(.bottom, 16)
            }
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = model.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: model.scaling == .fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(.black)
                } else {
                    LinearGradient(colors: [Color.teal.opacity(0.10), Color.blue.opacity(0.035)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 9) {
                        AppBrandIcon(size: 68).padding(.bottom, 4)
                        Text(model.selectedURL == nil ? model.localizer.text("Рабочий стол с характером") : model.localizer.text("Предпросмотр видео"))
                            .font(.system(size: 17, weight: .semibold))
                        if model.selectedURL == nil {
                            Text(model.localizer.text("Перетащи любимое видео в это окно"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button(action: model.chooseVideo) {
                                Label(model.localizer.text("Выбрать видео"), systemImage: "plus")
                            }
                            .controlSize(.large)
                            .padding(.top, 7)
                        }
                    }
                    .padding(20)
                }
                if model.isLoading {
                    Color(nsColor: .windowBackgroundColor).opacity(0.75)
                    ProgressView(model.localizer.text("Открываем видео…"))
                        .font(.system(size: 12))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.localizer.text("Предпросмотр обоев"))
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
            SettingsGroup(title: model.localizer.text("Звук")) {
                SettingsToggle(title: model.localizer.text("Без звука"), detail: model.localizer.text("Отключить аудиодорожку видео."),
                               symbol: "speaker.slash.fill", color: .purple, isOn: $model.isMuted)
                SettingsDivider()
                SettingsRow(title: model.localizer.text("Громкость"),
                            detail: model.localizer.text(model.isMuted
                                ? "Звук выключен. Уровень сохранится после включения."
                                : "Уровень звука видеообоев."),
                            symbol: "speaker.wave.2.fill", color: .purple) {
                    HStack(spacing: 10) {
                        Slider(value: $model.volume, in: 0...1)
                            .accessibilityLabel(model.localizer.text("Громкость"))
                            .accessibilityValue(model.volume.formatted(.percent.precision(.fractionLength(0)).locale(model.localizer.locale)))
                        Text(model.volume.formatted(.percent.precision(.fractionLength(0)).locale(model.localizer.locale)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .frame(width: 190)
                }
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
