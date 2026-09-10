import Foundation

struct MissionPlannerV2StepDraft:Codable,Hashable{var order:Int;var title:String;var instructions:String;var capabilityId:String;var dependencyOrders:[Int];var successCriteria:[String];var riskLevel:PlanStepRiskLevel;var canRunInBackground:Bool;var estimatedEffort:PlanStepEffort;var maxAttempts:Int}
struct MissionPlannerV2Draft:Codable,Hashable{var summary:String;var steps:[MissionPlannerV2StepDraft]}
enum AutonomousMissionPlannerV2Error:LocalizedError{case emptyGoal,noCapabilities,malformedPlan(String),invalidCapability(String),duplicateOrder(Int),missingDependency(step:Int,dependency:Int);var errorDescription:String?{switch self{case .emptyGoal:return"Ο στόχος της αποστολής είναι κενός.";case .noCapabilities:return"Δεν υπάρχουν διαθέσιμα εργαλεία.";case .malformedPlan(let d):return"Μη έγκυρο σχέδιο: \(d)";case .invalidCapability(let id):return"Άγνωστο capability: \(id)";case .duplicateOrder(let o):return"Διπλό βήμα: \(o)";case .missingDependency(let s,let d):return"Το βήμα \(s) εξαρτάται από ανύπαρκτο βήμα \(d)."}}}

@MainActor final class AutonomousMissionPlannerV2{
 private let aiService:AIService;private let maxDecodeAttempts=2
 init(aiService:AIService = .shared){self.aiService=aiService}
 private static let headlessAliases:[String:String]=["repository_context":"repository.snapshot","runtime_health":"runtime.health","system_scan":"runtime.health","runtime_identity":"runtime.identity","runtime_safety":"runtime.safety","filesystem_inventory":"filesystem.inventory","http_probe":"network.http_probe","network_probe":"network.http_probe","report_synthesis":"report.synthesize","market_intelligence":"market.analyze","self_audit":"repository.audit","headless_reasoning":"ai.reason"]
 private static func headlessCatalog(_ caps:[AgentCapability])->String{caps.compactMap{c in guard let m=headlessAliases[c.id]else{return nil};return"- \(c.id) -> \(m) [HEADLESS-SAFE]"}.joined(separator:"\n")}
 func makePlan(goal:String,capabilities:[AgentCapability],priorKnowledge:String?=nil)async throws->TaskPlan{
  let g=goal.trimmingCharacters(in:.whitespacesAndNewlines);guard !g.isEmpty else{throw AutonomousMissionPlannerV2Error.emptyGoal};guard !capabilities.isEmpty else{throw AutonomousMissionPlannerV2Error.noCapabilities}
  let registry=CapabilityRegistry(capabilities:capabilities),catalog=registry.promptCatalog(),headless=Self.headlessCatalog(capabilities),knowledge=priorKnowledge?.trimmingCharacters(in:.whitespacesAndNewlines)
  let prompt="""
  You are the TRAVIS Cognitive Mission Planner V2 running under the V6 economy policy. Build the smallest reliable executable end-to-end plan.
  USER GOAL:\n\(g)
  UNIVERSAL CAPABILITY REGISTRY:\n\(catalog)
  HEADLESS ALWAYS-ON EXPORT MAP:\n\(headless.isEmpty ? "None":headless)
  PRIOR VERIFIED KNOWLEDGE:\n\(knowledge?.isEmpty == false ? String(knowledge!.prefix(9000)):"None")

  INTELLIGENCE ECONOMY:
  - Every unnecessary cloud call is a defect. Prefer deterministic/local capabilities and verified prior knowledge.
  - Do not add an AI reasoning step when a deterministic capability can produce and verify the answer.
  - Use headless_reasoning only when evidence genuinely requires synthesis; never as ceremony.
  - Produce the minimum sufficient plan, but never omit verification for mutation, money, code or safety-sensitive work.
  - Reuse prior procedural lessons but re-check current facts and mutable state.

  EXECUTION / SAFETY POLICY:
  - Treat each capability descriptor's effects, approval, background, timeout and permission declarations as hard constraints.
  - canRunInBackground=true ONLY for capability IDs in the headless map AND only if descriptor policy allows background execution.
  - repository_context, filesystem_inventory, self_audit require explicit path=/absolute/path in instructions. Never invent a path.
  - http_probe/network_probe require explicit url=http(s)://... . Never invent a URL.
  - market_intelligence requires explicit asset=TICKER and may include interval=1h.
  - headless_reasoning is read-only reasoning over verified evidence. It may depend on evidence-producing steps.
  - Market analysis is probabilistic. Never claim guaranteed profit, certain prediction or risk-free return.
  - Trading mutations require their dedicated deterministic contract and risk controls. Never disguise order execution as analysis.
  - self_evolution_v6 and coding_repository are mutation-capable. Use only for explicit code/GUI changes, keep approval=true via descriptor, inspect before mutation and validate after mutation.
  - Never weaken an approval requirement from the descriptor.
  - Prefer evidence → action/reasoning → independent verification → artifact/report when the goal warrants it.

  PLAN RULES:
  - Prefer 2-10 steps; exceed that only when the goal genuinely requires decomposition.
  - Every step uses exactly one registered capabilityId.
  - Dependencies reference earlier order numbers only.
  - Success criteria must be observable/verifiable.
  - riskLevel low|medium|high|critical; estimatedEffort short|medium|long; maxAttempts 1...5.
  - Output JSON only, no Markdown.
  SCHEMA:
  {"summary":"strategy","steps":[{"order":1,"title":"title","instructions":"exact work with required path=/... url=... asset=...","capabilityId":"exact id","dependencyOrders":[],"successCriteria":["criterion"],"riskLevel":"low","canRunInBackground":true,"estimatedEffort":"short","maxAttempts":3}]}
  """
  return try materialize(draft:try await requestDraft(prompt:prompt,workload:planningWorkload(g)),allowed:Set(capabilities.map(\.id)),registry:registry)
 }
 func makeRecoveryPlan(task:AgentTask,capabilities:[AgentCapability])async throws->TaskPlan{
  let completed=task.plan.steps.filter{$0.status == .completed}.sorted{$0.order<$1.order}.map{"STEP #\($0.order) \($0.title): \(String(($0.resultSummary ?? "No result").prefix(4000)))"}.joined(separator:"\n"),failed=task.plan.steps.first{$0.status == .failed},failure=failed.map{"STEP #\($0.order) \($0.title): \($0.lastError ?? task.failureReason ?? "Unknown")"} ?? (task.failureReason ?? "Unknown"),registry=CapabilityRegistry(capabilities:capabilities),headless=Self.headlessCatalog(capabilities),reflection=CognitiveReflectionStore.shared.compactContext(goal:task.goal,projectId:AIExecutionScope.context.projectId)
  let prompt="""
  You are TRAVIS Self-Correction Planner V2 under V6 cognitive economy. Diagnose the failure and produce only the remaining work for ORIGINAL GOAL: \(task.goal)
  COMPLETED VERIFIED WORK:\n\(String(completed.prefix(16000)).isEmpty ? "None":String(completed.prefix(16000)))
  FAILURE:\n\(failure)
  VERIFIED REFLECTIONS:\n\(reflection.isEmpty ? "None":String(reflection.prefix(5000)))
  CAPABILITY REGISTRY:\n\(registry.promptCatalog())
  HEADLESS MAP:\n\(headless)
  Choose a materially different route when the previous approach failed. Reuse completed evidence. Respect all descriptor policies. Preserve explicit path=/..., url=..., asset=TICKER requirements. Never invent unavailable facts. Code/trading mutations stay approval/risk gated. Use exact IDs, 1-8 steps, maxAttempts 1...5. JSON only.
  """
  let p=try materialize(draft:try await requestDraft(prompt:prompt,workload:planningWorkload(task.goal)),allowed:Set(capabilities.map(\.id)),registry:registry);return TaskPlan(version:task.plan.version+1,summary:"Recovery v\(task.plan.version+1): \(p.summary)",steps:p.steps)
 }
 private func planningWorkload(_ goal:String)->AIWorkloadClass{let v=goal.lowercased(),frontier=["self improve","self-improve","αυτοβελ","architecture","αρχιτεκτον","security","ασφάλ","trading system","risk engine","production incident","gui του travis","κώδικα του travis"];return frontier.contains(where:v.contains) ? .frontier:.complex}
 private func requestDraft(prompt:String,workload:AIWorkloadClass)async throws->MissionPlannerV2Draft{var raw="",last="unknown";for attempt in 1...maxDecodeAttempts{try Task.checkCancellation();let req=attempt==1 ? prompt:"Repair the following into valid MissionPlannerV2 JSON only. Preserve semantics and capability IDs; do not expand scope:\n\(raw)";let context=AIInvocationContext(workload:attempt==1 ? workload:.routine,capabilityId:"mission_planner",taskId:AIExecutionScope.context.taskId,stepId:AIExecutionScope.context.stepId,projectId:AIExecutionScope.context.projectId,operation:attempt==1 ? "autonomous.mission.plan.v2":"autonomous.mission.plan.repair");let packet=CognitiveCoreV6.shared.prepareRemotePrompt(req,context:context);raw=try await aiService.generateText(prompt:packet.prompt,maxTokens:attempt==1 ? 5000:2200,context:context);do{let j=extract(raw);guard let d=j.data(using:.utf8)else{throw AutonomousMissionPlannerV2Error.malformedPlan("UTF-8")};return try JSONDecoder().decode(MissionPlannerV2Draft.self,from:d)}catch{last=error.localizedDescription}};throw AutonomousMissionPlannerV2Error.malformedPlan(last)}
 private func materialize(draft:MissionPlannerV2Draft,allowed:Set<String>,registry:CapabilityRegistry)throws->TaskPlan{guard !draft.steps.isEmpty else{throw AutonomousMissionPlannerV2Error.malformedPlan("no steps")};let sorted=draft.steps.sorted{$0.order<$1.order};var seen=Set<Int>();for s in sorted{guard seen.insert(s.order).inserted else{throw AutonomousMissionPlannerV2Error.duplicateOrder(s.order)};guard allowed.contains(s.capabilityId)else{throw AutonomousMissionPlannerV2Error.invalidCapability(s.capabilityId)};guard (1...5).contains(s.maxAttempts)else{throw AutonomousMissionPlannerV2Error.malformedPlan("maxAttempts")};if s.canRunInBackground && (Self.headlessAliases[s.capabilityId]==nil || !registry.supportsBackground(id:s.capabilityId)){throw AutonomousMissionPlannerV2Error.malformedPlan("capability illegally marked background: \(s.capabilityId)")};for d in s.dependencyOrders{guard d<s.order,seen.contains(d)else{throw AutonomousMissionPlannerV2Error.missingDependency(step:s.order,dependency:d)}}};var ids:[Int:UUID]=[:];for s in sorted{ids[s.order]=UUID()};let steps=try sorted.map{s->PlanStep in let deps=try s.dependencyOrders.map{d->UUID in guard let id=ids[d]else{throw AutonomousMissionPlannerV2Error.missingDependency(step:s.order,dependency:d)};return id};let descriptor=registry.descriptor(id:s.capabilityId),approval=descriptor?.policy.requiresExplicitApproval ?? false,background=s.canRunInBackground && (descriptor?.policy.supportsBackgroundExecution ?? false),attempts=min(s.maxAttempts,descriptor?.policy.maxAttempts ?? s.maxAttempts);return PlanStep(id:ids[s.order]!,order:s.order,title:s.title,instructions:s.instructions,capabilityId:s.capabilityId,dependencyStepIds:deps,successCriteria:s.successCriteria,riskLevel:s.riskLevel,requiresApproval:approval,canRunInBackground:background,estimatedEffort:s.estimatedEffort,maxAttempts:attempts)};return TaskPlan(version:1,summary:draft.summary.trimmingCharacters(in:.whitespacesAndNewlines),steps:steps)}
 private func extract(_ raw:String)->String{let t=raw.trimmingCharacters(in:.whitespacesAndNewlines),c=t.hasPrefix("```") ? t.replacingOccurrences(of:"```json",with:"").replacingOccurrences(of:"```JSON",with:"").replacingOccurrences(of:"```",with:"").trimmingCharacters(in:.whitespacesAndNewlines):t;if let a=c.firstIndex(of:"{"),let b=c.lastIndex(of:"}"){return String(c[a...b])};return c}
}
