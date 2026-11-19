import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case wallpaper, general, power

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wallpaper: return "Обои"
        case .general: return "Основные"
        case .power: return "Питание"
        }
    }
    var symbol: String {
        switch self {
        case .wallpaper: return "photo.on.rectangle"
        case .general: return "gearshape.fill"
        case .power: return "battery.100percent"
        }
    }
    var color: Color {
        switch self {
        case .wallpaper: return .blue
        case .general: return .gray
        case .power: return .green
        }
    }
    var subtitle: String {
        switch self {
        case .wallpaper: return "Видео и оформление рабочего стола."
        case .general: return "Запуск приложения и воспроизведение."
        case .power: return "Выбери, когда обои будут двигаться."
        }
    }
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var section: AppSection = .wallpaper
}
