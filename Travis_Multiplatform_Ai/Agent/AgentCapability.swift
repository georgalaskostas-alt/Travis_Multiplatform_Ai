import Foundation

enum AgentCapabilityStatus: String, Codable, CaseIterable {
    case idle
    case running
    case paused
}

protocol AgentCapability: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var capabilityDescription: String { get }
    var status: AgentCapabilityStatus { get }
    var keywords: [String] { get }

    func handle(command: String) async throws -> ProposedAction?
    func resolve(_ action: ProposedAction)
}
