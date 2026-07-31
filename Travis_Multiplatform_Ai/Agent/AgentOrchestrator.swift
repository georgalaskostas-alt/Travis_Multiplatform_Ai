import Foundation
import Observation

@MainActor
@Observable
final class AgentOrchestrator {
    private(set) var capabilities: [AgentCapability] = []
    let approvalGate: ApprovalGateService
    var onAssistantMessage: ((String) -> Void)?

    init(approvalGate: ApprovalGateService) {
        self.approvalGate = approvalGate
    }

    func register(_ capability: AgentCapability) {
        capabilities.append(capability)
        approvalGate.register(capability: capability)
    }

    func route(_ message: String) async {
        let lowered = message.lowercased()

        guard let capability = capabilities.first(where: { capability in
            capability.keywords.contains { lowered.contains($0.lowercased()) }
        }) else {
            onAssistantMessage?("Δεν κατάλαβα ποια δραστηριότητα αφορά αυτό.")
            return
        }

        do {
            if let action = try await capability.handle(command: message) {
                approvalGate.submit(action)
            }
        } catch {
            onAssistantMessage?("Σφάλμα: \(error.localizedDescription)")
        }
    }
}
