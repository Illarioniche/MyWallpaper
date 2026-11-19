import AppKit
import CoreGraphics

/// A conservative, metadata-only approximation of a covering application window.
/// Window alpha is a global fade value, not a guarantee of per-pixel opacity.
struct DesktopCoveringWindow {
    let bounds: CGRect

    init?(info: [String: Any]) {
        guard let layer = info[kCGWindowLayer as String] as? NSNumber,
              CFGetTypeID(layer) != CFBooleanGetTypeID(),
              (layer.doubleValue == 0
                || layer.doubleValue == Double(NSWindow.Level.floating.rawValue)),
              let alpha = info[kCGWindowAlpha as String] as? NSNumber,
              CFGetTypeID(alpha) != CFBooleanGetTypeID(),
              alpha.doubleValue.isFinite,
              (0.99...1).contains(alpha.doubleValue),
              let isOnscreen = info[kCGWindowIsOnscreen as String] as? NSNumber,
              CFGetTypeID(isOnscreen) == CFBooleanGetTypeID(),
              isOnscreen.boolValue,
              let dictionary = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              isValidCoverageRect(bounds) else { return nil }

        // Normal and floating application windows can cover the desktop.
        // Exclude other levels so menus, the Dock, and desktop elements do not
        // become coverage merely because their bounds span a large rectangle.
        self.bounds = bounds
    }
}

struct DesktopCoverageGeometry {
    /// AppKit and Quartz share logical points but have opposite vertical axes.
    /// The reference is the primary display, including for displays above it.
    static func quartzRect(from rect: CGRect, desktopTop: CGFloat) -> CGRect {
        guard isValidCoverageRect(rect), desktopTop.isFinite else { return .null }
        let converted = CGRect(
            x: rect.origin.x,
            y: desktopTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        return isValidCoverageRect(converted) ? converted : .null
    }

    /// Subtracts each covering rectangle from the remaining exposed regions.
    /// Overlaps are counted once, and even a narrow uncovered gap stays exposed.
    static func isCovered(_ target: CGRect, by covers: [CGRect]) -> Bool {
        guard isValidCoverageRect(target) else { return false }
        var remaining = [target]
        for cover in covers where isValidCoverageRect(cover) {
            var next: [CGRect] = []
            for exposed in remaining {
                let overlap = exposed.intersection(cover)
                guard isValidCoverageRect(overlap) else {
                    next.append(exposed)
                    continue
                }

                // Left and right strips use the full height. The other two
                // strips use only the overlap's width, so pieces never overlap.
                if overlap.minX > exposed.minX {
                    next.append(CGRect(
                        x: exposed.minX, y: exposed.minY,
                        width: overlap.minX - exposed.minX, height: exposed.height
                    ))
                }
                if overlap.maxX < exposed.maxX {
                    next.append(CGRect(
                        x: overlap.maxX, y: exposed.minY,
                        width: exposed.maxX - overlap.maxX, height: exposed.height
                    ))
                }
                if overlap.minY > exposed.minY {
                    next.append(CGRect(
                        x: overlap.minX, y: exposed.minY,
                        width: overlap.width, height: overlap.minY - exposed.minY
                    ))
                }
                if overlap.maxY < exposed.maxY {
                    next.append(CGRect(
                        x: overlap.minX, y: overlap.maxY,
                        width: overlap.width, height: exposed.maxY - overlap.maxY
                    ))
                }
            }
            remaining = next
            if remaining.isEmpty { return true }
        }
        return false
    }
}

private func isValidCoverageRect(_ rect: CGRect) -> Bool {
    !rect.isNull && !rect.isInfinite
        && rect.origin.x.isFinite && rect.origin.y.isFinite
        && rect.size.width.isFinite && rect.size.height.isFinite
        && rect.size.width > 0 && rect.size.height > 0
        && rect.maxX.isFinite && rect.maxY.isFinite
}

/// Supplements AppKit occlusion for native translucent/rounded application
/// windows. Only four geometry/visibility keys are read; no capture or AX access.
@MainActor
final class DesktopCoverageMonitor {
    typealias WindowInfoProvider = @MainActor () -> [[String: Any]]?

    var onChange: (@MainActor ([Bool]) -> Void)?

    private let windowInfoProvider: WindowInfoProvider
    private var trackingFrames: [CGRect] = []
    private var lastCoverage: [Bool]?
    private var resources: DesktopCoverageObservationResources?

    init(windowInfoProvider: @escaping WindowInfoProvider = DesktopCoverageMonitor.readWindowInfo) {
        self.windowInfoProvider = windowInfoProvider
    }

    deinit {
        // Explicit stop invalidates synchronously. This fallback also handles
        // an owner released off the main actor without leaving a live timer.
        if let resources {
            DispatchQueue.main.async { resources.invalidate() }
        }
    }

    func update(trackingFrames: [CGRect], enabled: Bool) {
        if self.trackingFrames != trackingFrames {
            self.trackingFrames = trackingFrames
            // A changed configuration may refer to newly created surfaces.
            lastCoverage = nil
        }
        guard enabled, !trackingFrames.isEmpty else {
            cancelObservations()
            publish(Array(repeating: false, count: trackingFrames.count))
            return
        }
        if resources == nil { startObservations() }
        refresh()
    }

    /// Does not notify surfaces that are about to be disposed. A subsequent
    /// update publishes a fresh initial result even if the values are unchanged.
    func stop() {
        cancelObservations()
        trackingFrames = []
        lastCoverage = nil
    }

    private func startObservations() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        let observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        resources = DesktopCoverageObservationResources(
            timer: timer, center: center, observers: observers
        )
    }

    private func cancelObservations() {
        resources?.invalidate()
        resources = nil
    }

    private func refresh() {
        // Callbacks already queued when stop/disable ran must have no effect.
        guard resources != nil else { return }
        guard let desktopTop = NSScreen.screens.first?.frame.maxY,
              let windowInfo = windowInfoProvider(), !windowInfo.isEmpty else {
            publish(Array(repeating: false, count: trackingFrames.count))
            return
        }
        // A single system snapshot serves every display in this refresh.
        let covers = windowInfo.compactMap { DesktopCoveringWindow(info: $0)?.bounds }
        let coverage = trackingFrames.map {
            DesktopCoverageGeometry.isCovered(
                DesktopCoverageGeometry.quartzRect(from: $0, desktopTop: desktopTop),
                by: covers
            )
        }
        publish(coverage)
    }

    private func publish(_ coverage: [Bool]) {
        guard coverage != lastCoverage else { return }
        lastCoverage = coverage
        onChange?(coverage)
    }

    private static func readWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
    }
}

/// Immutable handles may cross to the main queue only for cleanup. Installation,
/// use, and invalidation of the timer and observation tokens stay on that queue.
private struct DesktopCoverageObservationResources: @unchecked Sendable {
    let timer: Timer
    let center: NotificationCenter
    let observers: [NSObjectProtocol]

    @MainActor
    func invalidate() {
        timer.invalidate()
        observers.forEach { center.removeObserver($0) }
    }
}
