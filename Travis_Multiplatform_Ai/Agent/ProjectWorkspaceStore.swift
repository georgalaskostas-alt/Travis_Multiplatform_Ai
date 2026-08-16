import Foundation

final class ProjectWorkspaceStore {
    static let shared = ProjectWorkspaceStore()

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var projects: [ProjectWorkspace]
    }

    private let schemaVersion = 1
    private let fileManager: FileManager
    private let storeURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent("TRAVIS/Projects", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("project-workspaces-v1.json")
    }

    func load() -> [ProjectWorkspace] {
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data), snapshot.schemaVersion == schemaVersion else { return [] }
        return snapshot.projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func create(title: String, goal: String, summary: String = "") -> ProjectWorkspace {
        var projects = load()
        let project = ProjectWorkspace(title: title, goal: goal, summary: summary)
        projects.append(project)
        save(projects)
        return project
    }

    func project(id: UUID) -> ProjectWorkspace? { load().first { $0.id == id } }

    func find(_ query: String) -> [ProjectWorkspace] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return load() }
        return load().filter { normalized($0.title + " " + $0.goal + " " + $0.summary).contains(needle) }
    }

    func attachTask(_ taskId: UUID, to projectId: UUID) {
        mutate(projectId) { project in
            if !project.taskIds.contains(taskId) { project.taskIds.append(taskId) }
        }
    }

    func addDecision(_ text: String, rationale: String? = nil, to projectId: UUID) {
        mutate(projectId) { $0.decisions.append(ProjectDecision(text: text, rationale: rationale)) }
    }

    func addNote(_ text: String, to projectId: UUID) {
        mutate(projectId) { $0.notes.append(ProjectNote(text: text)) }
    }

    func addArtifact(path: String, to projectId: UUID) {
        mutate(projectId) { project in
            if !project.artifactPaths.contains(path) { project.artifactPaths.append(path) }
        }
    }

    private func mutate(_ id: UUID, body: (inout ProjectWorkspace) -> Void) {
        var projects = load()
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        body(&projects[index])
        projects[index].updatedAt = Date()
        save(projects)
    }

    private func save(_ projects: [ProjectWorkspace]) {
        let snapshot = Snapshot(schemaVersion: schemaVersion, savedAt: Date(), projects: projects)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
