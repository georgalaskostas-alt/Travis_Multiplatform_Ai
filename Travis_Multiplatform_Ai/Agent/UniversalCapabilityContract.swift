import Foundation

enum CapabilityEffect: String, Codable, CaseIterable, Hashable {
    case readOnly
    case localMutation
    case externalMutation
    case financial
    case codeMutation
}

enum CapabilityDomain: String, Codable, CaseIterable, Hashable {
    case conversation
    case research
    case repository
    case files
    case coding
    case trading
    case productivity
    case automation
    case system
    case other
}

struct CapabilityExecutionPolicy: Codable, Hashable {
    var declaredEffects: [CapabilityEffect]
    var permissionKeys: [String]
    var requiresExplicitApproval: Bool
    var supportsBackgroundExecution: Bool
    var supportsProjectContext: Bool
    var timeoutSeconds: Int
    var maxAttempts: Int

    init(
        declaredEffects: [CapabilityEffect] = [.readOnly],
        permissionKeys: [String] = [],
        requiresExplicitApproval: Bool = false,
        supportsBackgroundExecution: Bool = true,
        supportsProjectContext: Bool = true,
        timeoutSeconds: Int = 120,
        maxAttempts: Int = 3
    ) {
        let effects = declaredEffects.isEmpty ? [.readOnly] : declaredEffects
        self.declaredEffects = Array(Set(effects)).sorted { $0.rawValue < $1.rawValue }
        self.permissionKeys = Array(Set(permissionKeys)).sorted()
        self.requiresExplicitApproval = requiresExplicitApproval
        self.supportsBackgroundExecution = supportsBackgroundExecution
        self.supportsProjectContext = supportsProjectContext
        self.timeoutSeconds = max(5, timeoutSeconds)
        self.maxAttempts = max(1, maxAttempts)
    }

    func declares(_ effect: CapabilityEffect) -> Bool {
        declaredEffects.contains(effect)
    }
}

struct CapabilityDescriptor: Identifiable, Codable, Hashable {
    var id: String
    var displayName: String
    var summary: String
    var domain: CapabilityDomain
    var keywords: [String]
    var policy: CapabilityExecutionPolicy
    var version: Int

    init(
        id: String,
        displayName: String,
        summary: String,
        domain: CapabilityDomain = .other,
        keywords: [String] = [],
        policy: CapabilityExecutionPolicy = CapabilityExecutionPolicy(),
        version: Int = 1
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.domain = domain
        self.keywords = keywords
        self.policy = policy
        self.version = max(1, version)
    }
}

struct CapabilityExecutionRecord: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case started
        case replied
        case proposedMutation
        case noResult
        case failed
        case cancelled
        case timedOut
    }

    let id: UUID
    var capabilityId: String
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var commandSummary: String
    var taskId: UUID?
    var projectId: UUID?
    var resultSummary: String?
    var artifactPaths: [String]
    var errorDescription: String?

    init(
        id: UUID = UUID(),
        capabilityId: String,
        startedAt: Date = Date(),
        status: Status = .started,
        commandSummary: String,
        taskId: UUID? = nil,
        projectId: UUID? = nil
    ) {
        self.id = id
        self.capabilityId = capabilityId
        self.startedAt = startedAt
        self.status = status
        self.commandSummary = String(commandSummary.prefix(400))
        self.taskId = taskId
        self.projectId = projectId
        self.artifactPaths = []
    }
}

extension AgentCapability {
    /// Backward-compatible descriptor. Existing capabilities compile unchanged;
    /// specialist capabilities override this to declare precise execution semantics.
    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .other,
            keywords: keywords
        )
    }
}
