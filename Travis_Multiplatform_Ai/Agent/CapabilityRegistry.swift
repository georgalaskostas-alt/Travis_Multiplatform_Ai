import Foundation

struct CapabilityRegistry {
    private let descriptorsById: [String: CapabilityDescriptor]

    init(capabilities: [AgentCapability]) {
        var map: [String: CapabilityDescriptor] = [:]
        for capability in capabilities {
            map[capability.id] = capability.descriptor
        }
        self.descriptorsById = map
    }

    var descriptors: [CapabilityDescriptor] {
        descriptorsById.values.sorted { lhs, rhs in
            if lhs.domain.rawValue != rhs.domain.rawValue {
                return lhs.domain.rawValue < rhs.domain.rawValue
            }
            return lhs.id < rhs.id
        }
    }

    var ids: [String] { descriptors.map(\.id) }

    func descriptor(id: String) -> CapabilityDescriptor? {
        descriptorsById[id]
    }

    func supportsBackground(id: String) -> Bool {
        descriptor(id: id)?.policy.supportsBackgroundExecution ?? false
    }

    func supportsProjectContext(id: String) -> Bool {
        descriptor(id: id)?.policy.supportsProjectContext ?? false
    }

    func promptCatalog() -> String {
        guard !descriptors.isEmpty else { return "No capabilities registered." }
        return descriptors.map { descriptor in
            let effects = descriptor.policy.declaredEffects.map(\.rawValue).joined(separator: ",")
            let permissions = descriptor.policy.permissionKeys.isEmpty
                ? "none"
                : descriptor.policy.permissionKeys.joined(separator: ",")
            return """
            - id: \(descriptor.id)
              domain: \(descriptor.domain.rawValue)
              description: \(descriptor.summary)
              effects: \(effects)
              permissions: \(permissions)
              approvalByDefault: \(descriptor.policy.requiresExplicitApproval)
              background: \(descriptor.policy.supportsBackgroundExecution)
              projectContext: \(descriptor.policy.supportsProjectContext)
              timeoutSeconds: \(descriptor.policy.timeoutSeconds)
              maxAttempts: \(descriptor.policy.maxAttempts)
            """
        }.joined(separator: "\n")
    }

    func diagnosticReport() -> String {
        guard !descriptors.isEmpty else { return "CAPABILITIES\n\nκανένα" }
        let rows = descriptors.map { descriptor in
            let effects = descriptor.policy.declaredEffects.map(\.rawValue).joined(separator: ",")
            return "\(descriptor.id) [\(descriptor.domain.rawValue)] effects:\(effects) bg:\(descriptor.policy.supportsBackgroundExecution) timeout:\(descriptor.policy.timeoutSeconds)s — \(descriptor.displayName)"
        }.joined(separator: "\n")
        return "CAPABILITY REGISTRY\n\n\(rows)"
    }
}
