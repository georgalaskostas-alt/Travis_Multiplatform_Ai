import Foundation

final class TextTaskCapability: AgentCapability {
    let id = "text_task"
    let name = "Text Task"
    let capabilityDescription = "Γράφει κείμενο σε φυσική γλώσσα βάσει της εντολής του χρήστη (π.χ. \"γράψε μου ένα κείμενο για Χ\")."
    let keywords = ["γράψε", "γράψτε", "κείμενο", "write", "text"]
    private(set) var status: AgentCapabilityStatus = .idle

    private let aiService: AIService

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func handle(command: String) async -> ProposedAction? {
        status = .running
        defer { status = .idle }

        let prompt = """
        Ο χρήστης ζήτησε: "\(command)"

        Γράψε το κείμενο που ζητήθηκε, στα ελληνικά, έτοιμο να αποθηκευτεί σε αρχείο .txt. Απάντησε μόνο με το τελικό κείμενο, χωρίς εισαγωγικά σχόλια.
        """

        do {
            let generatedText = try await aiService.generateText(prompt: prompt)
            return ProposedAction(
                capabilityId: id,
                summary: "Δημιουργία κειμένου: \"\(command)\"",
                reasoning: "Η εντολή ζητάει παραγωγή κειμένου, οπότε κάλεσα το AI για να το γράψει. Πρόκειται για αναστρέψιμη ενέργεια — απλή αποθήκευση σε τοπικό αρχείο, χωρίς καμία άλλη επίδραση στο σύστημα.",
                expectedImpact: "Θα αποθηκευτεί ένα νέο αρχείο .txt με το παραγόμενο κείμενο.",
                riskLevel: .low,
                payload: generatedText
            )
        } catch {
            print("TextTaskCapability: αποτυχία κλήσης AIService — \(error.localizedDescription)")
            return nil
        }
    }

    func resolve(_ action: ProposedAction) {
        // Η αποθήκευση του παραγόμενου κειμένου γίνεται από το ChatView κατά το approve.
    }
}
