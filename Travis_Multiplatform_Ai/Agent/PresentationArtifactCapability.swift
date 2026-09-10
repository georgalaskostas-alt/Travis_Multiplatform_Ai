import Foundation

/// Produces self-contained visual artifacts (SVG/HTML/Markdown) without scripts or remote resources.
/// Generation may use AI for layout/synthesis, but filesystem mutation is always approval-gated.
@MainActor
final class PresentationArtifactCapability: AgentCapability {
    let id="presentation_artifact"
    let name="Presentation & Visualization"
    let capabilityDescription="Creates polished self-contained charts, dashboards, infographics and rich report artifacts as SVG/HTML/Markdown; save is approval-gated and no overwrite is allowed."
    let keywords=["γράφημα","γραφημα","chart","dashboard","infographic","οπτικοποίηση","οπτικοποιηση","visualize","παρουσίασε γραφικά","presentation artifact","svg","html report"]
    private(set) var status:AgentCapabilityStatus = .idle
    var onExecutionUpdate:((String)->Void)?
    private let aiService:AIService
    private let locations:FileLocationService
    init(aiService:AIService = .shared,locations:FileLocationService = .shared){self.aiService=aiService;self.locations=locations}
    var descriptor:CapabilityDescriptor{CapabilityDescriptor(id:id,displayName:name,summary:capabilityDescription,domain:.files,keywords:keywords,policy:CapabilityExecutionPolicy(declaredEffects:[.readOnly,.localMutation],permissionKeys:["file_save"],requiresExplicitApproval:true,supportsBackgroundExecution:false,supportsProjectContext:true,timeoutSeconds:180,maxAttempts:2))}
    private struct Payload:Codable{var filename:String;var location:String?;var content:String;var format:String}
    func handle(command:String,recentHistory:[ChatMessage])async throws->CapabilityOutcome{
        status = .running;defer{status = .idle};let request=command.trimmingCharacters(in:.whitespacesAndNewlines);guard !request.isEmpty else{return .reply("Πες μου τι visualization/report θέλεις να δημιουργήσω.")}
        let prompt="""
        You are TRAVIS Presentation Engine. Convert the request and supplied conversational evidence into ONE polished self-contained visual artifact.
        Choose exactly one format: svg, html, or md. Prefer SVG for charts/infographics, HTML for multi-section dashboards, Markdown for text-heavy reports.
        SECURITY: no JavaScript, no script tags, no event handlers, no external URLs/resources/fonts/images, no forms, no network calls. Inline CSS only in HTML. SVG must be standalone XML/SVG with no foreignObject or external references.
        DATA INTEGRITY: use only facts/numbers present in the request/context; do not invent measurements. If exact numeric data is absent, make an explanatory visual rather than fabricated chart values.
        ACCESSIBILITY: include meaningful title/labels; make SVG text readable.
        Return JSON only with keys format, filename, content. filename must be a simple safe filename ending .svg/.html/.md.

        REQUEST
        \(request)

        RECENT CONTEXT
        \(recentHistory.suffix(8).promptTranscript.prefix(24000))
        """
        let context=AIInvocationContext(workload:.complex,capabilityId:id,operation:"presentation.generate")
        let raw=try await aiService.generateText(prompt:prompt,maxTokens:9000,context:context)
        guard let a=raw.firstIndex(of:"{"),let b=raw.lastIndex(of:"}"),let data=String(raw[a...b]).data(using:.utf8),let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let format=(obj["format"] as? String)?.lowercased(),let filename=obj["filename"] as? String,let content=obj["content"] as? String,Self.valid(filename:filename,format:format),Self.safe(content:content,format:format),content.utf8.count<=5_000_000 else{return .reply("Το visual artifact απορρίφθηκε από deterministic safety/completeness validation και δεν θα αποθηκευτεί.")}
        let payload=Payload(filename:filename,location:nil,content:content,format:format),encoded=try JSONEncoder().encode(payload);guard let text=String(data:encoded,encoding:.utf8)else{return .none}
        return .proposal(ProposedAction(capabilityId:id,summary:"Create visual artifact \(filename)",reasoning:"Το artifact δημιουργήθηκε και πέρασε deterministic checks για format, scripts, external resources και μέγεθος.",expectedImpact:"Θα δημιουργηθεί νέο self-contained \(format.uppercased()) artifact χωρίς overwrite.",riskLevel:.medium,payload:text,filename:filename,location:nil))
    }
    func resolve(_ action:ProposedAction){guard action.status == .approved,let text=action.payload,let data=text.data(using:.utf8),let p=try? JSONDecoder().decode(Payload.self,from:data),Self.valid(filename:p.filename,format:p.format),Self.safe(content:p.content,format:p.format),let scoped=locations.resolveSaveDirectory(for:p.location)else{return};defer{scoped.stopAccessing()};let target=scoped.url.appendingPathComponent(p.filename);guard !FileManager.default.fileExists(atPath:target.path)else{onExecutionUpdate?("❌ Visual artifact exists already; overwrite blocked.");return};do{try p.content.write(to:target,atomically:true,encoding:.utf8);PersistenceService.shared.saveFile(filename:p.filename,path:target.path,capabilityId:id);onExecutionUpdate?("✅ Visual artifact created: \(target.path)")}catch{onExecutionUpdate?("❌ Visual artifact creation failed: \(error.localizedDescription)")}}
    private static func valid(filename:String,format:String)->Bool{guard ["svg","html","md"].contains(format),!filename.isEmpty,!filename.contains("/"),!filename.contains("\\"),!filename.contains("..")else{return false};return (filename as NSString).pathExtension.lowercased()==format}
    private static func safe(content:String,format:String)->Bool{let x=content.lowercased(),blocked=["<script","javascript:","onload=","onclick=","onerror=","<iframe","<object","<embed","<form","http://","https://","url(http","url(https","foreignobject"];guard !blocked.contains(where:x.contains)else{return false};if format=="svg"{return x.contains("<svg") && x.contains("</svg>")};if format=="html"{return x.contains("<html") && x.contains("</html>")};return !content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
}
