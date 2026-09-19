import Foundation

struct CapabilityRegistry {
    private let descriptorsById: [String: CapabilityDescriptor]

    init(capabilities: [AgentCapability]) {
        var map: [String: CapabilityDescriptor] = [:]
        for capability in capabilities { map[capability.id] = capability.descriptor }
        self.descriptorsById = map
    }

    var descriptors: [CapabilityDescriptor] {
        descriptorsById.values.sorted { lhs, rhs in
            if lhs.domain.rawValue != rhs.domain.rawValue { return lhs.domain.rawValue < rhs.domain.rawValue }
            return lhs.id < rhs.id
        }
    }

    var ids: [String] { descriptors.map(\.id) }
    func descriptor(id: String) -> CapabilityDescriptor? { descriptorsById[id] }
    func supportsBackground(id: String) -> Bool { descriptor(id: id)?.policy.supportsBackgroundExecution ?? false }
    func supportsProjectContext(id: String) -> Bool { descriptor(id: id)?.policy.supportsProjectContext ?? false }

    /// Human-readable catalog for planner prompts. Compact enough to avoid paying
    /// repeated token tax for prose that the planner does not need.
    func promptCatalog() -> String {
        guard !descriptors.isEmpty else { return "No capabilities registered." }
        return descriptors.map { descriptor in
            let effects = descriptor.policy.declaredEffects.map(\.rawValue).joined(separator: ",")
            let permissions = descriptor.policy.permissionKeys.isEmpty ? "none" : descriptor.policy.permissionKeys.joined(separator: ",")
            let inputs = descriptor.inputSchema?.sorted(by: {$0.key<$1.key}).map{"\($0.key):\($0.value)"}.joined(separator:",") ?? "freeform"
            let outputs = descriptor.outputKinds?.map(\.rawValue).joined(separator:",") ?? "text"
            return "\(descriptor.id)|domain=\(descriptor.domain.rawValue)|effects=\(effects)|approval=\(descriptor.policy.requiresExplicitApproval)|bg=\(descriptor.policy.supportsBackgroundExecution)|timeout=\(descriptor.policy.timeoutSeconds)|attempts=\(descriptor.policy.maxAttempts)|cost=\(descriptor.costClass?.rawValue ?? "unspecified")|inputs=\(inputs)|outputs=\(outputs)|\(descriptor.summary)"
        }.joined(separator: "\n")
    }

    /// Structured registry for a future dynamic/MCP-style tool bridge. No model
    /// needs to scrape natural-language documentation to discover basic contracts.
    func machineCatalog() -> [[String:Any]] {
        descriptors.map { d in
            var row:[String:Any] = [
                "id":d.id,"name":d.displayName,"summary":d.summary,"domain":d.domain.rawValue,
                "effects":d.policy.declaredEffects.map(\.rawValue),"permissionKeys":d.policy.permissionKeys,
                "requiresApproval":d.policy.requiresExplicitApproval,"background":d.policy.supportsBackgroundExecution,
                "projectContext":d.policy.supportsProjectContext,"timeoutSeconds":d.policy.timeoutSeconds,
                "maxAttempts":d.policy.maxAttempts,"version":d.version
            ]
            if let schema=d.inputSchema{row["inputSchema"]=schema}
            if let kinds=d.outputKinds{row["outputKinds"]=kinds.map(\.rawValue)}
            if let cost=d.costClass{row["costClass"]=cost.rawValue}
            if let deterministic=d.deterministicWhenStructured{row["deterministicWhenStructured"]=deterministic}
            if let fresh=d.freshnessSensitive{row["freshnessSensitive"]=fresh}
            return row
        }
    }

    func diagnosticReport() -> String {
        guard !descriptors.isEmpty else { return "CAPABILITIES\n\nκανένα" }
        let rows = descriptors.map { descriptor in
            let effects = descriptor.policy.declaredEffects.map(\.rawValue).joined(separator: ",")
            let outputs=descriptor.outputKinds?.map(\.rawValue).joined(separator:",") ?? "text"
            return "\(descriptor.id) [\(descriptor.domain.rawValue)] effects:\(effects) bg:\(descriptor.policy.supportsBackgroundExecution) cost:\(descriptor.costClass?.rawValue ?? "n/a") outputs:\(outputs) timeout:\(descriptor.policy.timeoutSeconds)s — \(descriptor.displayName)"
        }.joined(separator: "\n")
        return "CAPABILITY REGISTRY V6\n\n\(rows)"
    }
}
