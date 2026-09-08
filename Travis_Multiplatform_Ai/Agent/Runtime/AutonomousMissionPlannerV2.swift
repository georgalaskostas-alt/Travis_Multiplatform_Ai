import Foundation

struct MissionPlannerV2StepDraft: Codable, Hashable { var order:Int;var title:String;var instructions:String;var capabilityId:String;var dependencyOrders:[Int];var successCriteria:[String];var riskLevel:PlanStepRiskLevel;var canRunInBackground:Bool;var estimatedEffort:PlanStepEffort;var maxAttempts:Int }
struct MissionPlannerV2Draft: Codable, Hashable { var summary:String;var steps:[MissionPlannerV2StepDraft] }
enum AutonomousMissionPlannerV2Error:LocalizedError { case emptyGoal,noCapabilities,malformedPlan(String),invalidCapability(String),duplicateOrder(Int),missingDependency(step:Int,dependency:Int);var errorDescription:String?{switch self{case .emptyGoal:return "Ο στόχος της αποστολής είναι κενός.";case .noCapabilities:return "Δεν υπάρχουν διαθέσιμα εργαλεία για να σχεδιαστεί η αποστολή.";case .malformedPlan(let d):return "Ο planner επέστρεψε μη έγκυρο σχέδιο: \(d)";case .invalidCapability(let id):return "Ο planner επέλεξε άγνωστο εργαλείο: \(id)";case .duplicateOrder(let o):return "Το σχέδιο έχει διπλό αριθμό βήματος: \(o)";case .missingDependency(let s,let d):return "Το βήμα \(s) εξαρτάται από ανύπαρκτο βήμα \(d)."}}}

@MainActor final class AutonomousMissionPlannerV2 {
    private let aiService:AIService;private let maxDecodeAttempts=2
    init(aiService:AIService = .shared){self.aiService=aiService}
    private static let headlessAliases:[String:String] = ["repository_context":"repository.snapshot","runtime_health":"runtime.health","system_scan":"runtime.health","runtime_identity":"runtime.identity","runtime_safety":"runtime.safety","filesystem_inventory":"filesystem.inventory","http_probe":"network.http_probe","network_probe":"network.http_probe","report_synthesis":"report.synthesize"]
    private static func headlessCatalog(_ capabilities:[AgentCapability])->String{capabilities.compactMap{c in guard let mapped=headlessAliases[c.id] else{return nil};return "- \(c.id) -> \(mapped) [HEADLESS-SAFE: yes]"}.joined(separator:"\n")}

    func makePlan(goal:String,capabilities:[AgentCapability],priorKnowledge:String?=nil)async throws->TaskPlan{
        let goal=goal.trimmingCharacters(in:.whitespacesAndNewlines);guard !goal.isEmpty else{throw AutonomousMissionPlannerV2Error.emptyGoal};guard !capabilities.isEmpty else{throw AutonomousMissionPlannerV2Error.noCapabilities}
        let catalog=capabilities.map{"- \($0.id): \($0.name) — \($0.capabilityDescription)"}.joined(separator:"\n");let headless=Self.headlessCatalog(capabilities);let knowledge=priorKnowledge?.trimmingCharacters(in:.whitespacesAndNewlines)
        let prompt="""
        You are TRAVIS Mission Planner V2. Build the smallest reliable executable plan.

        USER GOAL:
        \(goal)

        AVAILABLE CAPABILITIES:
        \(catalog)

        HEADLESS ALWAYS-ON EXPORT MAP:
        \(headless.isEmpty ? "No headless-safe capabilities are currently available." : headless)

        PRIOR VERIFIED KNOWLEDGE:
        \(knowledge?.isEmpty == false ? knowledge! : "None")

        EXECUTION POLICY:
        - Prefer HEADLESS-SAFE capabilities whenever they can satisfy the goal without reducing correctness.
        - A step may set canRunInBackground=true ONLY when its capability appears in HEADLESS ALWAYS-ON EXPORT MAP.
        - Capabilities absent from that map MUST set canRunInBackground=false.
        - For repository.snapshot or filesystem.inventory, instructions MUST contain an explicit token path=/absolute/path when the path is known from the goal/context. Never invent a path.
        - For network.http_probe, instructions MUST contain url=https://... or url=http://... explicitly. Never invent a URL.
        - If required deterministic arguments are unknown, keep the step foreground rather than fabricating them.
        - Prefer a fully headless plan when the complete goal can be fulfilled by headless-safe capabilities.
        - If foreground work is genuinely required, put foreground steps first and independent/exportable background work after them when dependencies allow. This enables hybrid execution.

        GENERAL RULES:
        - Prefer 3-12 steps. Every step uses exactly one available capabilityId.
        - Dependencies reference earlier order numbers only. Success criteria must be concrete and verifiable.
        - Separate inspection, modification, verification and delivery where needed.
        - Do not ask for information discoverable by capabilities.
        - riskLevel: low|medium|high|critical. estimatedEffort: short|medium|long. maxAttempts: 1...5.
        - Output JSON only.

        JSON SCHEMA:
        {"summary":"short execution strategy","steps":[{"order":1,"title":"short title","instructions":"exact work; include path=/... or url=https://... when required","capabilityId":"exact capability id","dependencyOrders":[],"successCriteria":["criterion"],"riskLevel":"low","canRunInBackground":true,"estimatedEffort":"short","maxAttempts":3}]}
        """
        let draft=try await requestDraft(prompt:prompt);return try materialize(draft:draft,allowedCapabilityIds:Set(capabilities.map(\.id)))
    }

    func makeRecoveryPlan(task:AgentTask,capabilities:[AgentCapability])async throws->TaskPlan{
        let completed=task.plan.steps.filter{$0.status == .completed}.sorted{$0.order<$1.order};let evidence=completed.map{"STEP #\($0.order) — \($0.title)\nVERIFIED RESULT:\n\(String(($0.resultSummary ?? "No result summary").prefix(5000)))"}.joined(separator:"\n\n");let failed=task.plan.steps.first{$0.status == .failed};let failure=failed.map{"FAILED STEP #\($0.order) — \($0.title)\nERROR: \($0.lastError ?? task.failureReason ?? "Unknown")"} ?? "Failure: \(task.failureReason ?? "Unknown")";let catalog=capabilities.map{"- \($0.id): \($0.name) — \($0.capabilityDescription)"}.joined(separator:"\n");let headless=Self.headlessCatalog(capabilities)
        let prompt="""
        You are TRAVIS Self-Correction Planner V2. Produce only remaining work.
        ORIGINAL GOAL: \(task.goal)
        PREVIOUS PLAN: \(task.plan.summary)
        COMPLETED VERIFIED WORK:\n\(evidence.isEmpty ? "None":evidence)
        FAILURE:\n\(failure)
        AVAILABLE CAPABILITIES:\n\(catalog)
        HEADLESS ALWAYS-ON EXPORT MAP:\n\(headless.isEmpty ? "None":headless)
        Prefer headless-safe capabilities where correct. canRunInBackground=true ONLY for mapped capabilities. Never invent paths or URLs. Use exact IDs, concrete success criteria, 1-8 steps, maxAttempts 1...5. Output JSON only using the normal schema.
        """
        let draft=try await requestDraft(prompt:prompt);let r=try materialize(draft:draft,allowedCapabilityIds:Set(capabilities.map(\.id)));return TaskPlan(version:task.plan.version+1,summary:"Recovery v\(task.plan.version+1): \(r.summary)",steps:r.steps)
    }

    private func requestDraft(prompt:String)async throws->MissionPlannerV2Draft{var raw="";var last="unknown error";for attempt in 1...maxDecodeAttempts{try Task.checkCancellation();let request=attempt==1 ? prompt:"Repair this response into valid JSON matching MissionPlannerV2 schema. Return JSON only.\n\nMALFORMED RESPONSE:\n\(raw)";raw=try await AIExecutionScope.$context.withValue(AIInvocationContext(workload:.complex,operation:"autonomous.mission.plan.v2")){try await aiService.generateText(prompt:request,maxTokens:attempt==1 ? 5000:2500)};do{let json=extractJSONObject(from:raw);guard let data=json.data(using:.utf8)else{throw AutonomousMissionPlannerV2Error.malformedPlan("response is not UTF-8")};return try JSONDecoder().decode(MissionPlannerV2Draft.self,from:data)}catch{last=error.localizedDescription}};throw AutonomousMissionPlannerV2Error.malformedPlan(last)}
    private func materialize(draft:MissionPlannerV2Draft,allowedCapabilityIds:Set<String>)throws->TaskPlan{guard !draft.steps.isEmpty else{throw AutonomousMissionPlannerV2Error.malformedPlan("plan has no steps")};let sorted=draft.steps.sorted{$0.order<$1.order};var seen=Set<Int>();for s in sorted{guard seen.insert(s.order).inserted else{throw AutonomousMissionPlannerV2Error.duplicateOrder(s.order)};guard allowedCapabilityIds.contains(s.capabilityId)else{throw AutonomousMissionPlannerV2Error.invalidCapability(s.capabilityId)};guard (1...5).contains(s.maxAttempts)else{throw AutonomousMissionPlannerV2Error.malformedPlan("step \(s.order) maxAttempts must be 1...5")};if s.canRunInBackground && Self.headlessAliases[s.capabilityId] == nil{throw AutonomousMissionPlannerV2Error.malformedPlan("step \(s.order) marks non-headless capability \(s.capabilityId) as background")};for d in s.dependencyOrders{guard d<s.order,seen.contains(d)else{throw AutonomousMissionPlannerV2Error.missingDependency(step:s.order,dependency:d)}}};var ids:[Int:UUID]=[:];for s in sorted{ids[s.order]=UUID()};let steps=try sorted.map{s->PlanStep in let deps=try s.dependencyOrders.map{d->UUID in guard let id=ids[d]else{throw AutonomousMissionPlannerV2Error.missingDependency(step:s.order,dependency:d)};return id};return PlanStep(id:ids[s.order]!,order:s.order,title:s.title,instructions:s.instructions,capabilityId:s.capabilityId,dependencyStepIds:deps,successCriteria:s.successCriteria,riskLevel:s.riskLevel,canRunInBackground:s.canRunInBackground,estimatedEffort:s.estimatedEffort,maxAttempts:s.maxAttempts)};return TaskPlan(version:1,summary:draft.summary.trimmingCharacters(in:.whitespacesAndNewlines),steps:steps)}
    private func extractJSONObject(from raw:String)->String{let t=raw.trimmingCharacters(in:.whitespacesAndNewlines);let clean=t.hasPrefix("```") ? t.replacingOccurrences(of:"```json",with:"").replacingOccurrences(of:"```JSON",with:"").replacingOccurrences(of:"```",with:"").trimmingCharacters(in:.whitespacesAndNewlines):t;if let f=clean.firstIndex(of:"{"),let l=clean.lastIndex(of:"}"){return String(clean[f...l])};return clean}
}
