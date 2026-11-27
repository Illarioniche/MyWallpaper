import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct UpdateControllerTests {
    @Test
    func defaultLanguageIsEnglishForUpdateFailures() async throws {
        try await withDefaults { defaults in
            let transport = UpdateTestTransport([.response(response(Data(), status: 418))])
            let model = UpdateController(currentVersion: "0.4.0", defaults: defaults,
                                         transport: { request in try await transport.fetch(request) })

            await model.checkNow()

            #expect(model.localizer == .english)
            #expect(model.state == .failed(AppLocalizer.english.format(
                "GitHub не смог выполнить проверку обновлений (HTTP %@).", "418")))
            #expect(await transport.count == 1)
        }
    }

    @Test
    func changingLanguageRendersTheCurrentFailureWithoutNetworkOrChangingKnownRelease() async throws {
        try await withDefaults { defaults in
            let transport = UpdateTestTransport([.response(response(try releaseData())), .response(response(Data(), status: 418))])
            let model = controller(defaults, transport: transport)
            await model.checkNow()
            let release = try #require(model.availableRelease)
            let checked = model.lastChecked
            await model.checkNow()
            let russian = try #require(failureMessage(model.state))
            let english = AppLocalizer(language: .english)

            model.localizer = english

            let expected = english.format("GitHub не смог выполнить проверку обновлений (HTTP %@).", "418")
            #expect(model.state == .failed(expected))
            #expect(expected != russian)
            #expect(expected.contains("418"))
            #expect(await transport.count == 2)
            #expect(model.lastChecked == checked)
            #expect(model.availableRelease == release, "Release prose and trusted URLs must remain exactly as published.")
            model.localizer = .russian
            #expect(model.state == .failed(russian))
        }
    }

    @Test
    func stableVersionsUseNumericOrderingAndNormalizeLocalVersions() throws {
        #expect(try #require(UpdateVersion("v0.10.0")) > #require(UpdateVersion("0.9.9")))
        #expect(try #require(UpdateVersion("1.0.0")) > #require(UpdateVersion("0.99.99")))
        #expect(UpdateVersion("0.4") == UpdateVersion("0.4.0"))
        #expect(UpdateVersion("v2") == UpdateVersion("2.0.0"))
        for invalid in ["", "v", "0..4", "01.2.3", "0.4.0-beta", "0.4.0+build", "0.4.0.1",
                        " 0.4.0", "０.4.0", "-1.0.0", "18446744073709551616.0.0"] {
            #expect(UpdateVersion(invalid) == nil, "Must reject \(invalid)")
        }
    }

    @Test
    func newerReleaseExposesOnlyCanonicalDownloadsAndRecordsSuccess() async throws {
        try await withDefaults { defaults in
            let data = try releaseData()
            let clock = UpdateTestClock()
            let transport = UpdateTestTransport([.response(response(data))])
            let model = controller(defaults, clock: clock, transport: transport)
            #expect(model.state == .idle)
            #expect(model.lastChecked == nil)
            #expect(await transport.count == 0, "Initialization must never access the network.")

            await model.checkNow()

            let release = try #require(model.availableRelease)
            #expect(model.state == .available(release))
            #expect(release.version == "0.5.0")
            #expect(release.pageURL.absoluteString == "\(releaseRoot)/tag/v0.5.0")
            #expect(release.downloadURL?.lastPathComponent == "MyWallpaper-0.5.0-universal.dmg")
            #expect(release.checksumURL?.lastPathComponent == "MyWallpaper-0.5.0-universal.dmg.sha256")
            #expect(model.lastChecked == clock.date)
            #expect(!model.isChecking)
            let request = try #require(await transport.requests.first)
            #expect(request.url == GitHubUpdateTransport.endpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.timeoutInterval > 0 && request.timeoutInterval <= 20)
        }
    }

    @Test(arguments: ["0.5.0", "0.6.0", "0.10.0"])
    func currentOrNewerInstalledVersionIsUpToDate(_ installed: String) async throws {
        try await withDefaults { defaults in
            let model = controller(defaults, transport: UpdateTestTransport([.response(response(try releaseData()))]),
                                   version: installed)
            await model.checkNow()
            #expect(model.state == .upToDate)
            #expect(model.availableRelease == nil)
            #expect(model.lastChecked != nil)
        }
    }

    @Test
    func draftPrereleaseAndInvalidVersionsCannotBecomeUpdates() throws {
        for mutation: [String: Any] in [["draft": true], ["prerelease": true], ["tag_name": "v0.6.0-beta"],
                                        ["tag_name": "v0.6"], ["tag_name": "v01.6.0"]] {
            let data = try releaseData(overrides: mutation)
            #expect(throws: (any Error).self) { try UpdateReleaseParser.parse(data) }
        }
    }

    @Test
    func untrustedReleasePagesAndCanonicalAssetURLsAreRejected() throws {
        let page = "\(releaseRoot)/tag/v0.5.0"
        let download = "\(releaseRoot)/download/v0.5.0/MyWallpaper-0.5.0-universal.dmg"
        for address in [page.replacingOccurrences(of: "https:", with: "http:"),
                        page.replacingOccurrences(of: "github.com", with: "github.com.evil.example"),
                        page.replacingOccurrences(of: "Illarioniche", with: "AnotherOwner"),
                        page.replacingOccurrences(of: "MyWallpaper", with: "OtherRepository"),
                        page + "?redirect=evil", page + "#section", "https://evil.example/releases"] {
            #expect(throws: (any Error).self) { try UpdateReleaseParser.parse(releaseData(overrides: ["html_url": address])) }
        }
        for address in [download.replacingOccurrences(of: "v0.5.0", with: "v0.4.0"),
                        download.replacingOccurrences(of: "https:", with: "http:"),
                        download.replacingOccurrences(of: "github.com", with: "github.com@evil.example"),
                        download + "?download=1", download.replacingOccurrences(of: "MyWallpaper/", with: "Other/")] {
            let asset = assetInfo(name: "MyWallpaper-0.5.0-universal.dmg", url: address)
            #expect(throws: (any Error).self) { try UpdateReleaseParser.parse(releaseData(overrides: ["assets": [asset]])) }
        }
    }

    @Test
    func missingOrUnfinishedUniversalAssetStillAllowsSafeReleasePage() throws {
        let unrelated = assetInfo(name: "installer.pkg", url: "https://evil.example/installer.pkg")
        let unfinished = assetInfo(name: "MyWallpaper-0.5.0-universal.dmg", state: "starter")
        for assets in [[], [unrelated], [unfinished]] {
            let release = try UpdateReleaseParser.parse(releaseData(overrides: ["assets": assets]))
            #expect(release.downloadURL == nil)
            #expect(release.checksumURL == nil)
            #expect(release.pageURL.host == "github.com")
        }
        let duplicate = assetInfo(name: "MyWallpaper-0.5.0-universal.dmg")
        #expect(throws: (any Error).self) {
            try UpdateReleaseParser.parse(releaseData(overrides: ["assets": [duplicate, duplicate]]))
        }
    }

    @Test
    func malformedAndOversizedPayloadsFailAndDisplayTextIsBounded() throws {
        #expect(throws: (any Error).self) { try UpdateReleaseParser.parse(Data("not JSON".utf8)) }
        #expect(throws: (any Error).self) { try UpdateReleaseParser.parse(Data(repeating: 32, count: 1_048_577)) }
        let release = try UpdateReleaseParser.parse(releaseData(overrides: ["name": String(repeating: "a", count: 250),
                                                                         "body": String(repeating: "b", count: 25_000)]))
        #expect(release.title.count <= 200)
        #expect(release.notes.count <= 20_000)
    }

    @Test
    func serverAndNetworkFailuresHaveUsefulRussianMessages() async throws {
        let cases: [(UpdateTestReply, String)] = [
            (.response(response(Data(), status: 404)), "релизов"),
            (.response(response(Data(), status: 403)), "ограничил"),
            (.response(response(Data(), status: 429)), "ограничил"),
            (.response(response(Data(), status: 503)), "недоступен"),
            (.response(response(Data(), status: 302)), "перенаправления"),
            (.failure(.timedOut), "вовремя"),
            (.failure(.notConnectedToInternet), "интернету")
        ]
        for (reply, phrase) in cases {
            try await withDefaults { defaults in
                let model = controller(defaults, transport: UpdateTestTransport([reply]))
                await model.checkNow()
                #expect(failureMessage(model.state)?.contains(phrase) == true)
                #expect(model.lastChecked == nil)
                #expect(!model.isChecking)
            }
        }
    }

    @Test
    func unexpectedResponseOriginIsRejectedEvenWithValidReleaseJSON() async throws {
        try await withDefaults { defaults in
            let response = UpdateHTTPResponse(data: try releaseData(), statusCode: 200,
                                              finalURL: URL(string: "https://evil.example/latest")!)
            let model = controller(defaults, transport: UpdateTestTransport([.response(response)]))
            await model.checkNow()
            #expect(failureMessage(model.state)?.contains("непроверенный адрес") == true)
            #expect(model.availableRelease == nil)
        }
    }

    @Test
    func unknownInstalledVersionFailsWithoutNetwork() async throws {
        try await withDefaults { defaults in
            let transport = UpdateTestTransport([])
            let model = controller(defaults, transport: transport, version: "Неизвестна")
            await model.checkNow()
            #expect(failureMessage(model.state)?.contains("версию приложения") == true)
            #expect(await transport.count == 0)
        }
    }

    @Test
    func disabledAutomaticChecksPersistButManualChecksRemainAvailable() async throws {
        try await withDefaults { defaults in
            let transport = UpdateTestTransport([.response(response(try releaseData()))])
            let initial = controller(defaults, transport: transport)
            #expect(initial.automaticChecksEnabled)
            initial.automaticChecksEnabled = false
            let restored = controller(defaults, transport: transport)
            #expect(!restored.automaticChecksEnabled)
            await restored.checkAutomaticallyIfNeeded()
            #expect(await transport.count == 0)
            await restored.checkNow()
            #expect(await transport.count == 1)
            #expect(restored.availableRelease != nil)
        }
    }

    @Test
    func failedAutomaticAttemptIsThrottledAcrossRestartAndManualCheckBypassesCooldown() async throws {
        try await withDefaults { defaults in
            let clock = UpdateTestClock()
            let transport = UpdateTestTransport([.failure(.notConnectedToInternet), .response(response(try releaseData())),
                                                 .response(response(try releaseData()))])
            let initial = controller(defaults, clock: clock, transport: transport)
            await initial.checkAutomaticallyIfNeeded()
            #expect(initial.lastChecked == nil)
            clock.date += 86_399
            let restored = controller(defaults, clock: clock, transport: transport)
            await restored.checkAutomaticallyIfNeeded()
            #expect(await transport.count == 1)
            clock.date += 1
            await restored.checkAutomaticallyIfNeeded()
            #expect(await transport.count == 2)
            #expect(restored.lastChecked == clock.date)
            await restored.checkNow()
            #expect(await transport.count == 3)
        }
    }

    @Test
    func successfulReleaseSurvivesRestartAndOfflineRetry() async throws {
        try await withDefaults { defaults in
            let clock = UpdateTestClock()
            let transport = UpdateTestTransport([.response(response(try releaseData())), .failure(.notConnectedToInternet)])
            let initial = controller(defaults, clock: clock, transport: transport)
            await initial.checkNow()
            let known = try #require(initial.availableRelease)
            let successfulDate = try #require(initial.lastChecked)
            clock.date += 60
            let restored = controller(defaults, clock: clock, transport: transport)
            #expect(restored.state == .available(known))
            #expect(restored.availableRelease == known)
            #expect(restored.lastChecked == successfulDate)
            await restored.checkAutomaticallyIfNeeded()
            #expect(await transport.count == 1)
            await restored.checkNow()
            #expect(failureMessage(restored.state) != nil)
            #expect(restored.availableRelease == known)
            #expect(restored.lastChecked == successfulDate)
        }
    }

    @Test
    func installingTheCachedVersionClearsTheOldNotificationAndCache() async throws {
        try await withDefaults { defaults in
            let transport = UpdateTestTransport([.response(response(try releaseData()))])
            await controller(defaults, transport: transport).checkNow()
            let upgraded = controller(defaults, transport: transport, version: "0.5.0")
            #expect(upgraded.state == .upToDate)
            #expect(upgraded.availableRelease == nil)
            #expect(defaults.object(forKey: "updates.lastReleasePayload") == nil)
            #expect(await transport.count == 1)
        }
    }

    @Test
    func cachedPayloadIsRevalidatedAndInvalidCacheRemovedWithoutNetwork() async throws {
        let tampered = try releaseData(overrides: ["html_url": "https://evil.example/release"])
        let invalidValues: [Any] = [tampered, Data(repeating: 32, count: 1_048_577), Data("invalid cache".utf8), "wrong type"]
        for data in invalidValues {
            try await withDefaults { defaults in
                defaults.set(data, forKey: "updates.lastReleasePayload")
                let transport = UpdateTestTransport([])
                let model = controller(defaults, transport: transport)
                #expect(model.availableRelease == nil)
                #expect(model.state == .idle)
                #expect(defaults.object(forKey: "updates.lastReleasePayload") == nil)
                #expect(await transport.count == 0)
            }
        }
    }

    @Test
    func concurrentChecksAreCoalescedAndKnownReleaseRemainsDuringRetry() async throws {
        try await withDefaults { defaults in
            let data = try releaseData()
            await controller(defaults, transport: UpdateTestTransport([.response(response(data))])).checkNow()
            let gate = UpdateTestGate()
            let model = UpdateController(currentVersion: "0.4.0", defaults: defaults,
                                         transport: { request in try await gate.fetch(request) }, localizer: .russian)
            let task = Task { await model.checkNow() }
            for _ in 0..<200 where await gate.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
            let started = await gate.count == 1
            if started {
                #expect(model.isChecking)
                #expect(model.availableRelease?.version == "0.5.0")
                let known = model.availableRelease
                model.localizer = AppLocalizer(language: .english)
                #expect(model.isChecking, "Changing language must not interrupt an in-flight request.")
                #expect(model.availableRelease == known)
                await model.checkNow()
                await model.checkAutomaticallyIfNeeded()
                #expect(await gate.count == 1)
            } else {
                Issue.record("The injected request did not start.")
            }
            await gate.finish(response(data))
            await task.value
            #expect(!model.isChecking)
            #expect(model.availableRelease != nil)
        }
    }

    private func controller(_ defaults: UserDefaults, clock: UpdateTestClock = UpdateTestClock(),
                            transport: UpdateTestTransport, version: String = "0.4.0") -> UpdateController {
        UpdateController(currentVersion: version, defaults: defaults, now: { clock.date },
                         transport: { request in try await transport.fetch(request) }, localizer: .russian)
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let domain = "UpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try await body(defaults)
    }
}

private let releaseRoot = "https://github.com/Illarioniche/MyWallpaper/releases"

private func releaseData(overrides: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = [
        "tag_name": "v0.5.0", "name": "MyWallpaper 0.5.0", "body": "Исправления и улучшения.",
        "draft": false, "prerelease": false, "html_url": "\(releaseRoot)/tag/v0.5.0",
        "assets": [assetInfo(name: "MyWallpaper-0.5.0-universal.dmg"),
                   assetInfo(name: "MyWallpaper-0.5.0-universal.dmg.sha256")]
    ]
    value.merge(overrides) { _, new in new }
    return try JSONSerialization.data(withJSONObject: value)
}

private func assetInfo(name: String, url: String? = nil, state: String = "uploaded") -> [String: Any] {
    ["name": name, "state": state, "browser_download_url": url ?? "\(releaseRoot)/download/v0.5.0/\(name)"]
}

private func response(_ data: Data, status: Int = 200) -> UpdateHTTPResponse {
    UpdateHTTPResponse(data: data, statusCode: status, finalURL: GitHubUpdateTransport.endpoint)
}

private func failureMessage(_ state: UpdateState) -> String? {
    if case let .failed(message) = state { return message }
    return nil
}

@MainActor
private final class UpdateTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

private enum UpdateTestReply: Sendable {
    case response(UpdateHTTPResponse)
    case failure(URLError.Code)
}

private actor UpdateTestTransport {
    private var replies: [UpdateTestReply]
    private(set) var requests: [URLRequest] = []
    var count: Int { requests.count }
    init(_ replies: [UpdateTestReply]) { self.replies = replies }

    func fetch(_ request: URLRequest) throws -> UpdateHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else {
            Issue.record("Unexpected additional update request.")
            throw URLError(.unknown)
        }
        switch replies.removeFirst() {
        case let .response(value): return value
        case let .failure(code): throw URLError(code)
        }
    }
}

private actor UpdateTestGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<UpdateHTTPResponse, any Error>?
    private var finishedResponse: UpdateHTTPResponse?

    func fetch(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        count += 1
        if let finishedResponse { return finishedResponse }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ response: UpdateHTTPResponse) {
        finishedResponse = response
        continuation?.resume(returning: response)
        continuation = nil
    }
}
