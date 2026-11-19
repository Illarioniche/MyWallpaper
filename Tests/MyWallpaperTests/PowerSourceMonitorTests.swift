import Combine
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct PowerSourceMonitorTests {
    @Test
    func testSystemProviderTypesDistinguishUnlimitedAndLimitedPower() {
        #expect(PowerSource(providerType: "AC Power") == .external)
        #expect(PowerSource(providerType: "Battery Power") == .battery)
        #expect(PowerSource(providerType: "UPS Power") == .battery)
    }

    @Test
    func testMissingAndUnrecognizedProviderTypesRemainUnknown() {
        #expect(PowerSource(providerType: nil) == .unknown)
        #expect(PowerSource(providerType: "") == .unknown)
        #expect(PowerSource(providerType: "Future Power Source") == .unknown)
    }

    @Test
    func testSubscriberImmediatelyReceivesCurrentSourceAndOnlySourceChanges() {
        let system = SimulatedPowerSource()
        let monitor = PowerSourceMonitor(readSource: { system.source }, observeChanges: system.install)
        var received: [PowerSource] = []
        let subscription = monitor.sourcePublisher.sink { received.append($0) }

        #expect(received == [.external], "The startup value must not wait for a hardware event.")
        system.notify()
        #expect(received == [.external], "Battery percentage events must not retrigger playback.")

        system.source = .battery
        system.notify()
        #expect(monitor.source == .battery)
        #expect(received == [.external, .battery])

        system.source = .unknown
        system.notify()
        system.source = .external
        system.notify()
        #expect(received == [.external, .battery, .unknown, .external])
        withExtendedLifetime(subscription) {}
    }

    @Test
    func testRegistrationRaceUsesTheLatestSnapshot() {
        let system = SimulatedPowerSource()
        let monitor = PowerSourceMonitor(readSource: { system.source }, observeChanges: { callback in
            system.source = .battery
            return system.install(callback)
        })
        var received: [PowerSource] = []
        let subscription = monitor.sourcePublisher.sink { received.append($0) }

        #expect(monitor.source == .battery)
        #expect(received == [.battery], "A change during registration must not leave a stale AC state.")
        withExtendedLifetime(subscription) {}
    }

    @Test
    func testUnavailableNotificationsStillProvideAnInitialSnapshot() {
        let monitor = PowerSourceMonitor(readSource: { .battery }, observeChanges: { _ in nil })
        var received: [PowerSource] = []
        let subscription = monitor.sourcePublisher.sink { received.append($0) }
        #expect(received == [.battery])
        withExtendedLifetime(subscription) {}
    }

    @Test
    func testMonitorReleasesObservationAndQueuedCallbackDoesNotRetainIt() {
        let system = SimulatedPowerSource()
        var monitor: PowerSourceMonitor? = PowerSourceMonitor(
            readSource: { system.source }, observeChanges: system.install)
        weak var weakMonitor = monitor
        let queuedCallback = system.callback
        #expect(system.registrationCount == 1)

        monitor = nil
        #expect(weakMonitor == nil)
        #expect(system.cancellationCount == 1)
        #expect(system.callback == nil)
        queuedCallback?()
        #expect(weakMonitor == nil, "An already queued hardware callback must not retain the owner.")
    }
}

@MainActor
private final class SimulatedPowerSource {
    var source: PowerSource = .external
    var callback: (@MainActor @Sendable () -> Void)?
    private(set) var registrationCount = 0
    private(set) var cancellationCount = 0

    func install(_ callback: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
        self.callback = callback
        registrationCount += 1
        return AnyCancellable { [weak self] in
            // These deterministic tests create and release the monitor on MainActor.
            MainActor.assumeIsolated {
                self?.cancellationCount += 1
                self?.callback = nil
            }
        }
    }

    func notify() { callback?() }
}
