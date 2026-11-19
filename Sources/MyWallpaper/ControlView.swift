import SwiftUI

@MainActor
struct ControlView: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var navigation: AppNavigation
    @State private var dropTargeted = false

    init(model: WallpaperModel, navigation: AppNavigation = AppNavigation()) {
        self.model = model
        self.navigation = navigation
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                pageHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = model.errorMessage { errorBanner(error) }
                        switch navigation.section {
                        case .wallpaper: WallpaperSettingsPane(model: model)
                        case .general: GeneralSettingsPane(model: model)
                        case .power: PowerSettingsPane(model: model)
                        }
                    }
                    .frame(maxWidth: 740, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, idealWidth: 920, maxWidth: .infinity,
               minHeight: 550, idealHeight: 650, maxHeight: .infinity)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            navigation.section = .wallpaper
            model.selectVideo(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SettingsIcon(symbol: "play.rectangle.fill", color: .teal, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MyWallpaper").font(.system(size: 14, weight: .semibold))
                    Text("Живые обои").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 20)

            List(selection: Binding<AppSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                ForEach(AppSection.allCases) { section in
                    HStack(spacing: 10) {
                        SettingsIcon(symbol: section.symbol, color: section.color)
                        Text(section.title).font(.system(size: 13))
                    }
                    .padding(.vertical, 3)
                    .tag(section)
                    .accessibilityLabel(section.title)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 5)

            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(model.isPlaying ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    Text(model.status)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Приложение остаётся в строке меню, когда окно закрыто.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .background(.regularMaterial)
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(navigation.section.title)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(navigation.section.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if navigation.section == .wallpaper {
                Button("Выбрать видео…", action: model.chooseVideo)
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Закрыть сообщение")
        }
        .padding(13)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct WallpaperSettingsPane: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                preview.frame(height: 270)
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.selectedURL?.lastPathComponent ?? "Видео не выбрано")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.selectedURL == nil ? "MP4, MOV и другие форматы macOS" : "Текущие обои")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if model.selectedURL != nil {
                        Button(action: model.revealVideo) { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help("Показать видео в Finder")
                            .accessibilityLabel("Показать видео в Finder")
                    }
                }
                .padding(14)
                .help(model.selectedURL?.path ?? "Выбери локальный видеофайл")
            }

            HStack(spacing: 10) {
                Button(action: model.togglePlayback) {
                    Label(model.playbackButtonTitle, systemImage: model.playbackButtonSymbol)
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isLoading || model.selectedURL == nil)
                Button("Выключить", action: model.stop)
                    .controlSize(.large)
                    .disabled(!model.hasWallpaper && !model.isLoading)
                    .help("Вернуть обычные обои macOS")
                Spacer(minLength: 8)
                Label(model.isMuted ? "Без звука" : "Со звуком",
                      systemImage: model.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            SettingsCard {
                SettingsRow(title: "Экран") {
                    Picker("Экран", selection: $model.target) {
                        ForEach(DisplayTarget.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsDivider()
                SettingsRow(title: "Масштаб", detail: "Заполнить экран или показать весь кадр.") {
                    Picker("Масштаб", selection: $model.scaling) {
                        ForEach(VideoScaling.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
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
                    LinearGradient(colors: [Color.accentColor.opacity(0.07), Color.accentColor.opacity(0.015)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(Color.accentColor)
                            .padding(.bottom, 3)
                        Text(model.selectedURL == nil ? "Видео для рабочего стола" : "Предпросмотр видео")
                            .font(.system(size: 16, weight: .medium))
                        if model.selectedURL == nil {
                            Text("Перетащи MP4 или MOV в это окно")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button("Выбрать файл…", action: model.chooseVideo)
                                .padding(.top, 5)
                        }
                    }
                }
                if model.isLoading {
                    Color(nsColor: .windowBackgroundColor).opacity(0.65)
                    ProgressView("Открываем видео…")
                        .font(.system(size: 12))
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Предпросмотр обоев")
    }
}

@MainActor
private struct GeneralSettingsPane: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Запуск") {
                LoginSettingsRow(model: model, loginItems: model.loginItems)
                SettingsDivider()
                SettingsToggle(title: "Восстанавливать обои при запуске",
                               detail: "Открывать последнее видео и сохранять выбранный режим воспроизведения.",
                               isOn: $model.restoreOnLaunch)
            }
            SettingsGroup(title: "Воспроизведение") {
                SettingsToggle(title: "Без звука", detail: "Отключить аудиодорожку видео.", isOn: $model.isMuted)
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "menubar.rectangle").font(.system(size: 15))
                Text("После закрытия окна MyWallpaper остаётся в строке меню. Оттуда можно открыть настройки, поставить обои на паузу или завершить приложение.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
    }
}

@MainActor
private struct LoginSettingsRow: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var loginItems: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggle(title: "Запускать при входе в macOS",
                           detail: loginItems.status == .unavailable
                               ? "Доступно из собранного приложения MyWallpaper.app."
                               : "Открывать приложение в строке меню без лишних окон.",
                           isOn: Binding(get: { loginItems.status == .enabled },
                                         set: { value in model.setLaunchAtLogin(value) }))
                .disabled(loginItems.status == .unavailable || loginItems.status == .requiresApproval)
            if loginItems.status == .requiresApproval {
                HStack(spacing: 8) {
                    Label("Нужно разрешение macOS", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("Отменить") { model.setLaunchAtLogin(false) }
                    Button("Разрешить…", action: loginItems.openSystemSettings)
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
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
                HStack(spacing: 12) {
                    SettingsIcon(symbol: sourceSymbol, color: sourceColor, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sourceTitle).font(.system(size: 13, weight: .semibold))
                        Text("Режим меняется автоматически при смене источника питания.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(15)
            }

            SettingsGroup(title: "По источнику питания") {
                SettingsToggle(title: "Живые обои от сети",
                               detail: "Воспроизводить видео при подключённом питании.",
                               isOn: $model.animateOnExternalPower)
                SettingsDivider()
                SettingsToggle(title: "Живые обои от батареи",
                               detail: "Воспроизводить видео, когда Mac работает от аккумулятора.",
                               isOn: $model.animateOnBattery)
            }
            Text("Если режим выключен, на рабочем столе остаётся неподвижный кадр. Настройки для сети и батареи можно менять независимо.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, -12)

            SettingsGroup(title: "Экономия энергии") {
                SettingsToggle(title: "Пауза, когда рабочий стол скрыт",
                               detail: "Продолжать воспроизведение, когда обои снова видны.",
                               isOn: $model.pauseWhenCovered)
                    .help("Проверяется каждый экран отдельно, примерно раз в секунду. Небольшие зазоры у краёв не учитываются.")
                SettingsDivider()
                SettingsToggle(title: "Пауза в режиме энергосбережения",
                               detail: "Учитывать режим энергосбережения macOS.",
                               isOn: $model.pauseInLowPowerMode)
            }
        }
    }

    private var sourceTitle: String {
        switch model.powerSource {
        case .external: return "Сейчас: питание от сети"
        case .battery: return "Сейчас: питание от батареи"
        case .unknown: return "Источник питания не определён"
        }
    }

    private var sourceSymbol: String {
        switch model.powerSource {
        case .external: return "powerplug.fill"
        case .battery: return "battery.100percent"
        case .unknown: return "questionmark"
        }
    }

    private var sourceColor: Color {
        switch model.powerSource {
        case .external: return .green
        case .battery: return .orange
        case .unknown: return .gray
        }
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.54, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .accessibilityAddTraits(.isHeader)
            SettingsCard { content }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 18) {
            SettingsLabel(title: title, detail: detail)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { SettingsLabel(title: title, detail: detail) }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(14)
    }
}

private struct SettingsLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.horizontal, 14) }
}
