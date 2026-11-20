import Foundation

/// A stable installation identity is independent of the editable library label.
/// Neither the label nor the original video filename is used as a filesystem path.
struct ScreenSaverInstallationIdentity: Equatable, Sendable {
    let id: UUID
    let name: String

    var bundleIdentifier: String { "app.mywallpaper.screensaver." + id.uuidString.lowercased() }
    var principalClass: String { "MyWallpaperSaver_" + id.uuidString.replacingOccurrences(of: "-", with: "") }
    var fileName: String { "MyWallpaper-" + id.uuidString + ".saver" }
}
