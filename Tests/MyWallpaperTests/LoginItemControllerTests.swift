import AppKit
import Combine
import CoreServices
import ServiceManagement
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct LoginItemControllerTests {
    @Test
    func changingLanguageRepublishesAnExistingFailureWithoutRepeatingRegistration() throws {
        let service = FakeLoginItemService(status: .disabled)
        service.registerError = LocalizationLoginFailure()
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        let russian = try #require(controller.errorMessage)
        var published: [String?] = []
        let subscription = controller.$errorMessage.sink { published.append($0) }
        defer { subscription.cancel() }

        let english = AppLocalizer(language: .english)
        controller.localizer = english

        let expected = english.format("Не удалось включить автозапуск. %@", "Permission 50% denied")
        #expect(controller.errorMessage == expected)
        #expect(controller.errorMessage != russian)
        #expect(published.last == expected)
        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 0)
        #expect(service.openSettingsCalls == 0)
        #expect(controller.status == .disabled)
        controller.localizer = .russian
        #expect(controller.errorMessage == russian)
    }

    @Test
    func locationExplanationAndStatusChangeLanguageWithoutServiceActions() {
        let service = FakeLoginItemService(status: .notFound)
        service.availability = .readOnlyVolume
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        let russian = controller.statusDetail
        controller.localizer = AppLocalizer(language: .english)
        #expect(controller.statusDetail != russian)
        #expect(controller.errorMessage == controller.statusDetail)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
        #expect(service.openSettingsCalls == 0)

        service.availability = .available
        controller.refresh()
        controller.localizer = .russian
        #expect(controller.errorMessage == nil, "A language change must not revive a cleared error.")
    }

    @Test(arguments: [LoginItemStatus.disabled, .enabled, .requiresApproval, .notFound, .unavailable])
    func initializationReadsSystemStatusWithoutRegistration(_ status: LoginItemStatus) {
        let service = FakeLoginItemService(status: status)
        let controller = LoginItemController(service: service)

        #expect(controller.status == status)
        #expect(controller.errorMessage == nil)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
    }

    @Test
    func aMissingServiceIsDistinctFromAnUnavailableApplication() {
        #expect(LoginItemStatus(serviceStatus: .notFound) == .notFound)
        #expect(LoginItemStatus(serviceStatus: .notRegistered) == .disabled)
        #expect(LoginItemStatus(serviceStatus: .requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(serviceStatus: .enabled) == .enabled)

        let service = FakeLoginItemService(status: .notFound)
        let controller = LoginItemController(service: service)
        #expect(controller.availability == .available)
        #expect(controller.canToggle)
        #expect(!controller.statusDetail.contains("из собранного приложения"))
        #expect(service.registerCalls == 0)

        controller.setEnabled(true)
        #expect(service.registerCalls == 1)
        #expect(controller.status == .enabled)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func aMissingServiceCanBeRetriedAfterFailure() {
        let service = FakeLoginItemService(status: .notFound)
        service.registerError = TestFailure.denied
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        #expect(controller.status == .notFound)
        #expect(controller.canToggle)
        #expect(controller.errorMessage?.contains("Не удалось включить автозапуск") == true)

        controller.openSystemSettings()
        #expect(service.openSettingsCalls == 1)
        #expect(service.registerCalls == 1, "Opening Settings must not silently retry registration.")

        service.registerError = nil
        controller.setEnabled(true)
        #expect(service.registerCalls == 2)
        #expect(controller.status == .enabled)
        #expect(controller.errorMessage == nil)
    }

    @Test(arguments: [LoginItemStatus.notFound, .disabled])
    func aRegistrationWithoutConfirmationKeepsRetryAvailable(_ result: LoginItemStatus) {
        let service = FakeLoginItemService(status: .notFound)
        service.statusAfterRegister = result
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        #expect(controller.status == result)
        #expect(controller.canToggle)
        #expect(controller.errorMessage?.contains("пока не подтвердила") == true)
    }

    @Test
    func anUnknownStatusExplainsTheProblemWithoutClaimingTheAppIsUnbundled() {
        let service = FakeLoginItemService(status: .unavailable)
        let controller = LoginItemController(service: service)

        #expect(!controller.canToggle)
        #expect(controller.statusDetail.contains("состояние автозапуска"))
        controller.setEnabled(true)
        #expect(service.registerCalls == 0)
        #expect(controller.errorMessage != nil)
        controller.openSystemSettings()
        #expect(service.openSettingsCalls == 1)
    }

    @Test(arguments: [LoginItemAvailability.notAppBundle, .readOnlyVolume, .translocated])
    func unsuitableLocationsDoNotAttemptRegistration(_ availability: LoginItemAvailability) {
        let service = FakeLoginItemService(status: .notFound)
        service.availability = availability
        let controller = LoginItemController(service: service)

        #expect(controller.availability == availability)
        #expect(!controller.canToggle)
        controller.setEnabled(true)
        controller.setEnabled(false)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
        #expect(controller.errorMessage == controller.statusDetail)
        if availability != .notAppBundle {
            #expect(controller.statusDetail.contains("«Программы»"))
            #expect(controller.statusDetail.contains("заверши"))
        }

        controller.openSystemSettings()
        #expect(service.openSettingsCalls == 1)
    }

    @Test
    func refreshingAvailabilityDoesNotRegisterAndClearsItsObsoleteError() {
        let service = FakeLoginItemService(status: .notFound)
        service.availability = .readOnlyVolume
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        #expect(controller.errorMessage != nil)

        service.availability = .available
        controller.refresh()
        #expect(controller.canToggle)
        #expect(controller.errorMessage == nil)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
    }

    @Test(arguments: ["/Applications/MyWallpaper.app",
                      "/Users/test/Applications/MyWallpaper.app",
                      "/Volumes/External/Apps/MyWallpaper.app",
                      "/Users/test/Projects/MyWallpaper/dist/MyWallpaper.app"])
    func ordinaryAppBundlesAreEligibleWithoutRequiringOneInstallDirectory(_ path: String) {
        #expect(availability(of: path, readOnly: false) == .available)
        #expect(availability(of: path, readOnly: nil) == .available,
                "A missing read-only flag must not be misrepresented as a disk-image launch.")
    }

    @Test
    func diskImagesAndTranslocationHaveDistinctRecoveryExplanations() {
        #expect(availability(of: "/Volumes/MyWallpaper 0.4.0/MyWallpaper.app", readOnly: true) == .readOnlyVolume)
        let translocated = "/private/var/folders/test/T/AppTranslocation/91B5BE76-19F2-4D74-985C-CE89E03F236F/d/MyWallpaper.app"
        #expect(availability(of: translocated, readOnly: true) == .translocated)
        #expect(availability(of: translocated, readOnly: false) == .available,
                "A path name alone is not enough to block a legitimate writable app.")
        #expect(availability(of: "/Volumes/AppTranslocation/MyWallpaper.app", readOnly: true) == .readOnlyVolume)
    }

    @Test
    func executableAndBundleMetadataMustDescribeAnActualApplication() {
        let app = URL(fileURLWithPath: "/Applications/MyWallpaper.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/MyWallpaper")
        for packageType in [nil, "BNDL", "XPC!"] {
            #expect(LoginItemAvailability.assess(bundleURL: app, executableURL: executable,
                                                bundleIdentifier: "local.mywallpaper.MyWallpaper",
                                                packageType: packageType, volumeIsReadOnly: false) == .notAppBundle)
        }
        for identifier in [nil, ""] {
            #expect(LoginItemAvailability.assess(bundleURL: app, executableURL: executable,
                                                bundleIdentifier: identifier,
                                                packageType: "APPL", volumeIsReadOnly: false) == .notAppBundle)
        }
        for executableURL in [nil, URL(fileURLWithPath: "/tmp/MyWallpaper"),
                              app.appendingPathComponent("Other/MyWallpaper")] {
            #expect(LoginItemAvailability.assess(bundleURL: app, executableURL: executableURL,
                                                bundleIdentifier: "local.mywallpaper.MyWallpaper",
                                                packageType: "APPL", volumeIsReadOnly: false) == .notAppBundle)
        }
        #expect(availability(of: "/tmp/MyWallpaper", readOnly: false) == .notAppBundle)
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
            model.engine.onPlaybackError?(playbackError, nil)
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

    private func availability(of path: String, readOnly: Bool?) -> LoginItemAvailability {
        let bundleURL = URL(fileURLWithPath: path, isDirectory: true)
        return LoginItemAvailability.assess(
            bundleURL: bundleURL,
            executableURL: bundleURL.appendingPathComponent("Contents/MacOS/MyWallpaper"),
            bundleIdentifier: "local.mywallpaper.MyWallpaper", packageType: "APPL",
            volumeIsReadOnly: readOnly
        )
    }

    private func withIsolatedModel(
        service: FakeLoginItemService,
        _ body: (WallpaperModel, WallpaperPreferences) throws -> Void
    ) throws {
        let domain = "LoginItemModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.language = .russian
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
    var availability: LoginItemAvailability = .available
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

private struct LocalizationLoginFailure: LocalizedError {
    var errorDescription: String? { "Permission 50% denied" }
}
