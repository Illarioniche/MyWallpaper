import AppKit
import Combine
import CoreServices
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case unavailable

    init(serviceStatus: SMAppService.Status) {
        switch serviceStatus {
        case .enabled: self = .enabled
        case .notRegistered: self = .disabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unavailable
        }
    }
}

/// Location checks are separate from ServiceManagement's registration status.
/// In particular, .notFound says nothing about whether the caller is an app.
enum LoginItemAvailability: Equatable, Sendable {
    case available
    case notAppBundle
    case readOnlyVolume
    case translocated

    static func assess(bundleURL: URL, executableURL: URL?, bundleIdentifier: String?,
                       packageType: String?, volumeIsReadOnly: Bool?) -> LoginItemAvailability {
        let appURL = bundleURL.standardizedFileURL
        guard appURL.isFileURL, appURL.pathExtension.lowercased() == "app",
              packageType == "APPL", let bundleIdentifier, !bundleIdentifier.isEmpty,
              let executableURL, executableURL.isFileURL,
              executableURL.deletingLastPathComponent().standardizedFileURL
                == appURL.appendingPathComponent("Contents/MacOS", isDirectory: true) else {
            return .notAppBundle
        }

        if volumeIsReadOnly == true {
            // Translocation has no public detection API. Recognize its current
            // path only to improve the explanation for an already read-only
            // location; safety never depends on this undocumented path shape.
            let components = appURL.pathComponents
            if let marker = components.lastIndex(of: "AppTranslocation"),
               components.count > marker + 3,
               UUID(uuidString: components[marker + 1]) != nil,
               components[marker + 2] == "d" {
                return .translocated
            }
            return .readOnlyVolume
        }
        // Do not reject /Volumes in general: an app on a writable external
        // disk can be registered. An unavailable volume flag is not proof of
        // an unsuitable location; register() will report any actual failure.
        return .available
    }

    fileprivate var explanation: String? {
        switch self {
        case .available: return nil
        case .notAppBundle:
            return "Для автозапуска открой MyWallpaper.app. Запуск исполняемого файла вне приложения не поддерживается."
        case .readOnlyVolume:
            return "Приложение открыто с диска только для чтения. Перенеси MyWallpaper в «Программы», заверши эту копию и открой установленную."
        case .translocated:
            return "macOS открыла приложение из временной папки. Перенеси MyWallpaper в «Программы», заверши эту копию и открой установленную."
        }
    }
}

/// Keeps registration operations replaceable in tests without changing real login items.
@MainActor
protocol LoginItemServicing: AnyObject {
    var status: LoginItemStatus { get }
    var availability: LoginItemAvailability { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

extension LoginItemServicing {
    // Test services and other injected implementations do not inherit the
    // test runner's command-line bundle or touch a real registration.
    var availability: LoginItemAvailability { .available }
}

@MainActor
private final class SystemLoginItemService: LoginItemServicing {
    var availability: LoginItemAvailability {
        let bundle = Bundle.main
        let readOnly = try? bundle.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
        return LoginItemAvailability.assess(
            bundleURL: bundle.bundleURL, executableURL: bundle.executableURL,
            bundleIdentifier: bundle.bundleIdentifier,
            packageType: bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
            volumeIsReadOnly: readOnly
        )
    }

    var status: LoginItemStatus {
        guard availability == .available else { return .unavailable }
        return LoginItemStatus(serviceStatus: SMAppService.mainApp.status)
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var availability: LoginItemAvailability
    @Published private(set) var errorMessage: String?
    @Published var localizer: AppLocalizer {
        didSet { renderError() }
    }

    private let service: any LoginItemServicing
    private var activationObserver: AnyCancellable?
    private var errorKey: String?
    private var errorDetail: String?

    init(service: (any LoginItemServicing)? = nil,
         notificationCenter: NotificationCenter = .default,
         localizer: AppLocalizer = .english) {
        let resolvedService = service ?? SystemLoginItemService()
        self.service = resolvedService
        self.localizer = localizer
        availability = resolvedService.availability
        status = resolvedService.status
        activationObserver = notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    var canToggle: Bool {
        availability == .available && status != .unavailable && status != .requiresApproval
    }

    var statusDetail: String {
        localizer.text(statusDetailKey)
    }

    private var statusDetailKey: String {
        if let explanation = availability.explanation { return explanation }
        switch status {
        case .enabled, .disabled:
            return "Открывать в строке меню без лишних окон."
        case .requiresApproval:
            return "Разреши автозапуск MyWallpaper в системных настройках macOS."
        case .notFound:
            return "macOS не нашла службу автозапуска. Попробуй включить её повторно или добавь приложение в объекты входа вручную."
        case .unavailable:
            return "Не удалось определить состояние автозапуска. Проверь MyWallpaper в объектах входа macOS."
        }
    }

    /// Read the system again after returning from Settings or opening the controls.
    func refresh() {
        let currentAvailability = service.availability
        let currentStatus = service.status
        if currentStatus != status || currentAvailability != availability { setError(nil) }
        availability = currentAvailability
        status = currentStatus
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        setError(nil)

        guard availability == .available else {
            setError(availability.explanation)
            return
        }
        guard status != .unavailable else {
            setError(statusDetailKey)
            return
        }

        // A pending service is already registered. Approval must come from the user
        // in System Settings; registering again cannot override that decision.
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .disabled { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            status = service.status
            if enabled && status != .enabled && status != .requiresApproval {
                setError("macOS пока не подтвердила автозапуск. Повтори попытку или добавь MyWallpaper в объекты входа вручную.")
            }
        } catch {
            // An operation can fail after the system state has changed. Never infer
            // the checkbox state from the requested value or from a cached preference.
            status = service.status
            let key = enabled ? "Не удалось включить автозапуск. %@" : "Не удалось выключить автозапуск. %@"
            setError(key, detail: error.localizedDescription)
        }
    }

    private func setError(_ key: String?, detail: String? = nil) {
        errorKey = key
        errorDetail = detail
        renderError()
    }

    private func renderError() {
        guard let errorKey else { errorMessage = nil; return }
        if let errorDetail {
            errorMessage = localizer.format(errorKey, errorDetail)
        } else {
            errorMessage = localizer.text(errorKey)
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    /// Read this during applicationWill/DidFinishLaunching, while the launch event is current.
    static func wasLaunchedAtLogin(
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> Bool {
        guard let event,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
