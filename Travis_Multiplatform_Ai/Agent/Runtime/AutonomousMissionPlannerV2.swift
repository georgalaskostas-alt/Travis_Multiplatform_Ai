import Foundation

struct MissionPlannerV2StepDraft:Codable,Hashable{var order:Int;var title:String;var instructions:String;var capabilityId:String;var dependencyOrders:[Int];var successCriteria:[String];var riskLevel:PlanStepRiskLevel;var canRunInBackground:Bool;var estimatedEffort:PlanStepEffort;var maxAttempts:Int}
struct MissionPlannerV2Draft:Codable,Hashable{var summary:String;var steps:[MissionPlannerV2StepDraft]}
enum AutonomousMissionPlannerV2Error:LocalizedError{case emptyGoal,noCapabilities,malformedPlan(String),invalidCapability(String),duplicateOrder(Int),missingDependency(step:Int,dependency:Int);var errorDescription:String?{switch self{case .emptyGoal:return"Ο στόχος της αποστολής είναι κενός.";case .noCapabilities:return"Δεν υπάρχουν διαθέσιμα εργαλεία.";case .malformedPlan(let d):return"Μη έγκυρο σχέδιο: \(d)";case .invalidCapability(let id):return"Άγνωστο capability: \(id)";case .duplicateOrder(let o):return"Διπλό βήμα: \(o)";case .missingDependency(let s,let d):return"Το βήμα \(s) εξαρτάται από ανύπαρκτο βήμα \(d)."}}}

@MainActor final class AutonomousMissionPlannerV2{
 private let aiService:AIService;private let maxDecodeAttempts=2
 init(aiService:AIService = .shared){self.aiService=aiService}
 private static let headlessAliases:[String:String]=[
  "repository_context":"repository.snapshot",
  "runtime_health":"runtime.health",
  "system_scan":"runtime.health",
  "runtime_identity":"runtime.identity",
  "runtime_safety":"runtime.safety",
  "filesystem_inventory":"filesystem.inventory",
  "http_probe":"network.http_probe",
  "network_probe":"network.http_probe",
  "report_synthesis":"report.synthesize",
  "market_intelligence":"market.analyze",
  "self_audit":"repository.audit",
  "headless_reasoning":"ai.reason"
 ]
 private static func headlessCatalog(_ caps:[AgentCapability])->String{caps.compactMap{c in guard let m=headlessAliases[c.id]else{return nil};return"- \(c.id) -> \(m) [HEADLESS-SAFE]"}.joined(separator:"\n")}
 func makePlan(goal:String,capabilities:[AgentCapability],priorKnowledge:String?=nil)async throws->TaskPlan{
  let g=goal.trimmingCharacters(in:.whitespacesAndNewlines);guard !g.isEmpty else{throw AutonomousMissionPlannerV2Error.emptyGoal};guard !capabilities.isEmpty else{throw AutonomousMissionPlannerV2Error.noCapabilities}
  let catalog=capabilities.map{"- \($0.id): \($0.name) — \($0.capabilityDescription)"}.joined(separator:"\n"),headless=Self.headlessCatalog(capabilities),knowledge=priorKnowledge?.trimmingCharacters(in:.whitespacesAndNewlines)
  let prompt="""
  You are TRAVIS Mission Planner V2. Build the smallest reliable executable end-to-end plan.
  USER GOAL:\n\(g)
  AVAILABLE CAPABILITIES:\n\(catalog)
  HEADLESS ALWAYS-ON EXPORT MAP:\n\(headless.isEmpty ? "None":headless)
  PRIOR VERIFIED KNOWLEDGE:\n\(knowledge?.isEmpty == false ? knowledge!:"None")

  EXECUTION POLICY:
  - Prefer headless-safe capabilities when they can satisfy the goal correctly.
  - canRunInBackground=true ONLY for capability IDs in the headless map. Otherwise false.
  - repository_context, filesystem_inventory, self_audit require explicit path=/absolute/path in instructions. Never invent a path.
  - http_probe/network_probe require explicit url=http(s)://... . Never invent a URL.
  - market_intelligence requires explicit asset=TICKER and may include interval=1h. For a broad market report, create separate market_intelligence steps for requested/major assets.
  - headless_reasoning is for read-only reasoning/synthesis over verified context. Put the full reasoning objective in instructions; it may depend on earlier evidence-producing steps and can remain background-safe.
  - Market analysis is probabilistic. Never claim guaranteed profit, certain prediction, or risk-free return.
  - Trading mutations are NOT headless-safe through this planner unless a dedicated deterministic worker trading contract is explicitly available. Do not disguise order execution as market analysis.
  - self_audit is read-only. Code/GUI mutation belongs to approval-gated coding/self-improvement capabilities and must remain foreground/approval-gated.
  - If foreground mutation is required, place it before any independent headless verification/report suffix when dependencies permit.
  - Never mark approval-required work as background-safe.
  - Prefer evidence -> reasoning -> report chains. Reasoning must not fabricate missing evidence.

  GENERAL RULES:
  - Prefer 3-12 steps. Every step uses exactly one available capabilityId.
  - Dependencies reference earlier order numbers only. Success criteria are concrete and verifiable.
  - Separate inspection, mutation, verification and delivery where appropriate.
  - If code changes are requested, inspect first and include later verification/test when available.
  - riskLevel: low|medium|high|critical. estimatedEffort: short|medium|long. maxAttempts: 1...5.
  - Output JSON only, no Markdown.
  SCHEMA:
  {"summary":"strategy","steps":[{"order":1,"title":"title","instructions":"exact deterministic work with required path=/... url=... asset=...","capabilityId":"exact id","dependencyOrders":[],"successCriteria":["criterion"],"riskLevel":"low","canRunInBackground":true,"estimatedEffort":"short","maxAttempts":3}]}
  """
  return try materialize(draft:try await requestDraft(prompt:prompt),allowed:Set(capabilities.map(\.id)))
 }
 func makeRecoveryPlan(task:AgentTask,capabilities:[AgentCapability])async throws->TaskPlan{
  let completed=task.plan.steps.filter{$0.status == .completed}.sorted{$0.order<$1.order}.map{"STEP #\($0.order) \($0.title): \(String(($0.resultSummary ?? "No result").prefix(4000)))"}.joined(separator:"\n"),failed=task.plan.steps.first{$0.status == .failed},failure=failed.map{"STEP #\($0.order) \($0.title): \($0.lastError ?? task.failureReason ?? "Unknown")"} ?? (task.failureReason ?? "Unknown"),catalog=capabilities.map{"- \($0.id): \($0.capabilityDescription)"}.joined(separator:"\n"),headless=Self.headlessCatalog(capabilities)
  let prompt="""
  You are TRAVIS Self-Correction Planner V2. Produce only remaining work for ORIGINAL GOAL: \(task.goal)
  COMPLETED VERIFIED WORK:\n\(completed.isEmpty ? "None":completed)
  FAILURE:\n\(failure)
  CAPABILITIES:\n\(catalog)
  HEADLESS MAP:\n\(headless)
  Choose a materially better route. Preserve the same headless argument rules: explicit path=/..., url=..., asset=TICKER; never invent them. headless_reasoning may synthesize verified evidence but must not invent unavailable facts. Market analysis is probabilistic. Code/trading mutations remain approval-gated. Use exact IDs, 1-8 steps, maxAttempts 1...5. Output the normal JSON schema only.
  """
  let p=try materialize(draft:try await requestDraft(prompt:prompt),allowed:Set(capabilities.map(\.id)));return TaskPlan(version:task.plan.version+1,summary:"Recovery v\(task.plan.version+1): \(p.summary)",steps:p.steps)
 }
 private func requestDraft(prompt:String)async throws->MissionPlannerV2Draft{var raw="",last="unknown";for attempt in 1...maxDecodeAttempts{try Task.checkCancellation();let req=attempt==1 ? prompt:"Repair into valid MissionPlannerV2 JSON only:\n\(raw)";raw=try await AIExecutionScope.$context.withValue(AIInvocationContext(workload:.complex,operation:"autonomous.mission.plan.v2")){try await aiService.generateText(prompt:req,maxTokens:attempt==1 ? 5000:2500)};do{let j=extract(raw);guard let d=j.data(using:.utf8)else{throw AutonomousMissionPlannerV2Error.malformedPlan("UTF-8")};return try JSONDecoder().decode(MissionPlannerV2Draft.self,from:d)}catch{last=error.localizedDescription}};throw AutonomousMissionPlannerV2Error.malformedPlan(last)}
 private func materialize(draft:MissionPlannerV2Draft,allowed:Set<String>)throws->TaskPlan{guard !draft.steps.isEmpty else{throw AutonomousMissionPlannerV2Error.malformedPlan("no steps")};let sorted=draft.steps.sorted{$0.order<$1.order};var seen=Set<Int>();for s in sorted{guard seen.insert(s.order).inserted else{throw AutonomousMissionPlannerV2Error.duplicateOrder(s.order)};guard allowed.contains(s.capabilityId)else{throw AutonomousMissionPlannerV2Error.invalidCapability(s.capabilityId)};guard (1...5).contains(s.maxAttempts)else{throw AutonomousMissionPlannerV2Error.malformedPlan("maxAttempts")};if s.canRunInBackground && Self.headlessAliases[s.capabilityId]==nil{throw AutonomousMissionPlannerV2Error.malformedPlan("non-headless capability marked background: \(s.capabilityId)")};for d in s.dependencyOrders{guard d<s.order,seen.contains(d)else{throw AutonomousMissionPlannerV2Error.missingDependency(step:s.order,dependency:d)}}};var ids:[Int:UUID]=[:];for s in sorted{ids[s.order]=UUID()};let steps=try sorted.map{s->PlanStep in let deps=try s.dependencyOrders.map{d->UUID in guard let id=ids[d]else{throw AutonomousMissionPlannerV2Error.missingDependency(step:s.order,dependency:d)};return id};return PlanStep(id:ids[s.order]!,order:s.order,title:s.title,instructions:s.instructions,capabilityId:s.capabilityId,dependencyStepIds:deps,successCriteria:s.successCriteria,riskLevel:s.riskLevel,canRunInBackground:s.canRunInBackground,estimatedEffort:s.estimatedEffort,maxAttempts:s.maxAttempts)};return TaskPlan(version:1,summary:draft.summary.trimmingCharacters(in:.whitespacesAndNewlines),steps:steps)}
 private func extract(_ raw:String)->String{let t=raw.trimmingCharacters(in:.whitespacesAndNewlines),c=t.hasPrefix("```") ? t.replacingOccurrences(of:"```json",with:"").replacingOccurrences(of:"```JSON",with:"").replacingOccurrences(of:"```",with:"").trimmingCharacters(in:.whitespacesAndNewlines):t;if let a=c.firstIndex(of:"{"),let b=c.lastIndex(of:"}"){return String(c[a...b])};return c}
}
