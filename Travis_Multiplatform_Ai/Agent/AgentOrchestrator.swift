import Foundation
import Observation

@MainActor
@Observable
final class AgentOrchestrator {
    private(set) var capabilities: [AgentCapability] = []
    let approvalGate: ApprovalGateService
    private let sessionRecallService: SessionRecallService
    var onAssistantMessage: ((String) -> Void)?
    /// Fired instead of normal routing when the message is recognized as a
    /// "bring back an old conversation" request and a match was found.
    var onSessionRecall: ((UUID) -> Void)?

    init(approvalGate: ApprovalGateService, sessionRecallService: SessionRecallService? = nil) {
        self.approvalGate = approvalGate
        self.sessionRecallService = sessionRecallService ?? SessionRecallService()

        // Repository/source analysis is a core read-only capability of the
        // orchestrator. Register it before AppState adds the generic text
        // capability so source-grounded work cannot silently fall back to
        // ungrounded conversational reasoning.
        let repositoryContext = RepositoryContextCapability()
        capabilities.append(repositoryContext)
        approvalGate.register(capability: repositoryContext)
    }

    func register(_ capability: AgentCapability) {
        capabilities.append(capability)
        approvalGate.register(capability: capability)
    }

    /// `liveSessionId` is the session new messages are actually being
    /// appended to right now — passed in so a recall request never matches
    /// (or needs to search within) the very session it was typed into.
    /// `recentHistory` is a short recent window of the live session's
    /// messages (not including `message` itself) — passed straight through
    /// to whichever capability ends up handling this, so references like
    /// "αυτό"/"σχετικά" resolve against what was actually just said.
    func route(_ message: String, liveSessionId: UUID, recentHistory: [ChatMessage]) async {
        if let outcome = try? await sessionRecallService.evaluate(message, excluding: liveSessionId, recentHistory: recentHistory) {
            switch outcome {
            case .found(let sessionId):
                onSessionRecall?(sessionId)
                return
            case .notFound:
                onAssistantMessage?("Δεν βρήκα παλαιότερη συνομιλία που να ταιριάζει με αυτό που ζήτησες.")
                return
            case .notRecall:
                break
            }
        }

        let lowered = message.lowercased()

        let keywordMatch = capabilities.first(where: { capability in
            !capability.keywords.isEmpty && capability.keywords.contains { lowered.contains($0.lowercased()) }
        })
        let defaultCapability = capabilities.first(where: { $0.keywords.isEmpty })

        guard let capability = keywordMatch ?? defaultCapability else {
            onAssistantMessage?("Δεν κατάλαβα ποια δραστηριότητα αφορά αυτό.")
            return
        }

        do {
            switch try await capability.handle(command: message, recentHistory: recentHistory) {
            case .reply(let text):
                onAssistantMessage?(text)
            case .proposal(let action):
                approvalGate.submit(action)
            case .none:
                break
            }
        } catch {
            onAssistantMessage?("Σφάλμα: \(error.localizedDescription)")
        }
    }
}
