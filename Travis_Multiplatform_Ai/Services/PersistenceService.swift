import Foundation
import SwiftData

/// SwiftData persistence, synced across the user's devices via CloudKit
/// (private database, `.automatic` — picks up the container from the
/// `com.apple.developer.icloud-container-identifiers` entitlement, added
/// separately via Xcode's Signing & Capabilities). Explicitly NOT synced:
/// the Anthropic API key, which lives in `KeychainService` and was never
/// a SwiftData model — each device keeps its own.
///
/// CloudKit-backed SwiftData forbids two things plain SwiftData allows,
/// which is why every `@Model` here looks slightly different from a
/// typical local-only one: no `@Attribute(.unique)` (CloudKit has no
/// schema-level uniqueness constraint), and every non-optional property
/// needs an inline default value (so a partially-materialized CloudKit
/// record still has something valid to show). See the doc comment on any
/// of the `Persisted*`/`StandingPermission` models for the specifics.
@MainActor
final class PersistenceService {
    static let shared = PersistenceService()

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    private init() {
        do {
            container = try Self.makeContainer()
        } catch {
            // ⚠️ DEVELOPMENT-ONLY SAFETY NET — DO NOT SHIP THIS TO PRODUCTION. ⚠️
            //
            // The SwiftData schema here has already changed several times
            // (e.g. adding `sessionId`, adding the whole StandingPermission
            // model) with no SchemaMigrationPlan, so an on-device store
            // created under an older schema fails to load instead of
            // migrating (SwiftDataError.loadIssueModelContainer). While
            // there's no real user data at stake yet, wiping the local
            // store on load failure and retrying once is an acceptable way
            // to keep development unblocked instead of crashing outright.
            //
            // This MUST be replaced with a real, versioned
            // SchemaMigrationPlan before any production/App Store use —
            // left as-is, every future schema change will silently destroy
            // real users' chat history, permissions, and bookmarks.
            //
            // CloudKit caveat: this only wipes the LOCAL mirror. If the
            // failure is actually caused by incompatible records already
            // sitting in the CloudKit private database (e.g. from before
            // this schema changed), the retry can re-download the same
            // bad data and fail again — there's no client-side API to
            // reset the CloudKit side, that needs the CloudKit Dashboard.
            Self.deleteDefaultStore()
            do {
                container = try Self.makeContainer()
            } catch {
                fatalError("Δεν ήταν δυνατή η αρχικοποίηση του SwiftData ModelContainer, ακόμα και μετά τον καθαρισμό του τοπικού store: \(error)")
            }
        }

        deduplicateSingletonModels()
    }

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            PersistedChatMessage.self, PersistedProposedAction.self, PersistedFile.self, PersistedLocationBookmark.self,
            StandingPermission.self, PersistedPaperAccount.self, PersistedPaperPosition.self
        ])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Losing `@Attribute(.unique)` (required for CloudKit, see the type
    /// doc comment) means two devices can each create their own row for
    /// what's meant to be a single logical entry — e.g. both opening the
    /// app offline before ever syncing, each creating their own
    /// "paper_account". CloudKit has no idea these should be the same
    /// record, so both survive the sync as separate rows. Run once per
    /// launch, right after the store opens: for each of the three
    /// singleton-by-key models, keep only the most recently modified row
    /// per key and silently delete the rest. No UI, no user-visible
    /// conflict — the existing last-writer-wins merge policy already
    /// covers conflicting edits *within* one row; this only cleans up
    /// rows that should never have been duplicated in the first place.
    private func deduplicateSingletonModels() {
        deduplicateStandingPermissions()
        deduplicateLocationBookmarks()
        deduplicatePaperAccounts()
        try? context.save()
    }

    private func deduplicateStandingPermissions() {
        let all = (try? context.fetch(FetchDescriptor<StandingPermission>())) ?? []
        for (_, duplicates) in Dictionary(grouping: all, by: \.key) where duplicates.count > 1 {
            for stale in duplicates.sorted(by: { $0.grantedAt > $1.grantedAt }).dropFirst() {
                context.delete(stale)
            }
        }
    }

    private func deduplicateLocationBookmarks() {
        let all = (try? context.fetch(FetchDescriptor<PersistedLocationBookmark>())) ?? []
        for (_, duplicates) in Dictionary(grouping: all, by: \.locationKey) where duplicates.count > 1 {
            for stale in duplicates.sorted(by: { $0.createdAt > $1.createdAt }).dropFirst() {
                context.delete(stale)
            }
        }
    }

    private func deduplicatePaperAccounts() {
        let all = (try? context.fetch(FetchDescriptor<PersistedPaperAccount>())) ?? []
        for (_, duplicates) in Dictionary(grouping: all, by: \.id) where duplicates.count > 1 {
            for stale in duplicates.sorted(by: { $0.lastModifiedAt > $1.lastModifiedAt }).dropFirst() {
                context.delete(stale)
            }
        }
    }

    /// Deletes SwiftData's default on-disk store (plus its WAL/SHM
    /// sidecar files) so a fresh, schema-compatible one can be created on
    /// retry. Temporary development-only recovery path — see the warning
    /// in `init()`.
    private static func deleteDefaultStore() {
        guard let supportDirectory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }

        let storeURL = supportDirectory.appendingPathComponent("default.store")
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    // MARK: - Chat messages

    func loadChatMessages() -> [ChatMessage] {
        let descriptor = FetchDescriptor<PersistedChatMessage>(sortBy: [SortDescriptor(\.createdAt)])
        let stored = (try? context.fetch(descriptor)) ?? []
        return stored.map(\.asChatMessage)
    }

    func saveChatMessage(_ message: ChatMessage) {
        context.insert(PersistedChatMessage(id: message.id, role: message.role, text: message.text, createdAt: message.createdAt, sessionId: message.sessionId))
        try? context.save()
    }

    /// Groups all persisted messages by `sessionId`, most recently started
    /// first — the basis for both the "Ιστορικό" list and
    /// `SessionRecallService`'s date-based lookup.
    func loadChatSessions() -> [ChatSession] {
        let grouped = Dictionary(grouping: loadChatMessages(), by: \.sessionId)
        return grouped
            .map { ChatSession(id: $0.key, messages: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Proposed actions

    func loadProposedActions() -> (pending: [ProposedAction], history: [ProposedAction]) {
        let descriptor = FetchDescriptor<PersistedProposedAction>(sortBy: [SortDescriptor(\.createdAt)])
        let actions = ((try? context.fetch(descriptor)) ?? []).map(\.asProposedAction)
        return (actions.filter { $0.status == .pending }, actions.filter { $0.status != .pending })
    }

    func saveProposedAction(_ action: ProposedAction) {
        context.insert(PersistedProposedAction(from: action))
        try? context.save()
    }

    func updateProposedAction(_ action: ProposedAction) {
        let targetId = action.id
        let descriptor = FetchDescriptor<PersistedProposedAction>(
            predicate: #Predicate { $0.id == targetId }
        )

        guard let existing = try? context.fetch(descriptor).first else { return }
        existing.apply(action)
        try? context.save()
    }

    // MARK: - Files

    func loadFiles() -> [PersistedFile] {
        let descriptor = FetchDescriptor<PersistedFile>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fileExists(named filename: String) -> Bool {
        loadFiles().contains { $0.filename.caseInsensitiveCompare(filename) == .orderedSame }
    }

    func saveFile(filename: String, path: String, capabilityId: String) {
        context.insert(PersistedFile(filename: filename, path: path, capabilityId: capabilityId))
        try? context.save()
    }

    // MARK: - Location bookmarks

    func loadLocationBookmark(for key: String) -> Data? {
        let descriptor = FetchDescriptor<PersistedLocationBookmark>(
            predicate: #Predicate { $0.locationKey == key }
        )
        return (try? context.fetch(descriptor).first)?.bookmarkData
    }

    func saveLocationBookmark(key: String, data: Data) {
        if let existing = try? context.fetch(FetchDescriptor<PersistedLocationBookmark>(
            predicate: #Predicate { $0.locationKey == key }
        )).first {
            existing.bookmarkData = data
            existing.createdAt = Date()
        } else {
            context.insert(PersistedLocationBookmark(locationKey: key, bookmarkData: data))
        }
        try? context.save()
    }

    // MARK: - Standing permissions

    /// Generic "granted until revoked" gate, reusable for any future
    /// standing mandate (e.g. trading) beyond today's file-save permission.
    func isPermissionGranted(_ key: String) -> Bool {
        let descriptor = FetchDescriptor<StandingPermission>(predicate: #Predicate { $0.key == key })
        return (try? context.fetch(descriptor).first)?.granted ?? false
    }

    func setPermission(_ key: String, granted: Bool) {
        let descriptor = FetchDescriptor<StandingPermission>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.granted = granted
            existing.grantedAt = Date()
        } else {
            context.insert(StandingPermission(key: key, granted: granted))
        }
        try? context.save()
    }

    /// All standing permissions whose key starts with `prefix` — e.g.
    /// `"trading_"` for the crypto trading mandates list in Settings.
    func standingPermissions(withKeyPrefix prefix: String) -> [StandingPermission] {
        let descriptor = FetchDescriptor<StandingPermission>(sortBy: [SortDescriptor(\.grantedAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.key.hasPrefix(prefix) }
    }

    // MARK: - Paper trading

    /// Fetches (or creates, on first use) the single paper-account row.
    /// Purely simulated — never touches a real exchange balance.
    func paperAccount() -> PersistedPaperAccount {
        let accountId = "paper_account"
        let descriptor = FetchDescriptor<PersistedPaperAccount>(predicate: #Predicate { $0.id == accountId })
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let created = PersistedPaperAccount(id: accountId, cashBalance: PaperTradingConstants.startingBalance)
        context.insert(created)
        try? context.save()
        return created
    }

    @discardableResult
    func openPaperPosition(asset: String, quantity: Double, entryPrice: Double, stopLossPrice: Double) -> PersistedPaperPosition {
        let account = paperAccount()
        account.cashBalance -= quantity * entryPrice
        account.lastModifiedAt = Date()

        let position = PersistedPaperPosition(asset: asset, quantity: quantity, entryPrice: entryPrice, stopLossPrice: stopLossPrice)
        context.insert(position)
        try? context.save()
        return position
    }

    @discardableResult
    func closePaperPosition(id: UUID, exitPrice: Double) -> Double? {
        let descriptor = FetchDescriptor<PersistedPaperPosition>(predicate: #Predicate { $0.id == id })
        guard let position = try? context.fetch(descriptor).first, position.closedAt == nil else { return nil }

        let realizedPnL = (exitPrice - position.entryPrice) * position.quantity
        position.closedAt = Date()
        position.exitPrice = exitPrice
        position.realizedPnL = realizedPnL

        let account = paperAccount()
        account.cashBalance += position.quantity * exitPrice
        account.lastModifiedAt = Date()
        try? context.save()
        return realizedPnL
    }

    /// The single open position for `asset`, if any — used to resolve
    /// "close my position in X" requests.
    func openPaperPosition(for asset: String) -> PersistedPaperPosition? {
        let descriptor = FetchDescriptor<PersistedPaperPosition>(
            predicate: #Predicate { $0.asset == asset && $0.closedAt == nil }
        )
        return try? context.fetch(descriptor).first
    }

    /// Sum (as a positive magnitude) of today's realized paper losses —
    /// the basis for the daily loss-limit freeze.
    func todaysRealizedLoss() -> Double {
        let descriptor = FetchDescriptor<PersistedPaperPosition>(predicate: #Predicate { $0.closedAt != nil })
        let closedPositions = (try? context.fetch(descriptor)) ?? []
        let startOfDay = Calendar.current.startOfDay(for: Date())

        let todaysLosses = closedPositions.compactMap { position -> Double? in
            guard let closedAt = position.closedAt, closedAt >= startOfDay, let pnl = position.realizedPnL, pnl < 0 else {
                return nil
            }
            return pnl
        }

        return todaysLosses.reduce(0) { $0 + abs($1) }
    }

    func isTradingFrozenToday() -> Bool {
        todaysRealizedLoss() >= PaperTradingConstants.dailyLossLimit
    }
}
