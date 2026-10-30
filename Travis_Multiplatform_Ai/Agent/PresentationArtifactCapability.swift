import Foundation

/// V6 presentation capability. The model proposes data in a constrained manifest;
/// local deterministic code renders Markdown/HTML/SVG. No model-generated executable
/// UI code, JavaScript, remote resources or arbitrary HTML is persisted.
@MainActor
final class PresentationArtifactCapability: AgentCapability {
    let id = "presentation_artifact"
    let name = "Presentation & Visualization"
    let capabilityDescription = "Creates polished charts, dashboards and reports through a safe declarative manifest rendered locally to SVG/HTML/Markdown; save is approval-gated and overwrite is blocked."
    let keywords = ["γράφημα", "γραφημα", "chart", "dashboard", "infographic", "οπτικοποίηση", "οπτικοποιηση", "visualize", "παρουσίασε γραφικά", "presentation artifact", "svg", "html report"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let aiService: AIService
    private let locations: FileLocationService

    init(aiService: AIService = .shared, locations: FileLocationService = .shared) {
        self.aiService = aiService
        self.locations = locations
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
                timeoutSeconds: 180,
                maxAttempts: 2
            ),
            version: 3,
            inputSchema: [
                "request": "visualization/report goal grounded in available evidence",
                "format": "optional svg|html|md"
            ],
            outputKinds: [.chart, .table, .dashboard, .document, .file],
            costClass: .cloudReasoning,
            deterministicWhenStructured: true,
            freshnessSensitive: false
        )
    }

    private struct ModelEnvelope: Codable {
        var format: String
        var manifest: ArtifactManifestV6
    }

    private struct Payload: Codable {
        var filename: String
        var location: String?
        var content: String
        var format: String
        var manifest: ArtifactManifestV6
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        let request = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return .reply("Πες μου τι visualization/report θέλεις να δημιουργήσω.") }

        let prompt = """
        You are TRAVIS Presentation Planner V6. Build a DECLARATIVE artifact manifest only; local deterministic code will render it.

        Return JSON only with this shape:
        {
          "format":"html|svg|md",
          "manifest":{
            "version":1,
            "kind":"report|dashboard|chart|table",
            "title":"...",
            "subtitle":"optional",
            "sections":[
              {"kind":"text","title":"...","text":"..."},
              {"kind":"metrics","title":"...","metrics":[{"label":"...","value":"...","note":"optional"}]},
              {"kind":"table","title":"...","headers":["..."],"rows":[["..."]]},
              {"kind":"barChart","title":"...","bars":[{"label":"...","value":1.0,"displayValue":"optional"}]}
            ],
            "footer":"optional"
          }
        }

        RULES
        - Use only facts and numbers present in REQUEST or CONTEXT. Never fabricate measurements.
        - If exact numeric data is absent, prefer text/metrics/table explanation instead of invented chart values.
        - SVG format requires at least one barChart section.
        - Keep the result compact: <=24 sections, <=200 table rows, <=40 bars per chart.
        - Do not output HTML, SVG, Markdown, JavaScript, URLs, CSS or Swift. Only the JSON manifest above.
        - Preserve the user's language unless they request another language.

        REQUEST
        \(request)

        RECENT RELEVANT CONTEXT
        \(recentHistory.suffix(5).promptTranscript.prefix(14_000))
        """

        let context = AIInvocationContext(workload: .complex, capabilityId: id, operation: "presentation.manifest")
        let packet = CognitiveCoreV6.shared.prepareRemotePrompt(prompt, context: context)
        let raw = try await aiService.generateText(prompt: packet.prompt, maxTokens: 6_000, context: context)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else {
            return .reply("Το presentation manifest απορρίφθηκε επειδή δεν ήταν έγκυρο JSON.")
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8), let envelope = try? JSONDecoder().decode(ModelEnvelope.self, from: data) else {
            return .reply("Το presentation manifest απορρίφθηκε επειδή δεν ταίριαζε στο ασφαλές schema.")
        }
        guard let format = DeclarativeArtifactEngineV6.RenderFormat(rawValue: envelope.format.lowercased()) else {
            return .reply("Το presentation manifest ζήτησε μη υποστηριζόμενο format.")
        }

        let content: String
        do {
            content = try DeclarativeArtifactEngineV6.render(envelope.manifest, as: format)
        } catch {
            return .reply("Το presentation manifest απορρίφθηκε από deterministic validation: \(error.localizedDescription)")
        }
        guard content.utf8.count <= 5_000_000 else {
            return .reply("Το rendered visual artifact ξεπέρασε το ασφαλές όριο μεγέθους και δεν θα αποθηκευτεί.")
        }

        let filename = DeclarativeArtifactEngineV6.suggestedFilename(for: envelope.manifest, format: format)
        let payload = Payload(filename: filename, location: nil, content: content, format: format.rawValue, manifest: envelope.manifest)
        let encoded = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: encoded, encoding: .utf8) else { return .none }

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Create declarative visual artifact \(filename)",
            reasoning: "Το μοντέλο παρήγαγε μόνο structured manifest. Το τελικό artifact αποδόθηκε τοπικά από deterministic renderer και πέρασε schema/size validation.",
            expectedImpact: "Θα δημιουργηθεί νέο self-contained \(format.rawValue.uppercased()) artifact χωρίς overwrite και χωρίς executable content.",
            riskLevel: .medium,
            payload: payloadText,
            filename: filename,
            location: nil
        ))
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let text = action.payload,
              let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let format = DeclarativeArtifactEngineV6.RenderFormat(rawValue: payload.format),
              let scoped = locations.resolveSaveDirectory(for: payload.location) else { return }
        defer { scoped.stopAccessing() }

        let regenerated: String
        do {
            regenerated = try DeclarativeArtifactEngineV6.render(payload.manifest, as: format)
        } catch {
            onExecutionUpdate?("❌ Declarative artifact failed re-validation before save: \(error.localizedDescription)")
            return
        }
        guard regenerated == payload.content else {
            onExecutionUpdate?("🛡️ Declarative artifact payload mismatch; save blocked.")
            return
        }

        let target = scoped.url.appendingPathComponent(payload.filename)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            onExecutionUpdate?("❌ Visual artifact exists already; overwrite blocked.")
            return
        }
        do {
            try regenerated.write(to: target, atomically: true, encoding: .utf8)
            PersistenceService.shared.saveFile(filename: payload.filename, path: target.path, capabilityId: id)
            onExecutionUpdate?("✅ Declarative visual artifact created: \(target.path)")
        } catch {
            onExecutionUpdate?("❌ Visual artifact creation failed: \(error.localizedDescription)")
        }
    }
}
