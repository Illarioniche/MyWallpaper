import SwiftUI

@MainActor
struct WallpaperLibraryPane: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject private var library: WallpaperLibraryController
    @State private var sheet: Editor?
    @State private var pendingDeletion: WallpaperLibraryEntry?
    @State private var showsDeletion = false
    private var localizer: AppLocalizer { model.localizer }

    init(model: WallpaperModel) {
        self.model = model
        self.library = model.wallpaperLibrary
    }

    private enum Editor: Identifiable {
        case rename(WallpaperLibraryEntry)
        case settings(WallpaperLibraryEntry)

        var id: String {
            switch self {
            case .rename(let entry): return "rename-\(entry.id)"
            case .settings(let entry): return "settings-\(entry.id)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localizer.text("Мои обои"))
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(localizer.text("Твоя коллекция видео и настроек рабочего стола."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: model.addWallpaperVideo) {
                    Label(localizer.text("Добавить видео"), systemImage: "plus")
                }
                .controlSize(.large)
                .disabled(library.isWorking || model.isWorkingWithWallpapers || model.isLoading)
            }

            if let failure = library.failure {
                HStack(alignment: .top, spacing: 10) {
                    WallpaperLibraryFailureView(failure: failure, localizer: localizer)
                    Button(action: library.dismissFailure) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localizer.text("Закрыть сообщение"))
                }
                .padding(14)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            if !library.libraryWarnings.isEmpty {
                Label(localizer.text("Некоторые обои не удалось загрузить. Остальные доступны в коллекции."),
                      systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            if library.isWorking {
                ProgressView(localizer.text("Обновляем коллекцию…"))
                    .controlSize(.small).font(.system(size: 12))
            }

            if let id = model.activeWallpaperID,
               let entry = library.entries.first(where: { $0.id == id }),
               model.currentWallpaperOptions != entry.options {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.name).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Text(localizer.text("Текущие настройки отличаются от сохранённых."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(localizer.text("Сохранить текущие настройки")) {
                        Task { await model.updateWallpaper(entry, options: model.currentWallpaperOptions) }
                    }
                    .controlSize(.small)
                    .disabled(library.isWorking || model.isWorkingWithWallpapers || model.isLoading)
                    .help(localizer.text("Сохранить экран, масштаб, звук и питание для этих обоев."))
                }
                .padding(14)
                .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            if library.entries.isEmpty && (!library.isWorking || library.hasLoadedLibrary) {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.teal)
                    Text(localizer.text("Здесь будут твои обои"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(localizer.text("Добавь видео один раз, затем переключай обои вместе с их настройками."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 370)
                    Button(localizer.text("Добавить первые обои"), action: model.addWallpaperVideo)
                        .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
                        .disabled(library.isWorking || model.isWorkingWithWallpapers || model.isLoading)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 24)
                .background(Color.teal.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            } else if !library.entries.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top),
                                    GridItem(.flexible(), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(library.entries) { entry in card(entry) }
                }
            }

            if model.selectedURL != nil && model.activeWallpaperID == nil {
                HStack(alignment: .center, spacing: 12) {
                    Text(localizer.text("Текущего видео ещё нет в коллекции. Сохрани его вместе с настройками."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(localizer.text("Сохранить текущие обои")) {
                        Task { await model.saveCurrentWallpaperToLibrary() }
                    }
                    .disabled(library.isWorking || model.isWorkingWithWallpapers || model.isLoading)
                }
                .padding(14)
                .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { await library.reload() }
        .sheet(item: $sheet) { editor in
            switch editor {
            case .rename(let entry):
                WallpaperRenameSheet(model: model, library: library, entry: entry)
            case .settings(let entry):
                WallpaperOptionsSheet(model: model, library: library, entry: entry)
            }
        }
        .alert(localizer.text("Удалить обои?"), isPresented: $showsDeletion, presenting: pendingDeletion) { entry in
            Button(localizer.text("Удалить"), role: .destructive) {
                Task { await model.deleteWallpaper(entry) }
            }
            Button(localizer.text("Отмена"), role: .cancel) {}
        } message: { entry in
            Text(localizer.format("«%@» и копия видео будут удалены из коллекции. Исходное видео останется. Если эти обои включены, воспроизведение остановится. Сохранённый системный кадр останется.", entry.name))
        }
    }

    private func card(_ entry: WallpaperLibraryEntry) -> some View {
        let selected = model.activeWallpaperID == entry.id
        let changed = selected && model.currentWallpaperOptions != entry.options
        let applied = selected && model.hasWallpaper && !changed
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.applyWallpaper(entry) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { geometry in
                        ZStack {
                            Color.teal.opacity(0.12)
                            if let image = library.thumbnails[entry.id] {
                                Image(nsImage: image).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            } else {
                                Image(systemName: "photo.fill")
                                    .font(.system(size: 24)).foregroundStyle(.teal)
                            }
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .accessibilityHidden(true)

                    HStack(spacing: 8) {
                        Text(entry.name).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                                .accessibilityLabel(localizer.text("Выбрано"))
                        }
                    }
                    .frame(minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizer.format("Применить обои «%@»", entry.name))
            .disabled(library.isWorking || model.isWorkingWithWallpapers || model.isLoading || applied)

            HStack(spacing: 10) {
                Button(localizer.text(applied ? "Применено" : "Применить")) { model.applyWallpaper(entry) }
                    .controlSize(.small)
                    .disabled(applied || model.isLoading)
                Spacer(minLength: 0)
                Menu {
                    Button(localizer.text("Настроить…")) {
                        library.dismissFailure()
                        sheet = .settings(entry)
                    }
                    Button(localizer.text("Переименовать…")) {
                        library.dismissFailure()
                        sheet = .rename(entry)
                    }
                    Divider()
                    Button(localizer.text("Удалить из библиотеки…"), role: .destructive) {
                        pendingDeletion = entry
                        showsDeletion = true
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(localizer.format("Действия с обоями «%@»", entry.name))
            }
            .disabled(library.isWorking || model.isWorkingWithWallpapers || model.isLoading)
            .padding(.horizontal, 14).padding(.bottom, 14)

        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.teal.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        }
    }
}

@MainActor
private struct WallpaperRenameSheet: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var library: WallpaperLibraryController
    let entry: WallpaperLibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false
    private var localizer: AppLocalizer { model.localizer }

    init(model: WallpaperModel, library: WallpaperLibraryController, entry: WallpaperLibraryEntry) {
        self.model = model
        self.library = library
        self.entry = entry
        _name = State(initialValue: entry.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localizer.text("Переименовать обои")).font(.headline)
            TextField(localizer.text("Название обоев"), text: $name)
                .textFieldStyle(.roundedBorder).disabled(isSaving)
            Text(localizer.text("До 80 символов. Название можно изменить в любой момент."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let failure = library.failure {
                WallpaperLibraryFailureView(failure: failure, localizer: localizer)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(localizer.text("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(localizer.text("Сохранить")) {
                    isSaving = true
                    Task {
                        let saved = await model.renameWallpaper(entry, name: name)
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || library.isWorking || model.isWorkingWithWallpapers || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || name.count > 80 || name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
            }
        }
        .padding(24).frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isSaving)
    }
}

@MainActor
struct WallpaperOptionsSheet: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var library: WallpaperLibraryController
    let entry: WallpaperLibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var options: WallpaperLibraryOptions
    @State private var isSaving = false
    private var localizer: AppLocalizer { model.localizer }

    init(model: WallpaperModel, library: WallpaperLibraryController, entry: WallpaperLibraryEntry) {
        self.model = model
        self.library = library
        self.entry = entry
        _options = State(initialValue: entry.options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(localizer.text("Настройки обоев")).font(.system(size: 20, weight: .semibold))
                Text(entry.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(localizer.text("Настройки сохранятся для этих обоев. Если они сейчас включены, изменения применятся сразу."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    appearance
                    audio
                    power
                    if let failure = library.failure {
                        WallpaperLibraryFailureView(failure: failure, localizer: localizer)
                    }
                }
                .padding(20)
            }
            .disabled(isSaving)
            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(localizer.text("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(localizer.text("Сохранить")) {
                    isSaving = true
                    Task {
                        let saved = await model.updateWallpaper(entry, options: options)
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || library.isWorking || model.isWorkingWithWallpapers || model.isLoading)
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isSaving)
    }

    private var appearance: some View {
        SettingsGroup(title: localizer.text("Оформление")) {
            SettingsRow(title: localizer.text("Экран"), symbol: "display.2", color: .blue) {
                Picker(localizer.text("Экран"), selection: $options.target) {
                    ForEach(DisplayTarget.allCases) { Text(localizer.text($0.title)).tag($0) }
                }.labelsHidden().frame(width: 170)
            }
            SettingsDivider()
            SettingsRow(title: localizer.text("Масштаб"), symbol: "arrow.up.left.and.arrow.down.right", color: .purple) {
                Picker(localizer.text("Масштаб"), selection: $options.scaling) {
                    ForEach(VideoScaling.allCases) { Text(localizer.text($0.title)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 176)
            }
            SettingsDivider()
            SettingsToggle(title: localizer.text("Системный фон из видео"),
                           detail: localizer.text("Сохранять кадр видео как обои macOS. Он останется после выхода из приложения."),
                           symbol: "photo.on.rectangle", color: .teal, isOn: $options.syncSystemWallpaper)
            if options.syncSystemWallpaper {
                Text(localizer.text("Применяется к текущему рабочему столу на выбранных экранах. macOS может отключить показ на всех пространствах Spaces."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    private var audio: some View {
        SettingsGroup(title: localizer.text("Звук")) {
            SettingsToggle(title: localizer.text("Без звука"), symbol: "speaker.slash.fill", color: .pink, isOn: $options.isMuted)
            SettingsDivider()
            SettingsRow(title: localizer.text("Громкость"), symbol: "speaker.wave.2.fill", color: .pink) {
                HStack(spacing: 8) {
                    Slider(value: $options.volume, in: 0...1)
                        .accessibilityLabel(localizer.text("Громкость")).frame(width: 150)
                    Text("\(Int((options.volume * 100).rounded()))%")
                        .font(.system(size: 12)).monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }
        }
    }

    private var power: some View {
        SettingsGroup(title: localizer.text("Питание")) {
            SettingsToggle(title: localizer.text("Анимация от сети"), symbol: "powerplug.fill", color: .teal,
                           isOn: $options.animateOnExternalPower)
            SettingsDivider()
            SettingsToggle(title: localizer.text("Анимация от батареи"),
                           detail: localizer.text("По умолчанию — статичный кадр для экономии энергии."),
                           symbol: "battery.100", color: .orange, isOn: $options.animateOnBattery)
            SettingsDivider()
            SettingsToggle(title: localizer.text("Пауза в режиме энергосбережения"),
                           detail: localizer.text("Учитывать режим энергосбережения macOS."),
                           symbol: "leaf.fill", color: .green, isOn: $options.pauseInLowPowerMode)
            SettingsDivider()
            SettingsToggle(title: localizer.text("Пауза, когда рабочий стол скрыт"),
                           symbol: "macwindow.on.rectangle", color: .blue, isOn: $options.pauseWhenCovered)
        }
    }
}

@MainActor
private struct WallpaperLibraryFailureView: View {
    let failure: WallpaperLibraryError
    let localizer: AppLocalizer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(localizer.text(failure.ruKey))
                if let detail = failure.detail { Text(detail).foregroundStyle(.secondary) }
            }
            .font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
