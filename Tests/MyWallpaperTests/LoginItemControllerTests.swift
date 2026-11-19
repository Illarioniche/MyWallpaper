import AppKit
import CoreServices
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct LoginItemControllerTests {
    @Test(arguments: [LoginItemStatus.disabled, .enabled, .requiresApproval, .unavailable])
    func initializationReadsSystemStatusWithoutRegistration(_ status: LoginItemStatus) {
        let service = FakeLoginItemService(status: status)
        let controller = LoginItemController(service: service)

        #expect(controller.status == status)
        #expect(controller.errorMessage == nil)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
    }

    @Test
    func enableAndDisableFollowServiceState() {
        let service = FakeLoginItemService(status: .disabled)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        #expect(controller.status == .enabled)
        #expect(controller.errorMessage == nil)
        #expect(service.registerCalls == 1)

        controller.setEnabled(false)
        #expect(controller.status == .disabled)
        #expect(controller.errorMessage == nil)
        #expect(service.unregisterCalls == 1)
    }

    @Test
    func registrationRequiringApprovalDoesNotPretendToBeEnabled() {
        let service = FakeLoginItemService(status: .disabled)
        service.statusAfterRegister = .requiresApproval
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        #expect(controller.status == .requiresApproval)
        #expect(controller.errorMessage == nil)

        controller.setEnabled(true)
        #expect(service.registerCalls == 1, "A second request cannot bypass approval in Settings.")
        #expect(service.openSettingsCalls == 0, "Settings opens only through the explicit action.")

        controller.openSystemSettings()
        #expect(service.openSettingsCalls == 1)
        #expect(controller.status == .requiresApproval)
    }

    @Test
    func pendingRegistrationCanBeRemoved() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        #expect(service.unregisterCalls == 1)
        #expect(controller.status == .disabled)
    }

    @Test
    func failedRegistrationReadsActualStateAndReportsError() {
        let service = FakeLoginItemService(status: .disabled)
        service.registerError = TestFailure.denied
        service.statusAfterRegistrationFailure = .requiresApproval
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        #expect(controller.status == .requiresApproval, "The service can change state even when registration throws.")
        #expect(controller.errorMessage?.contains("Не удалось включить автозапуск") == true)
    }

    @Test
    func failedUnregistrationKeepsTheTrueEnabledState() {
        let service = FakeLoginItemService(status: .enabled)
        service.unregisterError = TestFailure.denied
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        #expect(controller.status == .enabled)
        #expect(controller.errorMessage?.contains("Не удалось выключить автозапуск") == true)

        service.unregisterError = nil
        controller.setEnabled(false)
        #expect(controller.status == .disabled)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func refreshReflectsExternalRevokeAndApproval() {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        service.status = .requiresApproval
        controller.refresh()
        #expect(controller.status == .requiresApproval)

        service.status = .enabled
        controller.refresh()
        #expect(controller.status == .enabled)

        service.status = .disabled
        controller.refresh()
        #expect(controller.status == .disabled)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
    }

    @Test
    func settingAnAlreadySatisfiedValueDoesNotReregister() {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)

        service.status = .disabled
        controller.setEnabled(false)

        #expect(controller.status == .disabled)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
    }

    @Test
    func modelClearsForwardedErrorAfterSuccessfulRetryAndExternalChange() throws {
        let service = FakeLoginItemService(status: .disabled)
        service.registerError = TestFailure.denied
        try withIsolatedModel(service: service) { model, _ in
            model.setLaunchAtLogin(true)
            #expect(model.errorMessage?.contains("Не удалось включить автозапуск") == true)

            service.registerError = nil
            model.setLaunchAtLogin(true)
            #expect(model.loginItems.status == .enabled)
            #expect(model.errorMessage == nil)

            service.unregisterError = TestFailure.denied
            model.setLaunchAtLogin(false)
            #expect(model.errorMessage?.contains("Не удалось выключить автозапуск") == true)

            service.status = .disabled
            model.loginItems.refresh()
            #expect(model.errorMessage == nil, "Resolving registration in Settings must clear its old error banner.")
        }
    }

    @Test
    func resolvingLoginErrorPreservesAnUnrelatedPlaybackError() throws {
        let service = FakeLoginItemService(status: .disabled)
        service.registerError = TestFailure.denied
        try withIsolatedModel(service: service) { model, _ in
            model.setLaunchAtLogin(true)
            #expect(model.errorMessage != nil)

            let playbackError = "Не удалось воспроизвести тестовый файл."
            model.engine.onPlaybackError?(playbackError)
            service.status = .enabled
            model.loginItems.refresh()

            #expect(model.loginItems.errorMessage == nil)
            #expect(model.errorMessage == playbackError)

            model.setLaunchAtLogin(true)
            #expect(model.errorMessage == playbackError, "A login preference action must not dismiss an unrelated video error.")
        }
    }

    @Test(arguments: [LoginItemStatus.enabled, .requiresApproval, .disabled])
    func enablingLoginRestoresWallpaperOnlyWhenRegistrationExists(_ result: LoginItemStatus) throws {
        let service = FakeLoginItemService(status: .disabled)
        service.statusAfterRegister = result
        if result == .disabled { service.registerError = TestFailure.denied }
        try withIsolatedModel(service: service) { model, preferences in
            #expect(!model.restoreOnLaunch)

            model.setLaunchAtLogin(true)

            #expect(model.loginItems.status == result)
            let shouldRestore = result == .enabled || result == .requiresApproval
            #expect(model.restoreOnLaunch == shouldRestore)
            #expect(preferences.restoreOnLaunch == shouldRestore)
        }
    }

    @Test
    func loginLaunchIsRecognizedFromTheOpenApplicationProperty() {
        let event = launchEvent()
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)

        #expect(LoginItemController.wasLaunchedAtLogin(event: event))
    }

    @Test
    func normalAndServiceLaunchesAreNotLoginLaunches() {
        #expect(!LoginItemController.wasLaunchedAtLogin(event: nil))
        #expect(!LoginItemController.wasLaunchedAtLogin(event: launchEvent()))

        let serviceEvent = launchEvent()
        serviceEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        #expect(!LoginItemController.wasLaunchedAtLogin(event: serviceEvent))

        let reopenEvent = launchEvent(id: kAEReopenApplication)
        reopenEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        #expect(!LoginItemController.wasLaunchedAtLogin(event: reopenEvent))
    }

    private func launchEvent(id: AEEventID = kAEOpenApplication) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id,
                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
    }

    private func withIsolatedModel(
        service: FakeLoginItemService,
        _ body: (WallpaperModel, WallpaperPreferences) throws -> Void
    ) throws {
        let domain = "LoginItemModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.restoreOnLaunch = false
        let loginItems = LoginItemController(service: service, notificationCenter: NotificationCenter())
        let model = WallpaperModel(preferences: preferences, loginItems: loginItems)
        defer { model.shutDown() }
        try body(model, preferences)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status: LoginItemStatus
    var statusAfterRegister: LoginItemStatus = .enabled
    var statusAfterRegistrationFailure: LoginItemStatus?
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0

    init(status: LoginItemStatus) { self.status = status }

    func register() throws {
        registerCalls += 1
        if let registerError {
            if let statusAfterRegistrationFailure { status = statusAfterRegistrationFailure }
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = .disabled
    }

    func openSystemSettings() { openSettingsCalls += 1 }
}

private enum TestFailure: Error {
    case denied
}
