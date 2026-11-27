import SwiftUI

@MainActor
struct QuickStartCard: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.localizer.text("Добро пожаловать в MyWallpaper"))
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(model.localizer.text("Три подсказки для начала"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: model.dismissQuickStart) {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.localizer.text("Закрыть подсказку"))
            }
            tip("film", "Добавь видео в коллекцию — оно станет обоями. Звук, масштаб и другие параметры — в настройках карточки.")
            tip("leaf", "По умолчанию обои движутся от сети и замирают от батареи. Это можно изменить в разделе «Питание».")
            tip("menubar.rectangle", "Закрой окно — обои продолжат работать. Пауза и настройки доступны через значок в строке меню.")
            Button(model.localizer.text("Понятно"), action: model.dismissQuickStart)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.teal.opacity(0.2), lineWidth: 0.5)
        }
    }

    private func tip(_ symbol: String, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.teal)
                .frame(width: 20, height: 17).accessibilityHidden(true)
            Text(model.localizer.text(key))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PlaybackExplanationView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "pause.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 310, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct GeneralHelpSection: View {
    @ObservedObject var model: WallpaperModel
    let showQuickStart: () -> Void

    var body: some View {
        SettingsGroup(title: model.localizer.text("Помощь")) {
            SettingsRow(title: model.localizer.text("Краткая инструкция"),
                        detail: model.localizer.text("Как выбрать видео, управлять паузой и найти приложение в строке меню."),
                        symbol: "questionmark.circle", color: .blue) {
                Button(model.localizer.text("Показать"), action: showQuickStart)
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: model.localizer.text("Сообщить о проблеме"),
                            detail: model.localizer.text("Скопируй сведения о приложении и приложи их к сообщению об ошибке."),
                            symbol: "doc.text.magnifyingglass", color: .teal) {
                    DiagnosticCopyButton(model: model)
                }
                Text(model.localizer.text("Без путей к файлам и названий видео. Копирование ничего не отправляет."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 60).padding(.trailing, 16).padding(.bottom, 14)
            }
        }
    }
}

@MainActor
struct DiagnosticCopyButton: View {
    @ObservedObject var model: WallpaperModel
    @State private var result: Bool?

    var body: some View {
        Button {
            result = model.copyDiagnostics()
        } label: {
            Label(model.localizer.text(titleKey), systemImage: result == true ? "checkmark" : "doc.on.doc")
        }
        .help(model.localizer.text("Диагностика на английском языке для сообщения об ошибке."))
        .task(id: result) {
            guard result != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            result = nil
        }
    }

    private var titleKey: String {
        switch result {
        case true: "Скопировано"
        case false: "Не удалось скопировать"
        case nil: "Скопировать диагностику"
        }
    }
}
