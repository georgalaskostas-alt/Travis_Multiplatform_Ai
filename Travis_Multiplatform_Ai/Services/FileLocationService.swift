import Foundation
#if os(macOS)
import AppKit
#endif

/// Resolves where generated files or explicitly requested filesystem operations
/// may access data. Security-scoped access is never expanded silently.
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
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact absolute/relative paths are resolved through the same
        // containment-safe security-scope logic used for existing filesystem
        // operations. This prevents silently redirecting an arbitrary requested
        // output folder back to the bookmark root.
        if trimmed.hasPrefix("/") || trimmed.contains("/") {
            guard let resolved = resolveExistingPath(trimmed) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                resolved.stopAccessing()
                return nil
            }
            return resolved
        }

        return resolveHomeSubdirectory(for: trimmed)
        #else
        return defaultDirectory()
        #endif
    }

    /// Resolves an existing user-selected path only when it is contained by the
    /// persisted security-scoped home bookmark. Relative paths are interpreted
    /// below that bookmark. Absolute paths must still remain inside it.
    func resolveExistingPath(_ requestedPath: String) -> ResolvedLocation? {
        let trimmed = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        #if os(macOS)
        guard let bookmarkData = persistence.loadLocationBookmark(for: Self.homeBookmarkKey) else { return nil }
        var isStale = false
        guard let rootURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard rootURL.startAccessingSecurityScopedResource() else { return nil }

        if isStale, let refreshed = try? rootURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            persistence.saveLocationBookmark(key: Self.homeBookmarkKey, data: refreshed)
        }

        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = rootURL.appendingPathComponent(trimmed)
        }

        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidateURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let candidatePath = candidateURL.path
        let contained = candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        guard contained else {
            rootURL.stopAccessingSecurityScopedResource()
            return nil
        }

        guard FileManager.default.fileExists(atPath: candidatePath) else {
            rootURL.stopAccessingSecurityScopedResource()
            return nil
        }

        return ResolvedLocation(url: candidateURL, stopAccessing: { rootURL.stopAccessingSecurityScopedResource() })
        #else
        return nil
        #endif
    }

    private func defaultDirectory() -> ResolvedLocation? {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ResolvedLocation(url: url, stopAccessing: {})
    }

    #if os(macOS)
    @discardableResult
    func requestHomeDirectoryAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Πρόσβαση στον προσωπικό φάκελο"
        panel.message = "Ο TRAVIS χρειάζεται άδεια πρόσβασης στον προσωπικό σου φάκελο για να μπορεί να αποθηκεύει και να διαχειρίζεται αρχεία μόνο μέσα στο scope που επιλέγεις."
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
