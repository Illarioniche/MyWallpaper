import Foundation
import Testing
@testable import MyWallpaper

@Suite
struct AppDiagnosticsTests {
    @Test
    func reportDescribesTheActualPlaybackAndPowerContextInEnglish() {
        var snapshot = AppDiagnosticSnapshot()
        snapshot.appVersion = "0.10.0"
        snapshot.appBuild = "12"
        snapshot.systemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        snapshot.architecture = .arm64
        snapshot.language = .russian
        snapshot.playback = .paused
        snapshot.pauseCause = .batteryRule
        snapshot.powerSource = .battery
        snapshot.connectedDisplayCount = 2
        snapshot.wallpaperDisplayCount = 2
        snapshot.occludedDisplayCount = 1
        snapshot.effectivePowerRules = WallpaperPowerRules(animateOnExternalPower: true, animateOnBattery: false,
            pauseInLowPowerMode: false, pauseWhenCovered: true)
        snapshot.usesGlobalPowerRules = false
        snapshot.wallpaperCount = 4
        snapshot.screenSaverCount = 2
        snapshot.loginStatus = .requiresApproval
        snapshot.loginAvailability = .available

        let report = snapshot.formattedText()
        #expect(report.contains("App version: 0.10.0\nApp build: 12"))
        #expect(report.contains("macOS: 26.1.0\nProcess architecture: arm64\nApp language: ru"))
        #expect(report.contains("Playback: paused\nPause reason: battery-rule"))
        #expect(report.contains("Power source: battery"))
        #expect(report.contains("Power rules: individual"))
        #expect(report.contains("Pause in Low Power Mode: no"))
        #expect(report.contains("Covered wallpaper displays: 1"))
        #expect(report.contains("Saved wallpapers: 4\nSaved screen savers: 2"))
        #expect(report.contains("Launch at login: requires-approval"))
        #expect(!report.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
    }

    @Test
    func rawErrorDetailsAndReleaseMetadataCannotEnterTheReport() {
        let privateText = "Cannot read /Users/Alice/Movies/Private Holiday.mp4?token=secret"
        let release = UpdateRelease(version: "0.11.0", title: privateText, notes: privateText,
            pageURL: URL(string: "https://example.com/private?token=secret")!, downloadURL: nil, checksumURL: nil)
        var snapshot = AppDiagnosticSnapshot()
        snapshot.updateCheck = .init(.available(release))
        snapshot.updateInstallation = .init(.failed(UpdateInstallFailure(message: privateText, detail: privateText)))
        snapshot.failures = [.updateInstallation]
        var report = snapshot.formattedText()
        #expect(report.contains("Update check: available"))
        #expect(report.contains("Update installation: failed"))
        #expect(report.contains("Reported errors: update-installation"))
        #expect(!report.contains(privateText))
        #expect(!report.contains("Alice"))
        #expect(!report.contains("secret"))
        #expect(!report.contains("example.com"))

        snapshot.updateCheck = .init(.failed(privateText))
        snapshot.failures.insert(.updateCheck)
        report = snapshot.formattedText()
        #expect(report.contains("Update check: failed"))
        #expect(!report.contains("Alice"))
        #expect(!report.contains("secret"))
    }

    @Test
    func malformedBundleVersionsCannotInjectPrivateDataOrExtraLines() {
        for value in ["/Users/Alice/MyWallpaper.app", "0.10.0\nSecret: token", "", "v0.10.0", String(repeating: "1", count: 100)] {
            var snapshot = AppDiagnosticSnapshot()
            snapshot.appVersion = value
            snapshot.appBuild = value
            let report = snapshot.formattedText()
            #expect(report.contains("App version: unknown\nApp build: unknown"))
            #expect(!report.contains("Alice"))
            #expect(!report.contains("Secret:"))
        }
    }

    @Test
    func errorOrderingAndDatesRemainStableAcrossMachines() {
        var first = AppDiagnosticSnapshot()
        first.lastUpdateCheck = Date(timeIntervalSince1970: 0)
        first.failures = [.screenSaverSync, .login, .wallpaperLibrary]
        var second = first
        second.failures = [.wallpaperLibrary, .login, .screenSaverSync]
        #expect(first.formattedText() == second.formattedText())
        #expect(first.formattedText().contains("Last successful update check (UTC): 1970-01-01T00:00:00Z"))
        #expect(first.formattedText().contains("Reported errors: login, screen-saver-sync, wallpaper-library"))
    }

    @Test
    func anEmptySnapshotDoesNotInventSuccessfulSetupOrReadPersonalState() {
        let report = AppDiagnosticSnapshot().formattedText()
        #expect(report.contains("App version: unknown"))
        #expect(report.contains("macOS: unknown"))
        #expect(report.contains("Playback: empty\nPause reason: none"))
        #expect(report.contains("Launch at login: unavailable"))
        #expect(report.contains("Last successful update check (UTC): never"))
        #expect(report.contains("Reported errors: none"))
        #expect(!report.contains(NSHomeDirectory()))
    }
}
