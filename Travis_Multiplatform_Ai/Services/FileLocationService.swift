import Foundation
#if os(macOS)
import AppKit
#endif

/// Resolves where a file should be written, respecting the App Sandbox.
///
/// - `location == nil` (no location mentioned by the user) → always the
///   app's own sandbox container (Documents), on both platforms — no
///   permission dance needed since the app already owns that directory.
/// - `location` given, on macOS → that's necessarily outside the sandbox
///   container (Desktop, ~/Documents, an arbitrary path, ...), which the
///   App Sandbox blocks by default. We resolve a previously granted
///   security-scoped bookmark for that location if one exists; otherwise
///   we present an NSOpenPanel so the user explicitly grants access, then
///   persist the resulting bookmark so this only happens once per location.
/// - `location` given, on iOS → iOS has no "Desktop"/system-folder concept
///   and no NSOpenPanel, so the location is ignored and we fall back to
///   the default sandboxed directory.
@MainActor
final class FileLocationService {
    static let shared = FileLocationService()

    struct ResolvedLocation {
        let url: URL
        let stopAccessing: () -> Void
    }

    private let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
    }

    func resolveSaveDirectory(for location: String?) -> ResolvedLocation? {
        guard let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultDirectory()
        }

        #if os(macOS)
        return resolveMacOSDirectory(for: location)
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
    private func resolveMacOSDirectory(for location: String) -> ResolvedLocation? {
        let key = Self.normalize(location)

        if let bookmarkData = persistence.loadLocationBookmark(for: key),
           let resolved = resolveBookmark(bookmarkData, key: key) {
            return resolved
        }

        return promptForFolder(key: key, hint: location)
    }

    private func resolveBookmark(_ data: Data, key: String) -> ResolvedLocation? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        guard url.startAccessingSecurityScopedResource() else { return nil }

        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            persistence.saveLocationBookmark(key: key, data: refreshed)
        }

        return ResolvedLocation(url: url, stopAccessing: { url.stopAccessingSecurityScopedResource() })
    }

    private func promptForFolder(key: String, hint: String) -> ResolvedLocation? {
        let panel = NSOpenPanel()
        panel.title = "Επιλογή φακέλου"
        panel.message = "Ο TRAVIS χρειάζεται άδεια για αποθήκευση στο \"\(hint)\". Επίλεξε τον φάκελο για να συνεχίσει."
        panel.prompt = "Επιλογή"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = Self.suggestedDirectoryURL(for: hint)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return nil }

        persistence.saveLocationBookmark(key: key, data: bookmarkData)

        guard url.startAccessingSecurityScopedResource() else { return nil }
        return ResolvedLocation(url: url, stopAccessing: { url.stopAccessingSecurityScopedResource() })
    }

    private static func suggestedDirectoryURL(for hint: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lower = hint.lowercased()

        if lower.contains("desktop") { return home.appendingPathComponent("Desktop") }
        if lower.contains("document") { return home.appendingPathComponent("Documents") }
        if lower.contains("download") { return home.appendingPathComponent("Downloads") }
        return nil
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    #endif
}
