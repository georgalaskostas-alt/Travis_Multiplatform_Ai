import Foundation

enum RiskLevel: String, Codable, CaseIterable {
    case low
    case medium
    case high
}

enum ProposedActionStatus: String, Codable, CaseIterable {
    case pending
    case approved
    case rejected
}

struct ProposedAction: Identifiable, Codable, Hashable {
    let id: UUID
    var capabilityId: String
    var summary: String
    var reasoning: String
    var expectedImpact: String
    var riskLevel: RiskLevel
    var status: ProposedActionStatus
    var payload: String?
    var createdAt: Date
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        capabilityId: String,
        summary: String,
        reasoning: String,
        expectedImpact: String,
        riskLevel: RiskLevel,
        status: ProposedActionStatus = .pending,
        payload: String? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.capabilityId = capabilityId
        self.summary = summary
        self.reasoning = reasoning
        self.expectedImpact = expectedImpact
        self.riskLevel = riskLevel
        self.status = status
        self.payload = payload
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}
