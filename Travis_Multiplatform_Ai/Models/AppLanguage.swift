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

    /// BCP-47 code used to pick an `AVSpeechSynthesisVoice` for this
    /// language — see `SpeechService`.
    var speechLanguageCode: String {
        switch self {
        case .greek: return "el-GR"
        case .english: return "en-US"
        }
    }
}
