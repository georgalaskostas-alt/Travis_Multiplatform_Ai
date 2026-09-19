import Foundation

/// Persistent idempotency ledger for Control Plane commands.
///
/// The store is transport-independent: LAN, Cloud, retries and reconnects
/// must all claim a command here before any side effect is executed.
actor TravisControlCommandReceiptStore {

    static let shared = TravisControlCommandReceiptStore()

    enum ReceiptStatus: String, Codable, Sendable {
        case executing
        case completed
        case failed
        case expired
    }

    struct Receipt: Codable, Sendable {
        let commandID: UUID
        let nonce: UUID
        let commandType: String
        let sourceDeviceID: UUID?
        let payload: [String: String]
        let firstSeenAt: Date
        var updatedAt: Date
        var status: ReceiptStatus
        var resultStatus: TravisControlCommandStatus?
        var resultMessage: String?
    }

    enum Claim: Sendable {
        case execute
        case duplicate(Receipt)
        case conflict(Receipt)
    }

    private struct Ledger: Codable {
        var receipts: [String: Receipt] = [:]
    }

    enum ReceiptStoreError: LocalizedError {
        case initializationFailed(String)

        var errorDescription: String? {
            switch self {
            case .initializationFailed(let message):
                return "Control Plane receipt store unavailable: \(message)"
            }
        }
    }

    private let fileManager: FileManager
    private let ledgerURL: URL
    private var ledger: Ledger
    private var initializationError: Error?

    init(
        fileManager: FileManager = .default,
        ledgerURL overrideLedgerURL: URL? = nil
    ) {
        self.fileManager = fileManager

        if let overrideLedgerURL {
            let directory = overrideLedgerURL.deletingLastPathComponent()

            self.ledgerURL = overrideLedgerURL
            self.ledger = Ledger()
            self.initializationError = nil

            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )

                if fileManager.fileExists(atPath: overrideLedgerURL.path) {
                    let data = try Data(contentsOf: overrideLedgerURL)
                    self.ledger = try JSONDecoder().decode(
                        Ledger.self,
                        from: data
                    )
                }
            } catch {
                self.initializationError = ReceiptStoreError
                    .initializationFailed(error.localizedDescription)
            }

            return
        }

        #if os(macOS)
        let homeDirectory: URL

        if let passwd = getpwuid(getuid()),
           let home = passwd.pointee.pw_dir {
            homeDirectory = URL(
                fileURLWithPath: String(cString: home),
                isDirectory: true
            )
        } else {
            homeDirectory = fileManager.homeDirectoryForCurrentUser
        }

        let base = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        #else
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        #endif

        let directory = base
            .appendingPathComponent("TRAVIS", isDirectory: true)
            .appendingPathComponent("ControlPlane", isDirectory: true)

        self.ledgerURL = directory
            .appendingPathComponent("command-receipts-v1.json")
        self.ledger = Ledger()
        self.initializationError = nil

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: self.ledgerURL.path) {
                let data = try Data(contentsOf: self.ledgerURL)
                self.ledger = try JSONDecoder().decode(
                    Ledger.self,
                    from: data
                )
            }
        } catch {
            self.initializationError = ReceiptStoreError
                .initializationFailed(error.localizedDescription)
        }
    }

    static func canonicalCommandType(_ rawValue: String) -> String {
        switch rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {

        case "killswitch",
             "kill_switch",
             "kill_switch.enable",
             "kill_switch.disable":
            return "killSwitch"

        case "pausetask", "pause_task":
            return "pauseTask"

        case "resumetask", "resume_task":
            return "resumeTask"

        case "canceltask", "cancel_task":
            return "cancelTask"

        case "deletetask", "delete_task":
            return "deleteTask"

        case "deletefinished", "delete_finished":
            return "deleteFinished"

        case "requeststatus", "request_status":
            return "requestStatus"

        case "mission":
            return "mission"

        case "worker_job", "workerjob":
            return "worker_job"

        default:
            return rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func claim(
        commandID: UUID,
        nonce: UUID,
        commandType: String,
        sourceDeviceID: UUID?,
        payload: [String: String]
    ) throws -> Claim {
        if let initializationError {
            throw initializationError
        }

        let key = commandID.uuidString.lowercased()
        let canonicalType = Self.canonicalCommandType(commandType)

        if let existing = ledger.receipts[key] {
            // sourceDeviceID is audit/transport metadata, not part of
            // logical command identity. LAN records the originating device,
            // while Cloud addresses a target device.
            guard existing.nonce == nonce,
                  Self.canonicalCommandType(existing.commandType) == canonicalType,
                  existing.payload == payload else {
                return .conflict(existing)
            }

            return .duplicate(existing)
        }

        let now = Date()

        ledger.receipts[key] = Receipt(
            commandID: commandID,
            nonce: nonce,
            commandType: canonicalType,
            sourceDeviceID: sourceDeviceID,
            payload: payload,
            firstSeenAt: now,
            updatedAt: now,
            status: .executing,
            resultStatus: nil,
            resultMessage: nil
        )

        do {
            try persist()
        } catch {
            // The claim was never durably recorded, so restore RAM to
            // the same state as disk before propagating the failure.
            ledger.receipts.removeValue(forKey: key)
            throw error
        }

        return .execute
    }

    func finish(
        commandID: UUID,
        status: TravisControlCommandStatus,
        message: String
    ) throws {
        if let initializationError {
            throw initializationError
        }

        let key = commandID.uuidString.lowercased()

        guard var receipt = ledger.receipts[key] else {
            return
        }

        receipt.updatedAt = Date()
        receipt.resultStatus = status
        receipt.resultMessage = message

        switch status {
        case .completed:
            receipt.status = .completed

        case .expired:
            receipt.status = .expired

        case .failed:
            receipt.status = .failed

        case .queued, .acknowledged, .executing:
            receipt.status = .executing
        }

        let previousReceipt = ledger.receipts[key]
        ledger.receipts[key] = receipt

        do {
            try persist()
        } catch {
            // Terminal state was not durably committed. Restore the
            // previously durable in-memory representation.
            if let previousReceipt {
                ledger.receipts[key] = previousReceipt
            } else {
                ledger.receipts.removeValue(forKey: key)
            }

            throw error
        }
    }

    func receipt(for commandID: UUID) -> Receipt? {
        ledger.receipts[commandID.uuidString.lowercased()]
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(ledger)

        try data.write(
            to: ledgerURL,
            options: [.atomic]
        )
    }
}
