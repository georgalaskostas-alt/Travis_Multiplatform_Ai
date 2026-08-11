import Foundation
import SwiftData

/// See `PersistedChatMessage` for why `.unique` is gone and every
/// non-optional property now has an inline default — required for
/// CloudKit-backed SwiftData.
@Model
final class PersistedProposedAction {
    var id: UUID = UUID()
    var capabilityId: String = ""
    var summary: String = ""
    var reasoning: String = ""
    var expectedImpact: String = ""
    var riskLevel: String = ""
    var status: String = ""
    var payload: String?
    var filename: String?
    var location: String?
    var createdAt: Date = Date()
    var resolvedAt: Date?

    init(from action: ProposedAction) {
        self.id = action.id
        self.capabilityId = action.capabilityId
        self.summary = action.summary
        self.reasoning = action.reasoning
        self.expectedImpact = action.expectedImpact
        self.riskLevel = action.riskLevel.rawValue
        self.status = action.status.rawValue
        self.payload = action.payload
        self.filename = action.filename
        self.location = action.location
        self.createdAt = action.createdAt
        self.resolvedAt = action.resolvedAt
    }

    func apply(_ action: ProposedAction) {
        status = action.status.rawValue
        resolvedAt = action.resolvedAt
    }

    var asProposedAction: ProposedAction {
        ProposedAction(
            id: id,
            capabilityId: capabilityId,
            summary: summary,
            reasoning: reasoning,
            expectedImpact: expectedImpact,
            riskLevel: RiskLevel(rawValue: riskLevel) ?? .low,
            status: ProposedActionStatus(rawValue: status) ?? .pending,
            payload: payload,
            filename: filename,
            location: location,
            createdAt: createdAt,
            resolvedAt: resolvedAt
        )
    }
}
