import Foundation

/// A one-use receipt for an updater restart. Ordinary launch preferences stay untouched.
struct UpdatePlaybackSnapshot: Codable, Equatable, Sendable {
    let wallpaperWasActive: Bool
    let userPaused: Bool
    let temporarilyAnimating: Bool
    let powerSource: String
    let windowWasVisible: Bool
}

@MainActor
final class UpdateRelaunchState {
    private struct Receipt: Codable {
        let sourceVersion: String
        let sourceBuild: String
        let targetVersion: String
        let targetBuild: String
        let createdAt: Date
        var playback: UpdatePlaybackSnapshot?
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let key = "updates.pendingRelaunch"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func prepare(sourceVersion: String, sourceBuild: String, targetVersion: String, targetBuild: String) {
        save(Receipt(sourceVersion: sourceVersion, sourceBuild: sourceBuild,
                     targetVersion: targetVersion, targetBuild: targetBuild, createdAt: now()))
    }

    /// Called at actual termination, after pending saves and imports have completed.
    func finalize(_ snapshot: UpdatePlaybackSnapshot) {
        guard var receipt = read() else { return }
        receipt.playback = snapshot
        save(receipt)
        // The installer replaces the process immediately after applicationWillTerminate.
        defaults.synchronize()
    }

    func cancel() { defaults.removeObject(forKey: key) }

    func consume(currentVersion: String, currentBuild: String) -> UpdatePlaybackSnapshot? {
        defer { cancel() }
        guard let receipt = read(), let snapshot = receipt.playback,
              let sourceVersion = UpdateVersion(receipt.sourceVersion),
              let targetVersion = UpdateVersion(receipt.targetVersion), targetVersion > sourceVersion,
              let sourceBuild = UInt64(receipt.sourceBuild), let targetBuild = UInt64(receipt.targetBuild),
              targetBuild > sourceBuild,
              receipt.targetVersion == currentVersion, receipt.targetBuild == currentBuild else { return nil }
        let age = now().timeIntervalSince(receipt.createdAt)
        guard age >= 0, age < 7 * 24 * 60 * 60 else { return nil }
        return snapshot
    }

    private func read() -> Receipt? {
        guard let data = defaults.data(forKey: key), data.count < 8_192 else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    private func save(_ receipt: Receipt) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(data, forKey: key)
    }
}
