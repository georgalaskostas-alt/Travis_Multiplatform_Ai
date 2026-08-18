import Foundation

extension LocalFileSearchCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
}

extension LocalDocumentCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool {
        invocation.operation.hasPrefix("write_")
    }

    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel {
        requiresApproval(for: invocation) ? .medium : .low
    }
}

extension LocalTextFileReadCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
}

extension LocalTextTransformCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
}

extension LocalProductivityCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool {
        invocation.operation == "clipboard_write"
    }

    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel {
        .low
    }
}

extension LocalAutomationCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool {
        invocation.operation != "list"
    }

    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel {
        .low
    }
}

extension FilesystemOperationsCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool {
        invocation.operation != "list"
    }

    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel {
        invocation.operation == "rename" ? .medium : .low
    }
}

extension AdvancedFilesystemCapability: DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { true }

    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel {
        invocation.operation == "delete" ? .high : .medium
    }
}
