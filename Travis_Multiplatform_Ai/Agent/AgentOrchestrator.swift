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
        print("[TRAVIS DEBUG] route() called with message: \"\(message)\", registered capabilities: \(capabilities.map(\.id))")
        let lowered = message.lowercased()

        guard let capability = capabilities.first(where: { capability in
            capability.keywords.contains { lowered.contains($0.lowercased()) }
        }) else {
            print("[TRAVIS DEBUG] route() — no capability matched \"\(lowered)\", sending fallback")
            onAssistantMessage?("Δεν κατάλαβα ποια δραστηριότητα αφορά αυτό.")
            return
        }

        print("[TRAVIS DEBUG] route() — matched capability: \(capability.id), calling handle()")

        do {
            if let action = try await capability.handle(command: message) {
                print("[TRAVIS DEBUG] route() — handle() returned a ProposedAction, submitting to approvalGate")
                approvalGate.submit(action)
            } else {
                print("[TRAVIS DEBUG] route() — handle() returned nil (no action proposed)")
            }
        } catch {
            print("[TRAVIS DEBUG] route() — handle() threw: \(error)")
            onAssistantMessage?("Σφάλμα: \(error.localizedDescription)")
        }
    }
}
