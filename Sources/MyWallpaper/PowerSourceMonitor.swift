import Combine
import Foundation
import IOKit.ps

enum PowerSource: String, Equatable, Sendable {
    case external, battery, unknown

    init(providerType: String?) {
        switch providerType {
        case kIOPMACPowerKey:
            self = .external
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey:
            // IOPS reports the active supply, not merely an attached UPS.
            // A UPS supplying backup power is limited, like an internal battery.
            self = .battery
        default:
            self = .unknown
        }
    }
}

@MainActor
protocol PowerSourceMonitoring: AnyObject {
    var source: PowerSource { get }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { get }
}

/// Reads the current system supply and follows IOKit's power-source events.
/// The current-value publisher delivers a startup value to every subscriber.
@MainActor
final class PowerSourceMonitor: PowerSourceMonitoring {
    typealias Reader = @MainActor () -> PowerSource
    typealias NotificationInstaller = @MainActor (
        @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable?

    private let readSource: Reader
    private let subject: CurrentValueSubject<PowerSource, Never>
    private var observation: AnyCancellable?

    var source: PowerSource { subject.value }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { subject.eraseToAnyPublisher() }

    init(
        readSource: @escaping Reader = PowerSourceMonitor.readSystemSource,
        observeChanges: NotificationInstaller = PowerSourceMonitor.observeSystemChanges
    ) {
        self.readSource = readSource
        subject = CurrentValueSubject(readSource())
        observation = observeChanges { [weak self] in self?.refresh() }
        // Close the gap between the first snapshot and registering for changes.
        refresh()
    }

    private func refresh() {
        let newSource = readSource()
        // IOKit also sends charge percentage/time updates. They must not cause
        // repeated playback transitions while the active supply is unchanged.
        if subject.value != newSource { subject.send(newSource) }
    }

    private static func readSystemSource() -> PowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let provider = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return .unknown
        }
        // Unlike scanning battery entries, this also reports AC on desktop Macs
        // that have no internal battery at all.
        return PowerSource(providerType: provider as String)
    }

    private static func observeSystemChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable? {
        let context = PowerSourceCallbackContext(onChange: onChange)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let context = Unmanaged<PowerSourceCallbackContext>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in context.onChange() }
        }, pointer)?.takeRetainedValue() else { return nil }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let resources = PowerSourceRunLoopResources(source: source, context: context)
        return AnyCancellable {
            // Cancellation/deinit can happen off the main actor. Keep both the
            // CF source and its unretained C context alive until the main run
            // loop can remove them, so an in-flight callback never sees a freed
            // context. Queued callbacks capture the context and the owner weakly.
            DispatchQueue.main.async {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), resources.source, .commonModes)
                CFRunLoopSourceInvalidate(resources.source)
                withExtendedLifetime(resources.context) {}
            }
        }
    }
}

private final class PowerSourceCallbackContext: Sendable {
    let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }
}

/// Immutable ownership transferred to main-queue cleanup; the CF source itself
/// is only installed, invoked, and invalidated on the main run loop.
private struct PowerSourceRunLoopResources: @unchecked Sendable {
    let source: CFRunLoopSource
    let context: PowerSourceCallbackContext
}
