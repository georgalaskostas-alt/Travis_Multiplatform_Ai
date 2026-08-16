import Foundation

@MainActor
final class ProjectWorkspaceStore {
    static let shared = ProjectWorkspaceStore()

    enum Resolution: Hashable {
        case found(ProjectWorkspace)
        case ambiguous([ProjectWorkspace])
        case notFound
    }

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
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent("TRAVIS/Projects", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("project-workspaces-v1.json")
    }

    func load() -> [ProjectWorkspace] {
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.schemaVersion == schemaVersion else { return [] }
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

    func project(containingTask taskId: UUID) -> ProjectWorkspace? {
        load().first { $0.taskIds.contains(taskId) }
    }

    func find(_ query: String) -> [ProjectWorkspace] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return load() }
        return load().filter {
            normalized($0.title + " " + $0.goal + " " + $0.summary).contains(needle)
        }
    }

    func resolve(_ rawReference: String?) -> Resolution {
        let projects = load()
        guard !projects.isEmpty else { return .notFound }
        guard let raw = rawReference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            let active = projects.filter { $0.status == .active }
            if active.count == 1, let project = active.first { return .found(project) }
            return active.isEmpty ? .found(projects[0]) : .ambiguous(active)
        }

        let reference = normalized(raw)
        if let exact = projects.first(where: { $0.id.uuidString.lowercased() == reference }) {
            return .found(exact)
        }
        let prefix = projects.filter { $0.id.uuidString.lowercased().hasPrefix(reference) }
        if prefix.count == 1 { return .found(prefix[0]) }
        if prefix.count > 1 { return .ambiguous(prefix) }

        let tokens = reference
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !Self.referenceStopWords.contains($0) }
        guard !tokens.isEmpty else { return .notFound }

        let scored = projects.compactMap { project -> (ProjectWorkspace, Int)? in
            let searchable = normalized(project.title + " " + project.goal + " " + project.summary)
            let score = tokens.reduce(0) { $0 + (searchable.contains($1) ? 1 : 0) }
            return score > 0 ? (project, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.updatedAt > $1.0.updatedAt
        }

        guard let best = scored.first else { return .notFound }
        let tied = scored.filter { $0.1 == best.1 }.map(\.0)
        return tied.count == 1 ? .found(best.0) : .ambiguous(tied)
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

    func updateSummary(_ summary: String, projectId: UUID) {
        mutate(projectId) { $0.summary = summary }
    }

    func updateStatus(_ status: ProjectWorkspace.Status, projectId: UUID) {
        mutate(projectId) { $0.status = status }
    }

    func contextBlock(for projectId: UUID, taskRuntime: AgentTaskRuntime? = nil) -> String? {
        guard let project = project(id: projectId) else { return nil }
        return contextBlock(for: project, taskRuntime: taskRuntime)
    }

    func contextBlock(for project: ProjectWorkspace, taskRuntime: AgentTaskRuntime? = nil) -> String {
        let decisions = project.decisions.suffix(12).map { decision in
            if let rationale = decision.rationale, !rationale.isEmpty {
                return "- \(decision.text) — rationale: \(rationale)"
            }
            return "- \(decision.text)"
        }.joined(separator: "\n")

        let notes = project.notes.suffix(12).map { "- \($0.text)" }.joined(separator: "\n")
        let artifacts = project.artifactPaths.suffix(12).map { "- \($0)" }.joined(separator: "\n")

        var priorTasks = "None"
        if let runtime = taskRuntime {
            let rows = project.taskIds.suffix(10).compactMap { id -> String? in
                guard let task = runtime.task(id: id) else { return nil }
                let checkpoint = task.executionState.lastCheckpoint?.summary ?? "no checkpoint"
                return "- \(task.id.uuidString.prefix(8)) [\(task.status.rawValue)] \(task.title) — \(checkpoint)"
            }
            if !rows.isEmpty { priorTasks = rows.joined(separator: "\n") }
        }

        return """
        PROJECT MEMORY — CANONICAL CONTEXT
        Project ID: \(project.id.uuidString)
        Title: \(project.title)
        Status: \(project.status.rawValue)
        Goal: \(project.goal)
        Summary: \(project.summary.isEmpty ? "Not established yet" : project.summary)

        RECENT DECISIONS
        \(decisions.isEmpty ? "None" : decisions)

        RECENT NOTES
        \(notes.isEmpty ? "None" : notes)

        ARTIFACTS
        \(artifacts.isEmpty ? "None" : artifacts)

        PRIOR PROJECT TASKS
        \(priorTasks)
        """
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func normalized(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "el_GR")
        ).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let referenceStopWords: Set<String> = [
        "project", "προτζεκτ", "εργο", "συνεχισε", "continue", "παμε",
        "στο", "στη", "στην", "του", "της", "απο", "εκεί", "μειναμε"
    ]
}
