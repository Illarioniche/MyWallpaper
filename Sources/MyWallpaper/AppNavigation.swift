import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case wallpaper, general, power, updates

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wallpaper: return "Обои"
        case .general: return "Основные"
        case .power: return "Питание"
        case .updates: return "Обновления"
        }
    }
    var symbol: String {
        switch self {
        case .wallpaper: return "photo.on.rectangle"
        case .general: return "gearshape.fill"
        case .power: return "battery.100"
        case .updates: return "arrow.down.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .wallpaper: return .blue
        case .general: return .gray
        case .power: return .green
        case .updates: return .teal
        }
    }
    var subtitle: String {
        switch self {
        case .wallpaper: return "Видео и оформление рабочего стола."
        case .general: return "Запуск приложения и воспроизведение."
        case .power: return "Выбери, когда обои будут двигаться."
        case .updates: return "Новые версии MyWallpaper с GitHub."
        }
    }
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var section: AppSection = .wallpaper
}
