import Foundation

enum AgentCapabilityStatus: String, Codable, CaseIterable {
    case idle
    case running
    case paused
}

/// What a capability decided to do with a command:
/// - `reply`: plain conversational response, shown directly in chat, no approval needed.
/// - `proposal`: a state-changing action that needs user approval before it happens.
/// - `none`: the capability had nothing to say or do.
enum CapabilityOutcome {
    case reply(String)
    case proposal(ProposedAction)
    case none
}

protocol AgentCapability: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var capabilityDescription: String { get }
    var status: AgentCapabilityStatus { get }
    /// Keywords that route a command to this capability. An empty array marks this
    /// as a catch-all/default capability, used when no other capability's keywords match.
    var keywords: [String] { get }

    func handle(command: String) async throws -> CapabilityOutcome
    func resolve(_ action: ProposedAction)
}
