import Foundation

@MainActor
final class LocalDeliveryBundleCapability: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    let id = "local_delivery_bundle"
    let name = "Local Delivery Bundle"
    let capabilityDescription = "Creates a new delivery folder from an exact verified file set and writes a manifest, with one approval and no overwrite."
    let keywords = ["delivery folder", "delivery bundle", "package files", "prepare delivery", "φάκελο παράδοσης", "πακέτο αρχείων", "ετοίμασε παράδοση"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let locations: FileLocationService
    private let maxItems = 2_000

    init(locations: FileLocationService? = nil) {
        self.locations = locations ?? FileLocationService.shared
    }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .files,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly, .localMutation],
                permissionKeys: ["file_save"],
                requiresExplicitApproval: true,
                supportsBackgroundExecution: false,
                supportsProjectContext: true,
                timeoutSeconds: 120,
                maxAttempts: 1
            )
        )
    }

    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { true }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .medium }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_delivery_bundle capability χρειάζεται structured source, destination, bundle name και ακριβή verified filenames.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id, invocation.operation == "create_bundle" else {
            return .reply("Unsupported delivery-bundle operation.")
        }
        guard let sourcePath = invocation.arguments["sourcePath"],
              let destinationPath = invocation.arguments["destinationPath"],
              let bundleName = invocation.arguments["bundleName"],
              isSafeSimpleName(bundleName) else {
            return .reply("Χρειάζομαι ακριβή source/destination paths και ασφαλές bundle name.")
        }

        let names = invocation.arguments["names"]?.split(separator: "|").map(String.init).filter { !$0.isEmpty } ?? []
        guard !names.isEmpty, names.count <= maxItems, names.allSatisfy(isSafeSimpleName) else {
            return .reply("Χρειάζομαι 1–\(maxItems) ασφαλή verified filenames για το delivery bundle.")
        }
        guard let source = locations.resolveExistingPath(sourcePath),
              let destination = locations.resolveSaveDirectory(for: destinationPath) else {
            return .reply("Source ή destination δεν είναι διαθέσιμο μέσα στο εγκεκριμένο filesystem scope.")
        }
        defer { source.stopAccessing(); destination.stopAccessing() }

        let bundleURL = destination.url.appendingPathComponent(bundleName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            return .reply("Υπάρχει ήδη delivery folder: \(bundleURL.path). Δεν θα γίνει overwrite.")
        }

        var fingerprints: [Fingerprint] = []
        for name in names {
            let url = source.url.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return .reply("Το source file λείπει ή δεν είναι αρχείο: \(name)")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            fingerprints.append(Fingerprint(name: name, size: size, modified: modified))
        }

        let payload = Payload(
            sourcePath: source.url.path,
            destinationPath: destination.url.path,
            bundleName: bundleName,
            files: fingerprints
        )
        let encoded = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: encoded, encoding: .utf8) else {
            return .reply("Απέτυχε η προετοιμασία του delivery bundle.")
        }
        let preview = names.prefix(20).joined(separator: "\n")
        let more = names.count > 20 ? "\n… και άλλα \(names.count - 20)" : ""
        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Create delivery bundle \(bundleName)",
            reasoning: "Το bundle θα δημιουργηθεί από το ακριβές verified file set. Πριν το copy θα επανελεγχθούν size και modification time κάθε source file.",
            expectedImpact: "Θα δημιουργηθεί νέος φάκελος \(bundleURL.path) με \(names.count) αρχεία και TRAVIS_MANIFEST.txt. Δεν επιτρέπεται overwrite.\n\n\(preview)\(more)",
            riskLevel: .medium,
            payload: payloadText,
            filename: bundleName,
            location: destination.url.path
        ))
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payloadText = action.payload,
              let data = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.files.count <= maxItems,
              isSafeSimpleName(payload.bundleName),
              let source = locations.resolveExistingPath(payload.sourcePath),
              let destination = locations.resolveSaveDirectory(for: payload.destinationPath) else { return }
        defer { source.stopAccessing(); destination.stopAccessing() }

        let bundleURL = destination.url.appendingPathComponent(payload.bundleName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            onExecutionUpdate?("❌ Delivery bundle stopped: target folder already exists.")
            return
        }

        do {
            for fingerprint in payload.files {
                guard isSafeSimpleName(fingerprint.name) else { throw BundleError.sourceChanged(fingerprint.name) }
                let url = source.url.appendingPathComponent(fingerprint.name)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                guard size == fingerprint.size, abs(modified - fingerprint.modified) < 0.001 else {
                    throw BundleError.sourceChanged(fingerprint.name)
                }
            }

            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
            var created: [URL] = []
            do {
                for fingerprint in payload.files {
                    let src = source.url.appendingPathComponent(fingerprint.name)
                    let dst = bundleURL.appendingPathComponent(fingerprint.name)
                    try FileManager.default.copyItem(at: src, to: dst)
                    created.append(dst)
                }
                let manifest = makeManifest(payload: payload)
                let manifestURL = bundleURL.appendingPathComponent("TRAVIS_MANIFEST.txt")
                try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
                PersistenceService.shared.saveFile(filename: payload.bundleName, path: bundleURL.path, capabilityId: id)
                onExecutionUpdate?("✅ Delivery bundle created: \(bundleURL.path) — \(payload.files.count) files + manifest")
            } catch {
                try? FileManager.default.removeItem(at: bundleURL)
                throw error
            }
        } catch {
            onExecutionUpdate?("❌ Delivery bundle stopped safely: \(error.localizedDescription)")
        }
    }

    private struct Fingerprint: Codable {
        let name: String
        let size: Int64
        let modified: TimeInterval
    }

    private struct Payload: Codable {
        let sourcePath: String
        let destinationPath: String
        let bundleName: String
        let files: [Fingerprint]
    }

    private enum BundleError: LocalizedError {
        case sourceChanged(String)
        var errorDescription: String? {
            switch self {
            case .sourceChanged(let name): return "Το source file άλλαξε μετά το preview: \(name)."
            }
        }
    }

    private func makeManifest(payload: Payload) -> String {
        let rows = payload.files.map { "\($0.name) | \($0.size) bytes" }.joined(separator: "\n")
        return """
        TRAVIS DELIVERY MANIFEST

        Created: \(ISO8601DateFormatter().string(from: Date()))
        Source: \(payload.sourcePath)
        Files: \(payload.files.count)

        \(rows)
        """
    }

    private func isSafeSimpleName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("|")
    }
}
