import Foundation

@MainActor
extension AgentOrchestrator {
    /// Shared execution entry point for autonomous runtime calls. This keeps
    /// capability discovery inside the orchestrator while routing execution
    /// through the same UniversalCapabilityRunner used by conversational work.
    func executeCapability(
        id capabilityId: String,
        command: String,
        taskId: UUID? = nil,
        stepId: UUID? = nil,
        projectId: UUID? = nil,
        recentHistory: [ChatMessage] = []
    ) async throws -> CapabilityOutcome {
        guard let capability = capabilities.first(where: { $0.id == capabilityId }) else {
            throw AgentTaskExecutorError.missingCapability(capabilityId)
        }

        return try await UniversalCapabilityRunner.shared.run(
            capability: capability,
            command: command,
            context: .init(
                taskId: taskId,
                stepId: stepId,
                projectId: projectId,
                recentHistory: recentHistory
            )
        )
    }

    func executeCapability(
        invocation: DeterministicCapabilityInvocation,
        taskId: UUID? = nil,
        stepId: UUID? = nil,
        projectId: UUID? = nil,
        recentHistory: [ChatMessage] = []
    ) async throws -> CapabilityOutcome {
        guard let capability = capabilities.first(where: { $0.id == invocation.capabilityId }) else {
            throw AgentTaskExecutorError.missingCapability(invocation.capabilityId)
        }

        return try await UniversalCapabilityRunner.shared.run(
            capability: capability,
            invocation: invocation,
            context: .init(
                taskId: taskId,
                stepId: stepId,
                projectId: projectId,
                recentHistory: recentHistory
            )
        )
    }
}
