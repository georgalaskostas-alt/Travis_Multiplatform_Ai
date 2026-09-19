import Foundation
import Observation

@MainActor
@Observable
final class ApprovalGateService {
    private(set) var pendingActions: [ProposedAction] = []
    private(set) var history: [ProposedAction] = []

    private var capabilities: [String: WeakAgentCapabilityBox] = [:]
    private let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
    }

    func register(capability: AgentCapability) {
        capabilities[capability.id] = WeakAgentCapabilityBox(capability)
    }

    /// Loads previously persisted proposed actions so pending approvals and
    /// resolution history survive a restart, not just a session.
    func restore(pending: [ProposedAction], history: [ProposedAction]) {
        pendingActions = pending
        self.history = history
    }

    func submit(_ action: ProposedAction) {
        pendingActions.append(action)
        persistence.saveProposedAction(action)
    }

    func approve(_ action: ProposedAction) {
        resolve(action, as: .approved)
    }

    func reject(_ action: ProposedAction) {
        resolve(action, as: .rejected)
    }

    private func resolve(_ action: ProposedAction, as status: ProposedActionStatus) {
        guard let index = pendingActions.firstIndex(where: { $0.id == action.id }) else { return }

        var resolvedAction = pendingActions.remove(at: index)
        resolvedAction.status = status
        resolvedAction.resolvedAt = Date()
        history.append(resolvedAction)
        persistence.updateProposedAction(resolvedAction)

        capabilities[resolvedAction.capabilityId]?.value?.resolve(resolvedAction)
    }
}

private final class WeakAgentCapabilityBox {
    weak var value: AgentCapability?

    init(_ value: AgentCapability) {
        self.value = value
    }
}
