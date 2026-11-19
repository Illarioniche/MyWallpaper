import Combine
import Foundation

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let title: String
    /// Untrusted release prose for plain-text display, never a source of download links.
    let notes: String
    let pageURL: URL
    let downloadURL: URL?
    let checksumURL: URL?
}

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case failed(String)
}

struct UpdateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL
}

typealias UpdateTransport = @Sendable (URLRequest) async throws -> UpdateHTTPResponse

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var lastChecked: Date?
    @Published private var knownAvailableRelease: UpdateRelease?
    @Published var automaticChecksEnabled: Bool {
        didSet { defaults.set(automaticChecksEnabled, forKey: Keys.automaticChecks) }
    }
    @Published var localizer: AppLocalizer {
        didSet {
            if case .failed = state, let currentFailure {
                state = .failed(currentFailure.localized(using: localizer))
            }
        }
    }

    let currentVersion: String
    var availableRelease: UpdateRelease? { knownAvailableRelease }
    var isChecking: Bool { state == .checking }

    private let defaults: UserDefaults
    private let now: @MainActor @Sendable () -> Date
    private let transport: UpdateTransport
    private var lastAttempt: Date?
    private var currentFailure: UpdateFailure?
    private static let automaticInterval: TimeInterval = 24 * 60 * 60

    init(currentVersion: String? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping @MainActor @Sendable () -> Date = { Date() },
         transport: @escaping UpdateTransport = GitHubUpdateTransport.fetch,
         localizer: AppLocalizer = .russian) {
        self.defaults = defaults
        self.now = now
        self.transport = transport
        self.localizer = localizer
        let version = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.currentVersion = version?.isEmpty == false ? version! : "Неизвестна"
        automaticChecksEnabled = defaults.object(forKey: Keys.automaticChecks) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        lastAttempt = defaults.object(forKey: Keys.lastAttempt) as? Date
        restoreCachedRelease()
    }

    func startCheck() {
        Task { [weak self] in await self?.checkNow() }
    }

    func checkAutomaticallyIfNeeded() async {
        guard automaticChecksEnabled, !isChecking else { return }
        if let lastAttempt {
            let elapsed = now().timeIntervalSince(lastAttempt)
            // A clock moved backwards should not suppress checks indefinitely.
            if elapsed >= 0 && elapsed < Self.automaticInterval { return }
        }
        await checkNow()
    }

    func checkNow() async {
        guard !isChecking else { return }
        currentFailure = nil
        state = .checking
        lastAttempt = now()
        defaults.set(lastAttempt, forKey: Keys.lastAttempt)

        do {
            guard let installed = UpdateVersion(currentVersion) else {
                throw UpdateFailure(message: "Не удалось определить версию приложения. Запусти собранное MyWallpaper.app.")
            }
            try Task.checkCancellation()
            let response = try await transport(GitHubUpdateTransport.request())
            try Task.checkCancellation()
            guard response.finalURL.absoluteString == GitHubUpdateTransport.endpoint.absoluteString else {
                throw UpdateFailure(message: "Проверка остановлена: GitHub вернул непроверенный адрес.")
            }
            try validateStatus(response.statusCode)
            let release = try UpdateReleaseParser.parse(response.data)
            guard let latest = UpdateVersion(release.version) else {
                throw UpdateFailure(message: "В релизе указана некорректная версия.")
            }

            lastChecked = now()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            if latest > installed {
                defaults.set(response.data, forKey: Keys.lastReleasePayload)
                knownAvailableRelease = release
                state = .available(release)
            } else {
                defaults.removeObject(forKey: Keys.lastReleasePayload)
                knownAvailableRelease = nil
                state = .upToDate
            }
        } catch {
            // A temporary outage must not remove an already verified download from the UI.
            let failure = Self.failure(for: error)
            currentFailure = failure
            state = .failed(failure.localized(using: localizer))
        }
    }

    private func restoreCachedRelease() {
        guard defaults.object(forKey: Keys.lastReleasePayload) != nil else { return }
        guard let data = defaults.data(forKey: Keys.lastReleasePayload) else {
            defaults.removeObject(forKey: Keys.lastReleasePayload)
            return
        }
        do {
            let release = try UpdateReleaseParser.parse(data)
            guard let installed = UpdateVersion(currentVersion), let latest = UpdateVersion(release.version) else {
                defaults.removeObject(forKey: Keys.lastReleasePayload)
                return
            }
            if latest > installed {
                knownAvailableRelease = release
                state = .available(release)
            } else {
                defaults.removeObject(forKey: Keys.lastReleasePayload)
                state = .upToDate
            }
        } catch {
            defaults.removeObject(forKey: Keys.lastReleasePayload)
        }
    }

    private func validateStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 404:
            throw UpdateFailure(message: "Опубликованных релизов пока нет или репозиторий недоступен.")
        case 403, 429:
            throw UpdateFailure(message: "GitHub временно ограничил запросы. Попробуй проверить обновления позже.")
        case 300..<400:
            throw UpdateFailure(message: "Проверка остановлена: неожиданный адрес перенаправления GitHub.")
        case 500..<600:
            throw UpdateFailure(message: "GitHub временно недоступен. Попробуй позже.")
        default:
            throw UpdateFailure(message: "GitHub не смог выполнить проверку обновлений (HTTP %@).", argument: String(status))
        }
    }

    private static func failure(for error: Error) -> UpdateFailure {
        if let failure = error as? UpdateFailure { return failure }
        if error is CancellationError { return UpdateFailure(message: "Проверка обновлений отменена.") }
        if let network = error as? URLError {
            switch network.code {
            case .timedOut: return UpdateFailure(message: "GitHub не ответил вовремя. Попробуй ещё раз.")
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return UpdateFailure(message: "Не удалось подключиться к GitHub. Проверь подключение к интернету.")
            case .cancelled: return UpdateFailure(message: "Проверка обновлений отменена.")
            default: return UpdateFailure(message: "Не удалось безопасно подключиться к GitHub. Попробуй позже.")
            }
        }
        return UpdateFailure(message: "Не удалось проверить обновления. Попробуй позже.")
    }

    private enum Keys {
        static let automaticChecks = "updates.automaticChecksEnabled"
        static let lastChecked = "updates.lastChecked"
        static let lastAttempt = "updates.lastAttempt"
        static let lastReleasePayload = "updates.lastReleasePayload"
    }
}

/// Numeric stable versions; shorter local bundle versions compare as zero-padded triples.
struct UpdateVersion: Comparable, Sendable {
    private let components: [UInt64]
    var description: String { components.map(String.init).joined(separator: ".") }

    init?(_ raw: String, requireThreeComponents: Bool = false) {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), !requireThreeComponents || pieces.count == 3 else { return nil }
        var parsed: [UInt64] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.utf8.allSatisfy({ (48...57).contains($0) }),
                  piece.count == 1 || piece.first != "0",
                  let number = UInt64(piece) else { return nil }
            parsed.append(number)
        }
        components = parsed + Array(repeating: 0, count: 3 - parsed.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) where left != right { return left < right }
        return false
    }
}

enum UpdateReleaseParser {
    static func parse(_ data: Data) throws -> UpdateRelease {
        guard data.count <= 1_048_576 else {
            throw UpdateFailure(message: "GitHub вернул слишком большой ответ о релизе.")
        }
        let payload: GitHubRelease
        do { payload = try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw UpdateFailure(message: "GitHub вернул некорректные данные релиза.") }
        guard !payload.draft, !payload.prerelease else {
            throw UpdateFailure(message: "Стабильный релиз пока не опубликован.")
        }
        guard let version = UpdateVersion(payload.tagName, requireThreeComponents: true) else {
            throw UpdateFailure(message: "В релизе указана некорректная стабильная версия.")
        }
        let root = "https://github.com/Illarioniche/MyWallpaper/releases"
        let page = "\(root)/tag/\(payload.tagName)"
        guard payload.htmlURL == page, let pageURL = URL(string: page) else {
            throw UpdateFailure(message: "Проверка остановлена: адрес страницы релиза не принадлежит MyWallpaper.")
        }
        let filename = "MyWallpaper-\(version.description)-universal.dmg"
        let download = try assetURL(named: filename, assets: payload.assets ?? [],
                                    expected: "\(root)/download/\(payload.tagName)/\(filename)")
        let checksum = try assetURL(named: filename + ".sha256", assets: payload.assets ?? [],
                                    expected: "\(root)/download/\(payload.tagName)/\(filename).sha256")
        let title = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateRelease(version: version.description,
                             title: title?.isEmpty == false ? String(title!.prefix(200)) : "MyWallpaper \(version.description)",
                             notes: String((payload.body ?? "").prefix(20_000)), pageURL: pageURL,
                             downloadURL: download, checksumURL: download == nil ? nil : checksum)
    }

    private static func assetURL(named name: String, assets: [GitHubRelease.Asset], expected: String) throws -> URL? {
        let matches = assets.filter { $0.name == name }
        guard matches.count <= 1 else { throw UpdateFailure(message: "GitHub вернул неоднозначный список файлов релиза.") }
        guard let asset = matches.first else { return nil }
        guard asset.browserDownloadURL == expected, let url = URL(string: expected) else {
            throw UpdateFailure(message: "Проверка остановлена: адрес файла обновления не прошёл проверку.")
        }
        guard asset.state == "uploaded" else { return nil }
        return url
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let htmlURL: String
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url"
            case name, body, draft, prerelease, assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            let state: String?
            enum CodingKeys: String, CodingKey {
                case browserDownloadURL = "browser_download_url"
                case name, state
            }
        }
    }
}

enum GitHubUpdateTransport {
    static let endpoint = URL(string: "https://api.github.com/repos/Illarioniche/MyWallpaper/releases/latest")!

    static func request() -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MyWallpaper-UpdateChecker", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func fetch(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: RejectUpdateRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw UpdateFailure(message: "GitHub вернул неожиданный ответ.")
        }
        return UpdateHTTPResponse(data: data, statusCode: response.statusCode, finalURL: url)
    }
}

private final class RejectUpdateRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct UpdateFailure: Error {
    let message: String
    let argument: String?

    init(message: String, argument: String? = nil) {
        self.message = message
        self.argument = argument
    }

    func localized(using localizer: AppLocalizer) -> String {
        if let argument { return localizer.format(message, argument) }
        return localizer.text(message)
    }
}
