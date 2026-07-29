import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case greek
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .greek: return "Ελληνικά"
        case .english: return "English"
        }
    }
}
