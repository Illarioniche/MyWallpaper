import SwiftUI

@MainActor
struct ScreenSaverSettingsPane: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var screenSaver: ScreenSaverController
    @State private var renamingEntry: ScreenSaverLibraryEntry?
    @State private var renameText = ""
    @State private var pendingDeletion: ScreenSaverLibraryEntry?
    @State private var showsDeletion = false
    private var localizer: AppLocalizer { model.localizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let failure = screenSaver.failure {
                message(localizer.text(failure.ruKey), detail: failure.detail, isError: true)
            }
            if !screenSaver.libraryWarnings.isEmpty {
                message(localizer.text("Некоторые заставки не удалось загрузить. Остальные доступны в библиотеке."),
                        detail: screenSaver.libraryWarnings.first.map { localizer.text($0.ruKey) }, isError: false)
            }

            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localizer.text("Мои заставки")).font(.system(size: 17, weight: .semibold))
                    Text(localizer.text("Твоя коллекция видео для отдыхающего Mac."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Button {
                    screenSaver.beginCreating()
                } label: {
                    Label(localizer.text("Новая заставка"), systemImage: "plus")
                }
                .controlSize(.large)
                .disabled(screenSaver.isBusy)
            }

            if screenSaver.isCreating { composer }

            if !screenSaver.hasLoadedLibrary && screenSaver.isWorking {
                ProgressView(localizer.text("Загружаем библиотеку…"))
                    .frame(maxWidth: .infinity).padding(28)
            } else if screenSaver.entries.isEmpty && !screenSaver.isCreating {
                VStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.indigo)
                    Text(localizer.text("Здесь будут твои заставки"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(localizer.text("Добавь видео и дай ему название. MyWallpaper сохранит всё автоматически."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 370)
                    Button(localizer.text("Создать первую заставку")) {
                        screenSaver.beginCreating()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
                    .disabled(screenSaver.isBusy)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 24)
                .background(Color.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(screenSaver.entries) { entry in libraryCard(entry) }
                }
            }

            if let name = screenSaver.installationRequestedName {
                message(localizer.format("Открыта установка «%@».", name),
                        detail: localizer.format("Подтверди установку в macOS, затем выбери «%@» в настройках заставки.", name)
                            + "\n" + systemSettingsInstructions,
                        isError: false)
            }

            SettingsGroup(title: localizer.text("Установка в macOS")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localizer.text("Выбери сохранённую заставку и нажми «Установить». Подтверди установку для своего пользователя. Разные заставки можно установить одновременно; при повторной установке той же заставки подтверди замену."))
                    Text(systemSettingsInstructions)
                    Text(localizer.text("Если новая заставка не появилась, закрой и снова открой системные настройки."))
                    Button(localizer.text("Открыть настройки заставки")) {
                        screenSaver.openSystemSettings()
                    }
                    .controlSize(.regular).foregroundStyle(.primary)
                    Text(localizer.text("Новое название появится в macOS после повторной установки этой заставки."))
                    Text(localizer.text("Заставки работают без запущенного MyWallpaper и всегда без звука."))
                    Divider()
                    Text(localizer.text("После установки проверь, что заставка появилась в системном списке и работает в предпросмотре."))
                    Text(localizer.text("Экспериментальная функция. Видео за полем ввода пароля и на экране входа после перезагрузки пока не поддерживается. Отображением заставки при блокировке управляет macOS."))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(16)
            }
        }
        .task { await screenSaver.reloadLibrary() }
        .sheet(item: $renamingEntry) { entry in renameSheet(entry) }
        .alert(localizer.text("Удалить заставку?"), isPresented: $showsDeletion, presenting: pendingDeletion) { entry in
            Button(localizer.text("Удалить"), role: .destructive) {
                Task { await screenSaver.delete(id: entry.id) }
            }
            Button(localizer.text("Отмена"), role: .cancel) {}
        } message: { entry in
            Text(localizer.format("«%@» и её копия видео будут удалены из библиотеки. Исходное видео и установленная в macOS заставка останутся.", entry.name))
        }
    }

    private var systemSettingsInstructions: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if version >= 26 {
            return localizer.text("В системных настройках открой «Обои» → «Заставка…» и выбери «Настроить» в строке «Использовать заставку». Прокрути список внутри диалога вниз до раздела «Другое» и при необходимости нажми «Показать все».")
        }
        if version >= 14 {
            return localizer.text("В системных настройках открой «Заставка» и раздел «Другое». При необходимости разверни весь список.")
        }
        return localizer.text("В системных настройках открой «Заставка» и найди установленную заставку в списке миниатюр.")
    }

    private func libraryCard(_ entry: ScreenSaverLibraryEntry) -> some View {
        let selected = screenSaver.selectedEntryID == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            Button { screenSaver.selectEntry(entry.id) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { geometry in
                        ZStack {
                            Color.indigo.opacity(0.12)
                            if let image = screenSaver.thumbnails[entry.id] {
                                Image(nsImage: image).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            } else {
                                Image(systemName: "moon.stars.fill").font(.system(size: 24)).foregroundStyle(.indigo)
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
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
                                .accessibilityLabel(localizer.text("Выбрано"))
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name)
            .disabled(screenSaver.isWorking)

            HStack(spacing: 10) {
                Button(localizer.text("Установить…")) {
                    Task { await screenSaver.install(id: entry.id) }
                }
                .controlSize(.small)
                Spacer(minLength: 0)
                Menu {
                    Button(localizer.text("Переименовать…")) {
                        renameText = entry.name
                        renamingEntry = entry
                    }
                    Button(localizer.text("Удалить из библиотеки…"), role: .destructive) {
                        pendingDeletion = entry
                        showsDeletion = true
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(localizer.format("Действия с заставкой «%@»", entry.name))
            }
            .disabled(screenSaver.isBusy)
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.indigo.opacity(0.75) : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(localizer.text("Новая заставка")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    screenSaver.resetDraft()
                } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localizer.text("Закрыть"))
                    .disabled(screenSaver.isWorking)
            }
            SettingsGroup(title: localizer.text("Название и видео")) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(localizer.text("Например, «Ночной город»"), text: $screenSaver.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(localizer.text("Название заставки"))
                    preview.aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).frame(maxWidth: .infinity)
                    HStack(spacing: 10) {
                        Button(localizer.text("Выбрать видео")) { screenSaver.chooseVideo(localizer: localizer) }
                        Button(localizer.text("Из текущих обоев")) {
                            if let url = model.selectedURL { screenSaver.selectVideo(url) }
                        }.disabled(model.selectedURL == nil)
                        Spacer(minLength: 0)
                    }
                    if let url = screenSaver.selectedURL {
                        Label(url.lastPathComponent, systemImage: "film")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(16)
            }
            .disabled(screenSaver.isBusy)

            SettingsGroup(title: localizer.text("Оформление и питание")) {
                SettingsRow(title: localizer.text("Масштаб"), symbol: "arrow.up.left.and.arrow.down.right", color: .purple) {
                    Picker(localizer.text("Масштаб"), selection: $screenSaver.scaling) {
                        ForEach(VideoScaling.allCases) { Text(localizer.text($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 176)
                }
                SettingsDivider()
                SettingsToggle(title: localizer.text("Анимация от сети"),
                               detail: localizer.text("При выключенном режиме остаётся неподвижный кадр."),
                               symbol: "powerplug.fill", color: .teal, isOn: $screenSaver.animateOnExternalPower)
                SettingsDivider()
                SettingsToggle(title: localizer.text("Анимация от батареи"),
                               detail: localizer.text("По умолчанию — статичный кадр для экономии энергии."),
                               symbol: "battery.100", color: .orange, isOn: $screenSaver.animateOnBattery)
                SettingsDivider()
                SettingsToggle(title: localizer.text("Пауза в режиме энергосбережения"),
                               detail: localizer.text("Учитывать режим энергосбережения macOS."),
                               symbol: "leaf.fill", color: .green, isOn: $screenSaver.pauseInLowPowerMode)
            }
            .disabled(screenSaver.isBusy)

            if screenSaver.isPreparing || screenSaver.isSaving {
                ProgressView(localizer.text(screenSaver.isPreparing ? "Открываем видео…" : "Сохраняем в библиотеку…"))
                    .controlSize(.small).font(.system(size: 12))
            } else {
                Button { Task { await screenSaver.saveToLibrary() } } label: {
                    Label(localizer.text("Сохранить в библиотеку"), systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!screenSaver.canSave)
            }
            if !screenSaver.hasTemplate {
                Text(localizer.text("Создание заставок доступно в собранном MyWallpaper.app."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(localizer.text("Заставка сохранится в коллекции и будет доступна после перезапуска."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.indigo.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }

    private func renameSheet(_ entry: ScreenSaverLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localizer.text("Переименовать заставку")).font(.headline)
            TextField(localizer.text("Название заставки"), text: $renameText)
                .textFieldStyle(.roundedBorder)
            Text(localizer.text("До 80 символов. Название можно изменить в любой момент."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(localizer.text("Новое название появится в macOS после повторной установки этой заставки."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(localizer.text("Отмена")) { renamingEntry = nil }.keyboardShortcut(.cancelAction)
                Button(localizer.text("Сохранить")) {
                    let name = renameText
                    renamingEntry = nil
                    Task { await screenSaver.rename(id: entry.id, name: name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameText.count > 80)
            }
        }
        .padding(24).frame(width: 380)
    }

    private func message(_ title: String, detail: String?, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.orange : .indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            .font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if isError {
                Button(action: screenSaver.dismissFailure) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(localizer.text("Закрыть сообщение"))
            }
        }
        .padding(14)
        .background((isError ? Color.orange : .indigo).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.8), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = screenSaver.thumbnail {
                    Image(nsImage: image).resizable()
                        .aspectRatio(contentMode: screenSaver.scaling == .fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height).background(.black)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "moon.stars.fill").font(.system(size: 32, weight: .light))
                        Text(localizer.text("Выбери MP4 или MOV для системной заставки."))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(20).foregroundStyle(.white).multilineTextAlignment(.center)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityLabel(localizer.text("Предпросмотр заставки"))
    }
}
