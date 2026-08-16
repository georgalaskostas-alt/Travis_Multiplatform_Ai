import Foundation

/// Synchronizes verified autonomous task outcomes back into their project
/// workspace. Decisions remain explicit user/project-memory operations; this
/// component updates only descriptive project summary and an auditable note.
@MainActor
final class ProjectMemoryCoordinator {
    private let store: ProjectWorkspaceStore
    private let aiService: AIService

    init(store: ProjectWorkspaceStore = .shared, aiService: AIService = .shared) {
        self.store = store
        self.aiService = aiService
    }

    func synchronize(taskId: UUID, runtime: AgentTaskRuntime) async {
        guard let task = runtime.task(id: taskId),
              task.status == .completed,
              let project = store.project(containingTask: taskId) else { return }

        let marker = "Completed task \(task.id.uuidString.prefix(8))"
        if project.notes.contains(where: { $0.text.hasPrefix(marker) }) { return }

        let completedOutputs = task.plan.steps
            .filter { $0.status == .completed }
            .sorted { $0.order < $1.order }
            .compactMap { step -> String? in
                guard let result = step.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !result.isEmpty else { return nil }
                return "STEP #\(step.order) — \(step.title)\n\(String(result.prefix(8000)))"
            }
            .joined(separator: "\n\n")

        let checkpoint = task.executionState.lastCheckpoint?.summary ?? "Completed without a final checkpoint summary."
        store.addNote("\(marker): \(checkpoint)", to: project.id)

        guard !completedOutputs.isEmpty else { return }

        let prompt = """
        Update a persistent project STATUS SUMMARY using ONLY the supplied project memory and VERIFIED TASK OUTPUTS.
        Do not invent decisions, requirements, files, results, or future work.
        Do not rewrite explicit decisions. Summarize current achieved state, unresolved work explicitly present in evidence, and the most recent verified progress.
        Maximum 700 words. Plain text only.

        EXISTING PROJECT MEMORY
        \(store.contextBlock(for: project, taskRuntime: runtime))

        NEW VERIFIED TASK OUTPUTS
        \(completedOutputs)
        """

        guard let summary = try? await aiService.generateText(prompt: prompt, maxTokens: 1000) else { return }
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        store.updateSummary(cleaned, projectId: project.id)
    }
}
