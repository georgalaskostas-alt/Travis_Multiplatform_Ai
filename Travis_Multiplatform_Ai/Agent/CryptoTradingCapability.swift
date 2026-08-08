import Foundation

/// Paper-trading only: no real exchange account, no API keys, no real
/// money at risk anywhere in this capability. Every position is
/// simulated against `PersistedPaperAccount`/`PersistedPaperPosition`,
/// priced from Binance's public market-data endpoints. A future
/// testnet/live mode is an explicit, separate switch to be added later,
/// only with the user's deliberate approval — this code has no path to
/// a real account.
///
/// `@MainActor` for the same reason as `TextTaskCapability`: it holds
/// mutable state (`pendingMandateRequest`) across separate `handle()`
/// calls while waiting for the user to answer the standing-mandate
/// consent question.
@MainActor
final class CryptoTradingCapability: AgentCapability {
    let id = "crypto_trading"
    let name = "Crypto Trading (Paper)"
    let capabilityDescription = "Παρακολουθεί τιμές crypto μέσω του δημόσιου Binance API και προτείνει paper-trading ενέργειες (άνοιγμα/κλείσιμο θέσης) με υποχρεωτικό stop-loss και position sizing βάσει ρίσκου. Καμία σύνδεση με πραγματικό λογαριασμό."
    let keywords: [String] = [
        "trading", "trade", "συναλλαγή", "crypto", "κρύπτο", "θέση",
        "xrp", "ripple", "solana", "sol", "bitcoin", "btc", "ethereum", "eth"
    ]
    private(set) var status: AgentCapabilityStatus = .idle

    private let aiService: AIService
    private let marketData: BinanceMarketDataService
    private let persistence: PersistenceService

    /// Standing-mandate keys are per-asset — see `PersistenceService`'s
    /// generic `isPermissionGranted`/`setPermission`, the same model
    /// `TextTaskCapability` uses for `"file_save"`.
    private static func mandateKey(for asset: String) -> String { "trading_\(asset)" }

    /// A fully-priced-and-sized open request that's on hold waiting for
    /// the user to answer the standing-mandate consent question — either
    /// because this asset has never been approved, or because this
    /// specific request is unusually risky even for an already-approved
    /// asset (see `handleOpen`).
    private struct PendingOpen {
        let asset: String
        let riskPercent: Double
    }
    private var pendingMandateRequest: PendingOpen?

    init(
        aiService: AIService = .shared,
        marketData: BinanceMarketDataService = .shared,
        persistence: PersistenceService = .shared
    ) {
        self.aiService = aiService
        self.marketData = marketData
        self.persistence = persistence
    }

    func handle(command: String) async throws -> CapabilityOutcome {
        if let pending = pendingMandateRequest {
            return try await resolveMandateConsent(reply: command, pending: pending)
        }

        status = .running
        defer { status = .idle }

        let prompt = """
        Είσαι ο προσωπικός βοηθός TRAVIS, σε λειτουργία crypto trading. ΟΛΕΣ οι ενέργειες είναι paper trading (πλασματικά κεφάλαια) — καμία σύνδεση με πραγματικό λογαριασμό. Ο χρήστης έγραψε: "\(command)"

        Απόφασε ποια από τις τρεις περιπτώσεις ισχύει:
        - "reply": ερώτηση ή συζήτηση για crypto, χωρίς ρητό αίτημα να ανοίξει ή να κλείσει θέση. Αυτή είναι η προεπιλογή εκτός αν το αίτημα είναι ρητό.
        - "open": ρητό αίτημα να ανοίξει/κάνει trading σε ένα asset (π.χ. "κάνε trading στο XRP", "αγόρασε Solana").
        - "close": ρητό αίτημα να κλείσει/πουλήσει μια υπάρχουσα θέση (π.χ. "πούλησε τη θέση μου σε Solana", "κλείσε XRP").

        Αν αναφέρεται συγκεκριμένο crypto asset, βάλε το ticker του στο πεδίο "asset", κεφαλαία, χωρίς κατάληξη νομίσματος (π.χ. "XRP", "SOL", "BTC", "ETH" — όχι "XRPUSDT"). Αν δεν αναφέρεται κανένα asset, βάλε null.

        Αν ο χρήστης ανέφερε ρητά συγκεκριμένο ποσοστό ρίσκου για μια ΝΕΑ θέση (π.χ. "ρίσκαρε 3%"), βάλε τον αριθμό (π.χ. 3 για 3%) στο πεδίο "riskPercent". Αν δεν ανέφερε ρητά ποσοστό, βάλε null — ΜΗΝ υποθέσεις τιμή.

        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με ένα JSON object, χωρίς κανένα άλλο κείμενο: {"kind": "reply, open, ή close", "asset": "TICKER ή null", "riskPercent": αριθμός ή null, "content": "η απάντηση (αν reply) ή σύντομη περιγραφή της ενέργειας, στα ελληνικά"}
        """

        let raw = try await aiService.generateText(prompt: prompt)
        guard let decision = Self.parseDecision(from: raw) else {
            return .reply(raw)
        }

        switch decision.kind {
        case "open":
            return try await handleOpen(decision: decision)
        case "close":
            return try await handleClose(decision: decision)
        default:
            return try await handleReply(decision: decision)
        }
    }

    func resolve(_ action: ProposedAction) {
        guard
            action.status == .approved,
            let payloadJSON = action.payload,
            let data = payloadJSON.data(using: .utf8),
            let trade = try? JSONDecoder().decode(TradePayload.self, from: data)
        else { return }

        switch trade.kind {
        case "open":
            guard let entryPrice = trade.entryPrice, let stopLossPrice = trade.stopLossPrice else { return }
            persistence.openPaperPosition(
                asset: trade.asset, quantity: trade.quantity, entryPrice: entryPrice, stopLossPrice: stopLossPrice
            )
        case "close":
            guard let positionId = trade.positionId, let exitPrice = trade.exitPrice else { return }
            persistence.closePaperPosition(id: positionId, exitPrice: exitPrice)
        default:
            break
        }
    }

    // MARK: - Reply

    private func handleReply(decision: Decision) async throws -> CapabilityOutcome {
        guard let asset = decision.asset else {
            return .reply(decision.content)
        }

        // Best-effort price enrichment — a failed lookup shouldn't turn a
        // successful conversational reply into an error.
        guard let price = try? await marketData.currentPrice(for: asset) else {
            return .reply(decision.content)
        }

        return .reply("\(decision.content) (τρέχουσα τιμή \(asset): $\(Self.formatPrice(price)))")
    }

    // MARK: - Open

    private func handleOpen(decision: Decision) async throws -> CapabilityOutcome {
        guard let asset = decision.asset else {
            return .reply("Σε ποιο crypto asset θέλεις να κάνω trading;")
        }

        guard !persistence.isTradingFrozenToday() else {
            return .reply("Το trading είναι παγωμένο για σήμερα — ξεπεράστηκε το ημερήσιο όριο ζημιάς σε paper trading. Το κλείσιμο υπαρχουσών θέσεων εξακολουθεί να είναι διαθέσιμο.")
        }

        let requestedRiskPercent = decision.riskPercent.map { $0 / 100 } ?? PaperTradingConstants.defaultRiskPercent
        let isUnusual = requestedRiskPercent > PaperTradingConstants.defaultRiskPercent
        let riskPercent = min(requestedRiskPercent, PaperTradingConstants.maxRiskPercent)

        let hasMandate = persistence.isPermissionGranted(Self.mandateKey(for: asset))

        guard hasMandate, !isUnusual else {
            pendingMandateRequest = PendingOpen(asset: asset, riskPercent: riskPercent)
            let reason = hasMandate
                ? "Αυτή η ενέργεια ζητάει μεγαλύτερο ρίσκο από το συνηθισμένο."
                : "Δεν έχω ακόμα άδεια για trading σε \(asset)."
            return .reply("\(reason) Μου δίνεις άδεια να ανοίξω paper θέση σε \(asset) με ρίσκο \(Self.formatPercent(riskPercent)) του λογαριασμού;")
        }

        return .proposal(try await makeOpenProposal(asset: asset, riskPercent: riskPercent))
    }

    /// Fetches a fresh price, computes mandatory stop-loss + risk-based
    /// position size, and builds the approval card. Always called right
    /// before proposing — never from a stale cached price.
    private func makeOpenProposal(asset: String, riskPercent: Double) async throws -> ProposedAction {
        let entryPrice = try await marketData.currentPrice(for: asset)
        let account = persistence.paperAccount()

        let stopLossPrice = entryPrice * (1 - PaperTradingConstants.stopLossPercent)
        let riskAmount = account.cashBalance * riskPercent
        let stopDistance = entryPrice - stopLossPrice
        let riskSizedQuantity = stopDistance > 0 ? riskAmount / stopDistance : 0
        let maxAffordableQuantity = entryPrice > 0 ? account.cashBalance / entryPrice : 0
        let quantity = min(riskSizedQuantity, maxAffordableQuantity)
        let positionCost = quantity * entryPrice

        let payload = TradePayload(
            kind: "open", asset: asset, quantity: quantity,
            entryPrice: entryPrice, stopLossPrice: stopLossPrice, positionId: nil, exitPrice: nil
        )

        return ProposedAction(
            capabilityId: id,
            summary: "Άνοιγμα paper θέσης σε \(asset)",
            reasoning: "Position sizing με \(Self.formatPercent(riskPercent)) ρίσκο του paper λογαριασμού ($\(Self.formatPrice(account.cashBalance))) και υποχρεωτικό stop-loss \(Self.formatPercent(PaperTradingConstants.stopLossPercent)) κάτω από την τιμή εισόδου. 100% προσομοίωση, καμία σύνδεση με πραγματικό λογαριασμό.",
            expectedImpact: "Θα ανοίξει paper θέση \(Self.formatQuantity(quantity)) \(asset) στα $\(Self.formatPrice(entryPrice)) (κόστος ~$\(Self.formatPrice(positionCost))), με stop-loss στα $\(Self.formatPrice(stopLossPrice)).",
            riskLevel: .medium,
            payload: Self.encode(payload)
        )
    }

    // MARK: - Close

    private func handleClose(decision: Decision) async throws -> CapabilityOutcome {
        guard let asset = decision.asset else {
            return .reply("Ποια θέση θέλεις να κλείσω;")
        }

        guard let position = persistence.openPaperPosition(for: asset) else {
            return .reply("Δεν βρήκα ανοιχτή paper θέση σε \(asset).")
        }

        let exitPrice = try await marketData.currentPrice(for: asset)
        let estimatedPnL = (exitPrice - position.entryPrice) * position.quantity
        let pnlDescription = estimatedPnL >= 0 ? "κέρδος" : "ζημιά"

        let payload = TradePayload(
            kind: "close", asset: asset, quantity: position.quantity,
            entryPrice: nil, stopLossPrice: nil, positionId: position.id, exitPrice: exitPrice
        )

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Κλείσιμο paper θέσης σε \(asset)",
            reasoning: "Κλείνει την υπάρχουσα paper θέση \(Self.formatQuantity(position.quantity)) \(asset), ανοιγμένη στα $\(Self.formatPrice(position.entryPrice)). 100% προσομοίωση, καμία σύνδεση με πραγματικό λογαριασμό.",
            expectedImpact: "Εκτιμώμενο \(pnlDescription) $\(Self.formatPrice(abs(estimatedPnL))) στην τιμή εξόδου $\(Self.formatPrice(exitPrice)).",
            riskLevel: .low,
            payload: Self.encode(payload)
        ))
    }

    // MARK: - Standing mandate consent

    /// Interprets the user's free-text reply via the AI (not a keyword
    /// match) — same pattern as `TextTaskCapability`'s file-save consent.
    private func resolveMandateConsent(reply: String, pending: PendingOpen) async throws -> CapabilityOutcome {
        pendingMandateRequest = nil

        let consentPrompt = """
        Ο χρήστης απάντησε: "\(reply)" σε ερώτηση αν δίνει άδεια στον TRAVIS να ανοίξει μια συγκεκριμένη paper trading θέση.
        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με τη λέξη yes ή no.
        """
        let raw = try await aiService.generateText(prompt: consentPrompt)
        guard raw.lowercased().contains("yes") else {
            return .reply("Εντάξει, δεν θα ανοίξω τη θέση.")
        }

        persistence.setPermission(Self.mandateKey(for: pending.asset), granted: true)
        return .proposal(try await makeOpenProposal(asset: pending.asset, riskPercent: pending.riskPercent))
    }

    // MARK: - Decision parsing

    private struct Decision {
        let kind: String
        let asset: String?
        let riskPercent: Double?
        let content: String
    }

    private static func parseDecision(from text: String) -> Decision? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let jsonStart = trimmed.firstIndex(of: "{"),
            let jsonEnd = trimmed.lastIndex(of: "}"),
            jsonStart < jsonEnd
        else { return nil }

        let jsonSubstring = trimmed[jsonStart...jsonEnd]

        guard
            let data = jsonSubstring.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? String,
            let content = object["content"] as? String
        else { return nil }

        let rawAsset = (object["asset"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let asset = (rawAsset?.isEmpty ?? true) ? nil : rawAsset

        return Decision(kind: kind, asset: asset, riskPercent: object["riskPercent"] as? Double, content: content)
    }

    // MARK: - Trade payload (encoded into ProposedAction.payload, decoded in resolve())

    private struct TradePayload: Codable {
        let kind: String
        let asset: String
        let quantity: Double
        let entryPrice: Double?
        let stopLossPrice: Double?
        let positionId: UUID?
        let exitPrice: Double?
    }

    private static func encode(_ payload: TradePayload) -> String? {
        (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Formatting

    private static func formatPrice(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatQuantity(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
