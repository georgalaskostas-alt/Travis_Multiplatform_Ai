import Foundation
#if os(macOS)
import AppKit
#endif

/// Resolves where a generated file should be written.
///
/// - `location == nil` → always the app's own sandbox container
///   (Documents), on both platforms — the app already owns that
///   directory, no permission needed.
/// - `location` given, on macOS → somewhere under the user's home
///   directory (Desktop, Documents, Downloads, ...), which the App
///   Sandbox blocks by default. Access to that is gated by a single
///   standing permission (`PersistenceService.isPermissionGranted`,
///   keyed `"file_save"`) rather than a picker per folder: once granted,
///   `TextTaskCapability` calls `requestHomeDirectoryAccess()` exactly
///   once to acquire ONE security-scoped bookmark for the whole home
///   directory, which covers everything beneath it. This type only ever
///   resolves an existing bookmark — it never shows UI on its own.
/// - `location` given, on iOS → ignored; iOS has no Desktop/system-folder
///   concept, so we fall back to the sandboxed directory.
@MainActor
final class FileLocationService {
    static let shared = FileLocationService()
    static let homeBookmarkKey = "home_directory"

    struct ResolvedLocation {
        let url: URL
        let stopAccessing: () -> Void
    }

    private let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
    }

    var hasHomeDirectoryAccess: Bool {
        persistence.loadLocationBookmark(for: Self.homeBookmarkKey) != nil
    }

    func resolveSaveDirectory(for location: String?) -> ResolvedLocation? {
        guard let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultDirectory()
        }

        #if os(macOS)
        return resolveHomeSubdirectory(for: location)
        #else
        return defaultDirectory()
        #endif
    }

    private func defaultDirectory() -> ResolvedLocation? {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ResolvedLocation(url: url, stopAccessing: {})
    }

    #if os(macOS)
    /// Presents NSOpenPanel pointed at the user's home directory and, if
    /// granted, persists ONE security-scoped bookmark covering it. Callers
    /// (the conversational grant flow in `TextTaskCapability`) are
    /// responsible for calling this exactly once, right after the user
    /// agrees — never speculatively.
    @discardableResult
    func requestHomeDirectoryAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Πρόσβαση στον προσωπικό φάκελο"
        panel.message = "Ο TRAVIS χρειάζεται άδεια πρόσβασης στον προσωπικό σου φάκελο για να μπορεί να αποθηκεύει αρχεία σε θέσεις όπως το Desktop ή τα Documents."
        panel.prompt = "Επιλογή"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return false }

        persistence.saveLocationBookmark(key: Self.homeBookmarkKey, data: bookmarkData)
        return true
    }

    private func resolveHomeSubdirectory(for location: String) -> ResolvedLocation? {
        guard let bookmarkData = persistence.loadLocationBookmark(for: Self.homeBookmarkKey) else {
            return nil
        }

        var isStale = false
        guard let homeURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        guard homeURL.startAccessingSecurityScopedResource() else { return nil }

        if isStale, let refreshed = try? homeURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            persistence.saveLocationBookmark(key: Self.homeBookmarkKey, data: refreshed)
        }

        let subdirectory = Self.subdirectoryURL(under: homeURL, for: location)
        return ResolvedLocation(url: subdirectory, stopAccessing: { homeURL.stopAccessingSecurityScopedResource() })
    }

    private static func subdirectoryURL(under home: URL, for location: String) -> URL {
        let lower = location.lowercased()
        if lower.contains("desktop") { return home.appendingPathComponent("Desktop") }
        if lower.contains("document") { return home.appendingPathComponent("Documents") }
        if lower.contains("download") { return home.appendingPathComponent("Downloads") }
        return home
    }
    #endif
}
