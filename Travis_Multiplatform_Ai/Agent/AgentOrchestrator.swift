import Foundation
import Observation

@MainActor
@Observable
final class AgentOrchestrator {
    private(set) var capabilities: [AgentCapability] = []
    let approvalGate: ApprovalGateService

    init(approvalGate: ApprovalGateService) {
        self.approvalGate = approvalGate
    }

    func register(_ capability: AgentCapability) {
        capabilities.append(capability)
        approvalGate.register(capability: capability)
    }

    func route(_ message: String) async {
        let lowered = message.lowercased()

        guard let capability = capabilities.first(where: {
            lowered.contains($0.id.lowercased()) || lowered.contains($0.name.lowercased())
        }) else {
            return
        }

        if let action = await capability.handle(command: message) {
            approvalGate.submit(action)
        }
    }
}
