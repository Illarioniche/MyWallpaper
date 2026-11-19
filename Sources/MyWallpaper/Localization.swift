import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case russian = "ru"
    case english = "en"

    var id: String { rawValue }

    func title(using localizer: AppLocalizer) -> String {
        switch self {
        case .system: return localizer.text("Системный")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

/// Resolves app language independently of the process-wide preferred localization.
/// This lets open windows and existing errors update without relaunching the app.
struct AppLocalizer: Sendable, Equatable {
    let language: AppLanguage
    let resolvedCode: String
    var locale: Locale { Locale(identifier: resolvedCode) }

    static let russian = AppLocalizer(language: .russian)

    init(language: AppLanguage = .system, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = language
        if language == .system {
            resolvedCode = preferredLanguages.lazy.compactMap { identifier in
                let code = identifier.replacingOccurrences(of: "_", with: "-")
                    .split(separator: "-").first?.lowercased()
                return code == "ru" || code == "en" ? code : nil
            }.first ?? "en"
        } else {
            resolvedCode = language.rawValue
        }
    }

    func text(_ ruKey: String) -> String {
        Self.tables[resolvedCode]?[ruKey] ?? ruKey
    }

    func format(_ ruKey: String, _ arguments: CVarArg...) -> String {
        String(format: text(ruKey), locale: locale, arguments: arguments)
    }

    /// Immutable tables are safe to use from UI, parsers and async error handling.
    private static let tables: [String: [String: String]] = {
        var roots: [URL] = []
        let codes = ["ru", "en"]
        let mainResources = Bundle.main.resourceURL
        if let mainResources { roots.append(mainResources) }
        #if SWIFT_PACKAGE
        // The packaged .app copies catalogs directly into Contents/Resources.
        // Bundle.module can fatalError after relocation when its generated
        // SwiftPM bundle is absent, so never evaluate it for that layout.
        let mainHasCatalogs = mainResources.map { root in
            codes.allSatisfy { code in
                FileManager.default.fileExists(atPath: root.appendingPathComponent("\(code).lproj/Localizable.strings").path)
            }
        } ?? false
        if !mainHasCatalogs, let resources = Bundle.module.resourceURL { roots.append(resources) }
        #else
        // The standalone preview/smoke drivers compile sources without SwiftPM.
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true))
        #endif
        var tables: [String: [String: String]] = [:]
        for code in codes {
            for root in roots {
                let url = root.appendingPathComponent("\(code).lproj/Localizable.strings")
                guard let data = try? Data(contentsOf: url),
                      let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dictionary = value as? [String: String] else { continue }
                tables[code] = dictionary
                break
            }
        }
        return tables
    }()
}
