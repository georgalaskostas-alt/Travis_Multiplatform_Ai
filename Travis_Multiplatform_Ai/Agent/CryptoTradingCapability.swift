import Foundation

/// Two trading modes, both non-live: `.paper` (default, 100% local
/// simulation, no API keys) and `.testnet` (real HMAC-signed orders
/// against Binance's SPOT TESTNET via `BinanceTestnetTradingService`,
/// using fictitious testnet-provided funds). Mode is resolved per
/// request from what the user actually said — see `Decision.mode` — and
/// defaults to `.paper` whenever testnet isn't explicitly mentioned.
/// There is no live mode anywhere in this file; that's a deliberate
/// future step requiring its own separate approval.
///
/// Standing mandates are mode-scoped (`"trading_paper_XRP"` vs.
/// `"trading_testnet_XRP"`, see `mandateKey`) — an existing paper
/// mandate for an asset never implicitly covers testnet for the same
/// asset, by construction: they're different `StandingPermission` keys,
/// so `handleOpen` always finds `hasMandate == false` the first time
/// testnet is requested for an asset, regardless of paper history.
///
/// Risk management (mandatory stop-loss, position sizing, daily-loss
/// circuit breaker) is identical in both modes — see `makeOpenProposal`
/// and `PersistenceService.todaysRealizedLoss()`, neither of which
/// branches on mode for the actual risk math, only for whether the
/// local paper cash balance gets touched.
///
/// `@MainActor` for the same reason as `TextTaskCapability`: it holds
/// mutable state (`pendingMandateRequest`) across separate `handle()`
/// calls while waiting for the user to answer the standing-mandate
/// consent question.
@MainActor
final class CryptoTradingCapability: AgentCapability {
    let id = "crypto_trading"
    let name = "Crypto Trading (Paper/Testnet)"
    let capabilityDescription = "Παρακολουθεί τιμές crypto μέσω του δημόσιου Binance API και προτείνει paper- ή testnet-trading ενέργειες (άνοιγμα/κλείσιμο θέσης) με υποχρεωτικό stop-loss και position sizing βάσει ρίσκου. Καμία σύνδεση με πραγματικό/live λογαριασμό σε καμία λειτουργία."
    let keywords: [String] = [
        "trading", "trade", "συναλλαγή", "crypto", "κρύπτο", "θέση",
        "xrp", "ripple", "solana", "sol", "bitcoin", "btc", "ethereum", "eth"
    ]
    private(set) var status: AgentCapabilityStatus = .idle

    /// Fired when a testnet order finishes executing (success or
    /// failure) — that happens asynchronously, after `resolve(_:)` has
    /// already returned, so it can't be conveyed through `handle()`'s
    /// return value like everything else. `TRAVISAppState` wires this to
    /// `addAssistantMessage`.
    var onTestnetExecutionUpdate: ((String) -> Void)?

    private let aiService: AIService
    private let marketData: BinanceMarketDataService
    private let testnetTrading: BinanceTestnetTradingService
    private let persistence: PersistenceService

    /// Standing-mandate keys are per (mode, asset) — see the type doc
    /// comment for why that's what makes point 4 of the testnet spec
    /// (never silently reuse a paper mandate for testnet) hold by
    /// construction rather than by an extra check.
    private static let mandateKeyPrefix = "trading_"
    private static func mandateKey(for asset: String, mode: TradingMode) -> String {
        "\(mandateKeyPrefix)\(mode.rawValue)_\(asset)"
    }

    /// Recovers `(mode, asset)` from a mandate key for display purposes
    /// (Settings' mandate list) — the inverse of `mandateKey(for:mode:)`.
    private static func parseMandateKey(_ key: String) -> (mode: TradingMode, asset: String)? {
        guard key.hasPrefix(mandateKeyPrefix) else { return nil }
        let remainder = key.dropFirst(mandateKeyPrefix.count)
        for mode in TradingMode.allCases {
            let modePrefix = "\(mode.rawValue)_"
            if remainder.hasPrefix(modePrefix) {
                return (mode, String(remainder.dropFirst(modePrefix.count)))
            }
        }
        return nil
    }

    /// A fully-priced-and-sized open request that's on hold waiting for
    /// the user to answer the standing-mandate consent question — either
    /// because this (asset, mode) pair has never been approved, or
    /// because this specific request is unusually risky even for an
    /// already-approved one (see `handleOpen`).
    private struct PendingOpen {
        let asset: String
        let riskPercent: Double
        let mode: TradingMode
    }
    private var pendingMandateRequest: PendingOpen?

    init(
        aiService: AIService = .shared,
        marketData: BinanceMarketDataService = .shared,
        testnetTrading: BinanceTestnetTradingService = .shared,
        persistence: PersistenceService = .shared
    ) {
        self.aiService = aiService
        self.marketData = marketData
        self.testnetTrading = testnetTrading
        self.persistence = persistence
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        if let pending = pendingMandateRequest {
            return try await resolveMandateConsent(reply: command, pending: pending, recentHistory: recentHistory)
        }

        status = .running
        defer { status = .idle }

        let historyBlock = recentHistory.isEmpty ? "" : """

        Πρόσφατο ιστορικό συνομιλίας (για context, ώστε να καταλαβαίνεις αναφορές όπως "αυτό", "σχετικά", "συνέχισε", ή σε ποιο asset αναφέρεσαι αν δεν το ξαναείπες):
        \(recentHistory.promptTranscript)

        """

        let prompt = """
        Είσαι ο προσωπικός βοηθός TRAVIS, σε λειτουργία crypto trading. Υπάρχουν δύο δυνατά modes, ΚΑΝΕΝΑ από τα δύο δεν αγγίζει πραγματικό/live λογαριασμό: "paper" (πλασματικά κεφάλαια, καθαρά τοπική προσομοίωση) και "testnet" (πραγματική εντολή στο Binance SPOT TESTNET, αλλά με πλασματικά κεφάλαια που δίνει το ίδιο το testnet). \(historyBlock)Ο χρήστης έγραψε τώρα: "\(command)"

        Απόφασε ποια από τις τέσσερις περιπτώσεις ισχύει:
        - "reply": ερώτηση ή συζήτηση για crypto, χωρίς ρητό αίτημα να ανοίξει ή να κλείσει θέση, και χωρίς να αφορά άδεια/mandate που έχει ήδη δοθεί. Αυτή είναι η προεπιλογή εκτός αν το αίτημα είναι ρητό.
        - "open": ρητό αίτημα να ανοίξει/κάνει trading σε ένα asset (π.χ. "κάνε trading στο XRP", "αγόρασε Solana στο testnet").
        - "close": ρητό αίτημα να κλείσει/πουλήσει μια υπάρχουσα θέση (π.χ. "πούλησε τη θέση μου σε Solana", "κλείσε το testnet XRP").
        - "mandate_status": ο χρήστης αναφέρεται ή ρωτάει για άδεια/mandate που έχει ήδη δώσει ή θέλει να επιβεβαιώσει (π.χ. "σου έδωσα ήδη άδεια", "τι άδειες έχεις;"), ΧΩΡΙΣ να είναι ρητό αίτημα νέου ανοίγματος/κλεισίματος θέσης.

        ΣΗΜΑΝΤΙΚΟ: Τα trading mandates αποθηκεύονται μόνιμα σε βάση δεδομένων, ανεξάρτητα από τη συνομιλία ή το session — ΠΟΤΕ μην απαντήσεις (στο "content") ότι δεν έχεις πρόσβαση σε προηγούμενες συνομιλίες/άδειες ή ότι "κάθε συνομιλία ξεκινά από μηδενική βάση". Αν η ερώτηση αφορά άδεια/mandate, χρησιμοποίησε ΠΑΝΤΑ "mandate_status" ώστε να ελεγχθεί το πραγματικό αποθηκευμένο state αντί να μαντέψεις.

        Αν αναφέρεται συγκεκριμένο crypto asset, βάλε το ticker του στο πεδίο "asset", κεφαλαία, χωρίς κατάληξη νομίσματος (π.χ. "XRP", "SOL", "BTC", "ETH" — όχι "XRPUSDT"). Αν δεν αναφέρεται κανένα asset, βάλε null.

        Αν ο χρήστης ανέφερε ΡΗΤΑ "testnet" (ή ισοδύναμο, π.χ. "δοκιμαστικό δίκτυο") για αυτή τη συγκεκριμένη ενέργεια, βάλε "testnet" στο πεδίο "mode". Αν δεν το ανέφερε ρητά, βάλε null — η προεπιλογή (paper) εφαρμόζεται αλλού, ΜΗΝ τη βάλεις εσύ σε αυτό το πεδίο.

        Αν ο χρήστης ανέφερε ρητά συγκεκριμένο ποσοστό ρίσκου για μια ΝΕΑ θέση (π.χ. "ρίσκαρε 3%"), βάλε τον αριθμό (π.χ. 3 για 3%) στο πεδίο "riskPercent". Αν δεν ανέφερε ρητά ποσοστό, βάλε null — ΜΗΝ υποθέσεις τιμή.

        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με ένα JSON object, χωρίς κανένα άλλο κείμενο: {"kind": "reply, open, close, ή mandate_status", "asset": "TICKER ή null", "mode": "testnet ή null", "riskPercent": αριθμός ή null, "content": "η απάντηση (αν reply) ή σύντομη περιγραφή της ενέργειας, στα ελληνικά (μπορεί να είναι κενό string αν kind είναι mandate_status)"}
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
        case "mandate_status":
            return handleMandateStatus(decision: decision)
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

        let mode = TradingMode(rawValue: trade.mode) ?? .paper

        switch trade.kind {
        case "open":
            guard let stopLossPrice = trade.stopLossPrice else { return }
            if mode == .testnet {
                executeTestnetOpen(trade: trade, stopLossPrice: stopLossPrice)
            } else {
                guard let entryPrice = trade.entryPrice else { return }
                persistence.openPaperPosition(
                    asset: trade.asset, quantity: trade.quantity, entryPrice: entryPrice, stopLossPrice: stopLossPrice, mode: .paper
                )
            }
        case "close":
            guard let positionId = trade.positionId else { return }
            if mode == .testnet {
                executeTestnetClose(trade: trade, positionId: positionId)
            } else {
                guard let exitPrice = trade.exitPrice else { return }
                persistence.closePaperPosition(id: positionId, exitPrice: exitPrice)
            }
        default:
            break
        }
    }

    // MARK: - Testnet execution (async, runs after resolve() returns)

    /// `resolve(_:)` is a synchronous, non-throwing protocol requirement
    /// (see `AgentCapability`) — it can't `await` the real network call a
    /// testnet order needs. This kicks off that call in its own Task and
    /// reports the outcome via `onTestnetExecutionUpdate` once it lands,
    /// rather than blocking or changing the protocol for every capability
    /// over what only this one mode of this one capability needs.
    private func executeTestnetOpen(trade: TradePayload, stopLossPrice: Double) {
        Task { @MainActor in
            do {
                let result = try await testnetTrading.placeMarketOrder(asset: trade.asset, side: .buy, quantity: trade.quantity)
                persistence.openPaperPosition(
                    asset: trade.asset, quantity: result.filledQuantity, entryPrice: result.filledPrice,
                    stopLossPrice: stopLossPrice, mode: .testnet
                )
                onTestnetExecutionUpdate?("Εκτελέστηκε στο Binance Testnet: αγορά \(Self.formatQuantity(result.filledQuantity)) \(trade.asset) στα $\(Self.formatPrice(result.filledPrice)).")
            } catch {
                onTestnetExecutionUpdate?("Απέτυχε η εντολή ανοίγματος στο Binance Testnet: \(error.localizedDescription)")
            }
        }
    }

    private func executeTestnetClose(trade: TradePayload, positionId: UUID) {
        Task { @MainActor in
            do {
                let result = try await testnetTrading.placeMarketOrder(asset: trade.asset, side: .sell, quantity: trade.quantity)
                persistence.closePaperPosition(id: positionId, exitPrice: result.filledPrice)
                onTestnetExecutionUpdate?("Εκτελέστηκε στο Binance Testnet: πώληση \(Self.formatQuantity(result.filledQuantity)) \(trade.asset) στα $\(Self.formatPrice(result.filledPrice)).")
            } catch {
                onTestnetExecutionUpdate?("Απέτυχε η εντολή κλεισίματος στο Binance Testnet: \(error.localizedDescription)")
            }
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

    // MARK: - Mandate status

    /// Ground-truth answer about standing mandates, pulled directly from
    /// `PersistenceService` — never left to the AI to guess or "remember"
    /// conversationally. Mode-aware: when the user didn't specify a mode
    /// for a given asset, both are reported explicitly rather than
    /// picking one, since a paper mandate never implies a testnet one.
    private func handleMandateStatus(decision: Decision) -> CapabilityOutcome {
        if let asset = decision.asset {
            if let mode = decision.mode {
                let granted = persistence.isPermissionGranted(Self.mandateKey(for: asset, mode: mode))
                return .reply(granted
                    ? "Ναι — υπάρχει ήδη ενεργό \(mode.title) trading mandate για \(asset), δεν χρειάζεται να ξαναδώσεις άδεια."
                    : "Δεν υπάρχει \(mode.title) mandate για \(asset) αυτή τη στιγμή. Θα σε ρωτήσω την επόμενη φορά που θα ζητήσω να ανοίξω \(mode.title) θέση σε αυτό.")
            }

            let paperGranted = persistence.isPermissionGranted(Self.mandateKey(for: asset, mode: .paper))
            let testnetGranted = persistence.isPermissionGranted(Self.mandateKey(for: asset, mode: .testnet))
            switch (paperGranted, testnetGranted) {
            case (true, true):
                return .reply("Για \(asset) έχεις ενεργό mandate και σε Paper και σε Testnet mode.")
            case (true, false):
                return .reply("Για \(asset) έχεις ενεργό mandate μόνο σε Paper mode — το Testnet χρειάζεται ξεχωριστή άδεια, ακόμα κι αν αφορά το ίδιο asset.")
            case (false, true):
                return .reply("Για \(asset) έχεις ενεργό mandate μόνο σε Testnet mode.")
            case (false, false):
                return .reply("Δεν υπάρχει mandate για \(asset) αυτή τη στιγμή, ούτε σε Paper ούτε σε Testnet mode.")
            }
        }

        let activeMandates = persistence.standingPermissions(withKeyPrefix: Self.mandateKeyPrefix).filter { $0.granted }
        guard !activeMandates.isEmpty else {
            return .reply("Δεν υπάρχει αυτή τη στιγμή κανένα ενεργό trading mandate.")
        }

        let descriptions = activeMandates.compactMap { mandate -> String? in
            guard let parsed = Self.parseMandateKey(mandate.key) else { return nil }
            return "\(parsed.asset) (\(parsed.mode.title))"
        }
        return .reply("Αυτή τη στιγμή έχεις ενεργό trading mandate για: \(descriptions.joined(separator: ", ")).")
    }

    // MARK: - Open

    private func handleOpen(decision: Decision) async throws -> CapabilityOutcome {
        guard let asset = decision.asset else {
            return .reply("Σε ποιο crypto asset θέλεις να κάνω trading;")
        }

        let mode = decision.mode ?? .paper

        guard !persistence.isTradingFrozenToday() else {
            return .reply("Το trading είναι παγωμένο για σήμερα — ξεπεράστηκε το ημερήσιο όριο ζημιάς (paper + testnet συνδυαστικά). Το κλείσιμο υπαρχουσών θέσεων εξακολουθεί να είναι διαθέσιμο.")
        }

        if mode == .testnet {
            let hasCredentials = !(KeychainService.shared.binanceTestnetAPIKey ?? "").isEmpty
                && !(KeychainService.shared.binanceTestnetAPISecret ?? "").isEmpty
            guard hasCredentials else {
                return .reply("Για testnet trading χρειάζομαι το Binance Testnet API Key και Secret — πρόσθεσέ τα στις Ρυθμίσεις.")
            }
        }

        let requestedRiskPercent = decision.riskPercent.map { $0 / 100 } ?? PaperTradingConstants.defaultRiskPercent
        let isUnusual = requestedRiskPercent > PaperTradingConstants.defaultRiskPercent
        let riskPercent = min(requestedRiskPercent, PaperTradingConstants.maxRiskPercent)

        let hasMandate = persistence.isPermissionGranted(Self.mandateKey(for: asset, mode: mode))

        guard hasMandate, !isUnusual else {
            pendingMandateRequest = PendingOpen(asset: asset, riskPercent: riskPercent, mode: mode)
            let reason = hasMandate
                ? "Αυτή η ενέργεια ζητάει μεγαλύτερο ρίσκο από το συνηθισμένο."
                : "Δεν έχω ακόμα άδεια για \(mode.title) trading σε \(asset)."
            return .reply("\(reason) Μου δίνεις άδεια να ανοίξω \(mode.title) θέση σε \(asset) με ρίσκο \(Self.formatPercent(riskPercent)) του λογαριασμού;")
        }

        return .proposal(try await makeOpenProposal(asset: asset, riskPercent: riskPercent, mode: mode))
    }

    /// Fetches a fresh price, computes mandatory stop-loss + risk-based
    /// position size, and builds the approval card. Always called right
    /// before proposing — never from a stale cached price. Sizing math
    /// is identical for both modes and is always computed against the
    /// local paper account's cash balance — even for testnet — as a
    /// stable, predictable risk budget, rather than depending on
    /// whatever amount Binance's testnet faucet happens to have granted.
    /// For testnet, `entryPrice` here is only an estimate shown in the
    /// proposal; the real fill price comes back from
    /// `executeTestnetOpen` after Approve and is what actually gets
    /// persisted.
    private func makeOpenProposal(asset: String, riskPercent: Double, mode: TradingMode) async throws -> ProposedAction {
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
            kind: "open", asset: asset, mode: mode.rawValue, quantity: quantity,
            entryPrice: entryPrice, stopLossPrice: stopLossPrice, positionId: nil, exitPrice: nil
        )

        let modeExplanation = mode == .testnet
            ? "Με το Approve θα σταλεί ΠΡΑΓΜΑΤΙΚΗ, υπογεγραμμένη εντολή MARKET στο Binance SPOT TESTNET (testnet.binance.vision) — τα κεφάλαια είναι πλασματικά (δίνονται από το ίδιο το testnet), αλλά η εκτέλεση είναι πραγματική. Η τελική τιμή/ποσότητα εκτέλεσης μπορεί να διαφέρει ελαφρώς από την παρακάτω εκτίμηση."
            : "100% τοπική προσομοίωση, καμία σύνδεση με πραγματικό ή testnet λογαριασμό."

        return ProposedAction(
            capabilityId: id,
            summary: "Άνοιγμα \(mode.title) θέσης σε \(asset)",
            reasoning: "Position sizing με \(Self.formatPercent(riskPercent)) ρίσκο του λογαριασμού αναφοράς ($\(Self.formatPrice(account.cashBalance))) και υποχρεωτικό stop-loss \(Self.formatPercent(PaperTradingConstants.stopLossPercent)) κάτω από την τιμή εισόδου. \(modeExplanation)",
            expectedImpact: "Θα ανοίξει \(mode.title) θέση ~\(Self.formatQuantity(quantity)) \(asset) στα ~$\(Self.formatPrice(entryPrice)) (κόστος ~$\(Self.formatPrice(positionCost))), με stop-loss στα ~$\(Self.formatPrice(stopLossPrice)).",
            riskLevel: mode == .testnet ? .high : .medium,
            payload: Self.encode(payload)
        )
    }

    // MARK: - Close

    private func handleClose(decision: Decision) async throws -> CapabilityOutcome {
        guard let asset = decision.asset else {
            return .reply("Ποια θέση θέλεις να κλείσω;")
        }

        let mode = decision.mode ?? .paper

        guard let position = persistence.openPaperPosition(for: asset, mode: mode) else {
            return .reply("Δεν βρήκα ανοιχτή \(mode.title) θέση σε \(asset).")
        }

        let exitPrice = try await marketData.currentPrice(for: asset)
        let estimatedPnL = (exitPrice - position.entryPrice) * position.quantity
        let pnlDescription = estimatedPnL >= 0 ? "κέρδος" : "ζημιά"

        let payload = TradePayload(
            kind: "close", asset: asset, mode: mode.rawValue, quantity: position.quantity,
            entryPrice: nil, stopLossPrice: nil, positionId: position.id, exitPrice: exitPrice
        )

        let modeExplanation = mode == .testnet
            ? "Με το Approve θα σταλεί ΠΡΑΓΜΑΤΙΚΗ, υπογεγραμμένη εντολή MARKET πώλησης στο Binance SPOT TESTNET — η τελική τιμή εξόδου μπορεί να διαφέρει ελαφρώς από την παρακάτω εκτίμηση."
            : "100% τοπική προσομοίωση, καμία σύνδεση με πραγματικό ή testnet λογαριασμό."

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Κλείσιμο \(mode.title) θέσης σε \(asset)",
            reasoning: "Κλείνει την υπάρχουσα \(mode.title) θέση \(Self.formatQuantity(position.quantity)) \(asset), ανοιγμένη στα $\(Self.formatPrice(position.entryPrice)). \(modeExplanation)",
            expectedImpact: "Εκτιμώμενο \(pnlDescription) ~$\(Self.formatPrice(abs(estimatedPnL))) στην τιμή εξόδου ~$\(Self.formatPrice(exitPrice)).",
            riskLevel: mode == .testnet ? .high : .low,
            payload: Self.encode(payload)
        ))
    }

    // MARK: - Standing mandate consent

    /// Interprets the user's free-text reply via the AI (not a keyword
    /// match) — same pattern as `TextTaskCapability`'s file-save consent.
    private func resolveMandateConsent(reply: String, pending: PendingOpen, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        pendingMandateRequest = nil

        let historyBlock = recentHistory.isEmpty ? "" : """
        Πρόσφατο ιστορικό συνομιλίας (για context):
        \(recentHistory.promptTranscript)

        """

        let consentPrompt = """
        \(historyBlock)Ο χρήστης απάντησε: "\(reply)" σε ερώτηση αν δίνει άδεια στον TRAVIS να ανοίξει μια συγκεκριμένη \(pending.mode.title) trading θέση.
        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με τη λέξη yes ή no.
        """
        let raw = try await aiService.generateText(prompt: consentPrompt)
        guard raw.lowercased().contains("yes") else {
            return .reply("Εντάξει, δεν θα ανοίξω τη θέση.")
        }

        persistence.setPermission(Self.mandateKey(for: pending.asset, mode: pending.mode), granted: true)
        return .proposal(try await makeOpenProposal(asset: pending.asset, riskPercent: pending.riskPercent, mode: pending.mode))
    }

    // MARK: - Decision parsing

    private struct Decision {
        let kind: String
        let asset: String?
        let riskPercent: Double?
        let mode: TradingMode?
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

        let rawMode = (object["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mode = rawMode.flatMap { TradingMode(rawValue: $0) }

        return Decision(kind: kind, asset: asset, riskPercent: object["riskPercent"] as? Double, mode: mode, content: content)
    }

    // MARK: - Trade payload (encoded into ProposedAction.payload, decoded in resolve())

    private struct TradePayload: Codable {
        let kind: String
        let asset: String
        let mode: String
        let quantity: Double
        let entryPrice: Double?
        let stopLossPrice: Double?
        let positionId: UUID?
        let exitPrice: Double?

        init(kind: String, asset: String, mode: String, quantity: Double, entryPrice: Double?, stopLossPrice: Double?, positionId: UUID?, exitPrice: Double?) {
            self.kind = kind
            self.asset = asset
            self.mode = mode
            self.quantity = quantity
            self.entryPrice = entryPrice
            self.stopLossPrice = stopLossPrice
            self.positionId = positionId
            self.exitPrice = exitPrice
        }

        // Custom decoding so a pending proposal encoded before `mode`
        // existed (i.e. created moments before this update shipped)
        // still decodes as .paper instead of silently failing to
        // execute on Approve.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            asset = try container.decode(String.self, forKey: .asset)
            mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? TradingMode.paper.rawValue
            quantity = try container.decode(Double.self, forKey: .quantity)
            entryPrice = try container.decodeIfPresent(Double.self, forKey: .entryPrice)
            stopLossPrice = try container.decodeIfPresent(Double.self, forKey: .stopLossPrice)
            positionId = try container.decodeIfPresent(UUID.self, forKey: .positionId)
            exitPrice = try container.decodeIfPresent(Double.self, forKey: .exitPrice)
        }
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
