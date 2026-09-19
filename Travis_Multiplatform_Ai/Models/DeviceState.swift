import Foundation

enum DeviceState: String, Codable, CaseIterable {
    case idle
    case listening
    case processing
    case notifying
    case offline

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Processing"
        case .notifying: return "Notifying"
        case .offline: return "Offline"
        }
    }
}
