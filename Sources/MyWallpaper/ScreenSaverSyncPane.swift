import SwiftUI

@MainActor
struct ScreenSaverSyncPane: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject private var sync: ScreenSaverSyncController
    @State private var showsInstructions = false
    private var localizer: AppLocalizer { model.localizer }

    init(model: WallpaperModel) {
        self.model = model
        self.sync = model.screenSaverSync
    }

    var body: some View {
        SettingsGroup(title: localizer.text("Обои и заставка вместе")) {
            SettingsToggle(title: localizer.text("Синхронизировать с обоями"),
                           detail: localizer.text("Одно видео, масштаб и режимы питания для рабочего стола и заставки."),
                           symbol: "link", color: .indigo, isOn: $model.syncScreenSaver)

            if model.syncScreenSaver || sync.snapshot != nil || sync.installationRequested || sync.isInstalled {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "moon.stars.fill").foregroundStyle(.indigo)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MyWallpaper — Sync").font(.system(size: 13, weight: .semibold))
                            if sync.isInstalled {
                                Label(localizer.text("Заставка установлена"), systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11)).foregroundStyle(.green)
                            }
                            if let snapshot = sync.snapshot {
                                Text(snapshot.name).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            } else if model.selectedURL == nil {
                                Text(localizer.text("Сначала выбери видео в разделе «Обои»."))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            } else if !sync.isWorking {
                                Text(localizer.text("Подготовь видео для связанной заставки."))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if sync.isInstalled { installedActions }
                    }

                    if sync.isWorking {
                        ProgressView(localizer.text(sync.isInstalling
                            ? "Готовим установку связанной заставки…" : "Синхронизируем заставку…"))
                            .controlSize(.small).font(.system(size: 12))
                    }

                    if !model.syncScreenSaver, sync.snapshot != nil {
                        Text(localizer.text("Синхронизация выключена. Установленная заставка продолжит показывать последнее сохранённое видео."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }

                    if !sync.isInstalled {
                        HStack(spacing: 10) {
                            Button {
                                Task { await sync.install() }
                            } label: {
                                Label(localizer.text("Установить MyWallpaper — Sync…"), systemImage: "arrow.down.to.line")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canInstall)
                            Button(localizer.text("Открыть настройки заставки")) {
                                model.screenSaver.openSystemSettings()
                            }
                        }
                        .controlSize(.regular)

                        if !sync.hasTemplate {
                            Text(localizer.text("Установка связанной заставки доступна в собранном MyWallpaper.app."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if sync.installationRequested {
                            Label(localizer.text("Открыт диалог установки. Подтверди его в macOS, затем выбери «MyWallpaper — Sync» в настройках заставки."),
                                  systemImage: "info.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }

                    if !sync.isInstalled || showsInstructions {
                        DisclosureGroup(localizer.text("Как включить в macOS"), isExpanded: $showsInstructions) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(localizer.text("Установи и выбери «MyWallpaper — Sync» один раз. Затем смена обоев и их настроек будет обновлять эту заставку без повторной установки."))
                                Text(systemSettingsInstructions)
                                Text(localizer.text("Обычные заставки из коллекции остаются отдельными. Для автоматического обновления в macOS должна быть выбрана именно «MyWallpaper — Sync»."))
                            }
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.top, 7)
                        }
                        .font(.system(size: 12))

                        Text(localizer.text("Заставка всегда без звука. Ручная пауза и перекрытие рабочего стола окнами на неё не влияют. После выхода из приложения или удаления обоев последнее сохранённое видео остаётся в заставке."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
            }

            if let failure = sync.failure {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localizer.text(failure.ruKey))
                            if let detail = failure.detail { Text(detail).foregroundStyle(.secondary) }
                        }
                        .font(.system(size: 12)).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button(action: sync.dismissFailure) { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(localizer.text("Закрыть сообщение"))
                    }
                    Button(localizer.text("Повторить синхронизацию")) { model.synchronizeScreenSaver() }
                        .disabled(!model.syncScreenSaver || model.selectedURL == nil || model.isLoading || sync.isWorking)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
            }
        }
        .task {
            if !sync.isWorking { await sync.reload() }
            else { await sync.refreshInstallation() }
        }
        .onChange(of: sync.isInstalled) { _ in showsInstructions = false }
    }

    private var canInstall: Bool {
        sync.hasTemplate && sync.snapshot != nil && !sync.isWorking && sync.failure == nil
    }

    private var installedActions: some View {
        Menu {
            Button(localizer.text("Открыть настройки заставки")) { model.screenSaver.openSystemSettings() }
            Button(localizer.text("Переустановить…")) { Task { await sync.install() } }
                .disabled(!canInstall)
            Divider()
            Button(localizer.text("Как включить в macOS")) { showsInstructions = true }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(localizer.format("Действия с заставкой «%@»", "MyWallpaper — Sync"))
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
}
