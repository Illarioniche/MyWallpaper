import SwiftUI

@MainActor
struct UpdateAvailableBanner: View {
    let version: String
    var localizer: AppLocalizer = .russian
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 22)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(localizer.format("Доступна версия %@", version))
                    .font(.system(size: 13, weight: .semibold))
                Text(localizer.text("Посмотри, что нового, и скачай обновление."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(localizer.text("Подробнее"), action: onOpen)
        }
        .padding(16)
        .background(Color.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

@MainActor
struct UpdateSettingsPane: View {
    @ObservedObject var updates: UpdateController
    var localizer: AppLocalizer = .russian

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsIntro(symbol: "arrow.down.circle.fill", color: .teal,
                          title: localizer.text("MyWallpaper становится лучше"),
                          detail: localizer.text("Проверяй новые версии и выбирай, когда их установить."))
            SettingsGroup(title: localizer.text("Версия приложения")) {
                SettingsRow(title: "MyWallpaper", detail: localizer.format("Установлена версия %@", localizer.text(updates.currentVersion)),
                            symbol: "app.badge", color: .teal) {
                    Button {
                        Task { await updates.checkNow() }
                    } label: {
                        Text(updates.isChecking ? localizer.text("Проверяем…") : localizer.text("Проверить обновления"))
                    }
                    .disabled(updates.isChecking)
                }
                SettingsDivider()
                HStack(alignment: .top, spacing: 10) {
                    if updates.isChecking {
                        ProgressView().controlSize(.small).frame(width: 16)
                    } else {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                            .frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(statusText).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = updates.lastChecked {
                            Text(localizer.format("Последняя успешная проверка: %@",
                                                  date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(localizer.locale))))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }

            if let release = updates.availableRelease {
                releaseCard(release)
            }

            SettingsGroup(title: localizer.text("Проверка обновлений")) {
                SettingsToggle(title: localizer.text("Проверять автоматически"),
                               detail: localizer.text("Раз в сутки, пока приложение работает. Только стабильные релизы."),
                               symbol: "arrow.triangle.2.circlepath", color: .blue,
                               isOn: $updates.automaticChecksEnabled)
            }
            Text(localizer.text("Новая версия появится здесь и в строке меню. Файлы скачиваются через браузер — установку ты запускаешь сам."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func releaseCard(_ release: UpdateRelease) -> some View {
        SettingsGroup(title: localizer.text("Доступно обновление")) {
            VStack(alignment: .leading, spacing: 14) {
                Label("MyWallpaper \(release.version)", systemImage: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.teal)
                if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Show release text as plain text; links are explicit, validated destinations.
                    Text(release.notes)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    if let download = release.downloadURL {
                        Link(destination: download) {
                            Label(localizer.text("Скачать DMG"), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    Link(localizer.text("Что нового"), destination: release.pageURL)
                    if let checksum = release.checksumURL {
                        Link("SHA-256", destination: checksum)
                            .help(localizer.text("Скачать контрольную сумму образа"))
                    }
                }
                if release.downloadURL == nil {
                    Text(localizer.text("DMG пока не прикреплён. Открой страницу релиза, чтобы посмотреть доступные файлы."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                Text(localizer.text("После скачивания заверши MyWallpaper через строку меню. Открой DMG, перенеси приложение в «Программы» с заменой и запусти его снова."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusText: String {
        switch updates.state {
        case .idle: return localizer.text("Проверь, появилась ли новая версия.")
        case .checking: return localizer.text("Проверяем GitHub Releases…")
        case .upToDate: return localizer.text("Новых версий нет.")
        case .available(let release): return localizer.format("Доступна версия %@.", release.version)
        case .failed(let message): return message
        }
    }

    private var statusSymbol: String {
        switch updates.state {
        case .upToDate: return "checkmark.circle.fill"
        case .available: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .idle, .checking: return "clock"
        }
    }

    private var statusColor: Color {
        switch updates.state {
        case .upToDate, .available: return .teal
        case .failed: return .orange
        case .idle, .checking: return .secondary
        }
    }
}
