import Foundation

@MainActor
extension AgentOrchestrator {
    /// Shared execution entry point for autonomous runtime calls.
    /// It now tries the safe structured/local path before the normal semantic path.
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

        // 1. Already-structured invocation: execute directly without model parsing.
        if let encodedInvocation = StructuredInvocationCodec.decode(from: command),
           encodedInvocation.capabilityId == capabilityId,
           capability is any DeterministicInvocableCapability {
            let invocation = try StructuredWorkflowBindingResolver.resolve(
                invocation: encodedInvocation,
                taskId: taskId
            )
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

        // 2. Autonomous steps contain a lot of context around the real instruction.
        // Extract ONLY the current instruction, so old learned examples can never
        // accidentally provide stale paths/arguments to deterministic execution.
        if capability is any DeterministicInvocableCapability {
            let currentInstruction = autonomousCurrentInstruction(from: command) ?? command
            if let localInvocation = DeterministicCommandRouter.shared.invocation(
                for: currentInstruction,
                capabilities: capabilities
            ), localInvocation.capabilityId == capabilityId {
                let invocation = try StructuredWorkflowBindingResolver.resolve(
                    invocation: localInvocation,
                    taskId: taskId
                )
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

        // 3. If the step cannot be represented safely and exactly, keep the
        // existing path. This is the fallback that may use AI when required.
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

        let resolvedInvocation = try StructuredWorkflowBindingResolver.resolve(
            invocation: invocation,
            taskId: taskId
        )
        return try await UniversalCapabilityRunner.shared.run(
            capability: capability,
            invocation: resolvedInvocation,
            context: .init(
                taskId: taskId,
                stepId: stepId,
                projectId: projectId,
                recentHistory: recentHistory
            )
        )
    }

    /// The executor wraps the real instruction between these two labels.
    /// Reading only this slice keeps model-free execution tied to CURRENT data.
    private func autonomousCurrentInstruction(from command: String) -> String? {
        let startMarker = "ΟΔΗΓΙΕΣ:"
        let endMarkers = [
            "VERIFIED DEPENDENCY EVIDENCE:",
            "LEARNED LOCAL SKILL",
            "VERIFIED PRIOR EXPERIENCE",
            "No sufficiently proven learned skill.",
            "No sufficiently similar verified prior experience."
        ]

        guard let startRange = command.range(of: startMarker) else { return nil }
        let afterStart = command[startRange.upperBound...]

        var nearestEnd: String.Index?
        for marker in endMarkers {
            if let range = afterStart.range(of: marker) {
                if nearestEnd == nil || range.lowerBound < nearestEnd! {
                    nearestEnd = range.lowerBound
                }
            }
        }

        let raw: Substring
        if let nearestEnd {
            raw = afterStart[..<nearestEnd]
        } else {
            raw = afterStart
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
