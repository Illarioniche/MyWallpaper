import AppKit
import Combine
import CoreServices
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

/// Keeps registration operations replaceable in tests without changing real login items.
@MainActor
protocol LoginItemServicing: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private final class SystemLoginItemService: LoginItemServicing {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var errorMessage: String?

    private let service: any LoginItemServicing
    private var activationObserver: AnyCancellable?

    init(service: (any LoginItemServicing)? = nil,
         notificationCenter: NotificationCenter = .default) {
        let resolvedService = service ?? SystemLoginItemService()
        self.service = resolvedService
        status = resolvedService.status
        activationObserver = notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    /// Read the system again after returning from Settings or opening the controls.
    func refresh() {
        let currentStatus = service.status
        if currentStatus != status { errorMessage = nil }
        status = currentStatus
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil

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
        } catch {
            // An operation can fail after the system state has changed. Never infer
            // the checkbox state from the requested value or from a cached preference.
            status = service.status
            let action = enabled ? "включить" : "выключить"
            errorMessage = "Не удалось \(action) автозапуск. \(error.localizedDescription)"
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
