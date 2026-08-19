import Foundation
import Observation

/// Durable seed dataset for TRAVIS local learning. Only verified runtime outcomes enter here.
@MainActor @Observable
final class VerifiedLearningStore {
    static let shared = VerifiedLearningStore()
    struct Example:Identifiable,Codable,Hashable{let id:UUID;var createdAt:Date;var taskId:UUID;var stepId:UUID;var projectId:UUID?;var capabilityId:String;var title:String;var instruction:String;var successCriteria:[String];var verifiedResult:String;var sourcePlanVersion:Int;init(id:UUID=UUID(),createdAt:Date=Date(),taskId:UUID,stepId:UUID,projectId:UUID?,capabilityId:String,title:String,instruction:String,successCriteria:[String],verifiedResult:String,sourcePlanVersion:Int){self.id=id;self.createdAt=createdAt;self.taskId=taskId;self.stepId=stepId;self.projectId=projectId;self.capabilityId=capabilityId;self.title=title;self.instruction=instruction;self.successCriteria=successCriteria;self.verifiedResult=verifiedResult;self.sourcePlanVersion=sourcePlanVersion}}
    private struct Snapshot:Codable{var version:Int;var examples:[Example]}
    private(set)var examples:[Example]=[];private(set)var persistenceError:String?;private let maxExamples=20_000;private let fileURL:URL
    private init(){let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.temporaryDirectory;let directory=base.appendingPathComponent("TRAVIS",isDirectory:true);try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);fileURL=directory.appendingPathComponent("verified-learning-v1.json");reload();rebuildLocalProjections()}
    func ingestCompletedTask(_ task:AgentTask,projectId:UUID?){guard task.status == .completed else{return};var changed=false;for step in task.plan.steps where step.status == .completed{guard let capabilityId=step.capabilityId?.trimmingCharacters(in:.whitespacesAndNewlines),!capabilityId.isEmpty,let result=step.resultSummary?.trimmingCharacters(in:.whitespacesAndNewlines),!result.isEmpty else{continue};guard !examples.contains(where:{$0.taskId==task.id && $0.stepId==step.id && $0.sourcePlanVersion==task.plan.version})else{continue};examples.append(Example(taskId:task.id,stepId:step.id,projectId:projectId,capabilityId:capabilityId,title:step.title,instruction:String(step.instructions.prefix(12_000)),successCriteria:step.successCriteria,verifiedResult:String(result.prefix(16_000)),sourcePlanVersion:task.plan.version));changed=true};if examples.count>maxExamples{examples.removeFirst(examples.count-maxExamples);changed=true};if changed{rebuildLocalProjections();persist()}}
    func recentExamples(capabilityId:String?=nil,projectId:UUID?=nil,limit:Int=50)->[Example]{let bounded=max(1,min(limit,500));return examples.reversed().filter{e in(capabilityId==nil || e.capabilityId==capabilityId)&&(projectId==nil || e.projectId==projectId)}.prefix(bounded).map{$0}}
    func contextBlock(capabilityId:String,projectId:UUID?=nil,limit:Int=5)->String{let selected=recentExamples(capabilityId:capabilityId,projectId:projectId,limit:limit);guard !selected.isEmpty else{return ""};return selected.map{"VERIFIED EXAMPLE\ntitle: \($0.title)\ninstruction: \($0.instruction)\nsuccess criteria: \($0.successCriteria.joined(separator:" | "))\nverified result: \($0.verifiedResult)"}.joined(separator:"\n\n")}
    func diagnosticReport()->String{let grouped=Dictionary(grouping:examples,by:\.capabilityId);let rows=grouped.map{"\($0.key): \($0.value.count) verified examples"}.sorted().joined(separator:"\n");return """
    TRAVIS VERIFIED LEARNING
    TOTAL VERIFIED EXAMPLES: \(examples.count)
    BY CAPABILITY
    \(rows.isEmpty ? "κανένα":rows)
    LOCAL VERIFICATION SAVES: \(LearnedVerificationRegistry.shared.localVerificationHits)
    LEARNED EXECUTION GUIDANCE HITS: \(LearnedExecutionRegistry.shared.hits)
    \(LearnedSkillStore.shared.report)
    """}
    func reload(){guard FileManager.default.fileExists(atPath:fileURL.path)else{rebuildLocalProjections();return};do{let data=try Data(contentsOf:fileURL);let snapshot=try JSONDecoder().decode(Snapshot.self,from:data);guard snapshot.version==1 else{return};examples=snapshot.examples;rebuildLocalProjections();persistenceError=nil}catch{persistenceError=error.localizedDescription}}
    private func rebuildLocalProjections(){LearnedVerificationRegistry.shared.rebuild(from:examples);LearnedExecutionRegistry.shared.rebuild(from:examples);LearnedSkillStore.shared.rebuild(from:examples)}
    private func persist(){do{let snapshot=Snapshot(version:1,examples:examples);let data=try JSONEncoder().encode(snapshot);let temporaryURL=fileURL.appendingPathExtension("tmp");try data.write(to:temporaryURL,options:.atomic);if FileManager.default.fileExists(atPath:fileURL.path){_=try FileManager.default.replaceItemAt(fileURL,withItemAt:temporaryURL)}else{try FileManager.default.moveItem(at:temporaryURL,to:fileURL)};persistenceError=nil}catch{persistenceError=error.localizedDescription}}
}

/// Reusable local skills synthesized only from repeated verified examples.
@MainActor @Observable
final class LearnedSkillStore {
    static let shared = LearnedSkillStore()

    struct Skill: Identifiable, Codable, Hashable {
        let id: UUID
        var createdAt: Date
        var updatedAt: Date
        var capabilityId: String
        var projectId: UUID?
        var signatureTerms: [String]
        var provenExamples: Int
        var confidence: Double
        var representativeInstruction: String
        var representativeResult: String
        var successCriteria: [String]
        var useCount: Int
        var lastUsedAt: Date?
    }

    struct Match: Hashable { let skill: Skill; let confidence: Double }
    private struct Snapshot: Codable { var version: Int; var skills: [Skill] }
    private(set) var skills: [Skill] = []
    private let fileURL: URL
    private let minimumExamples = 2

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("learned-skills-v1.json")
        reload()
    }

    func rebuild(from examples: [VerifiedLearningStore.Example]) {
        var built: [Skill] = []
        let grouped = Dictionary(grouping: examples, by: { $0.capabilityId })
        for (capabilityId, capabilityExamples) in grouped {
            var consumed = Set<UUID>()
            for seed in capabilityExamples.reversed() where !consumed.contains(seed.id) {
                let seedTerms = Self.terms(seed.title + " " + seed.instruction)
                guard seedTerms.count >= 3 else { continue }
                let cluster = capabilityExamples.filter { candidate in
                    guard !consumed.contains(candidate.id) else { return false }
                    return Self.similarity(seedTerms, Self.terms(candidate.title + " " + candidate.instruction)) >= 0.68
                }
                guard cluster.count >= minimumExamples else { continue }
                cluster.forEach { consumed.insert($0.id) }
                let common = cluster.dropFirst().reduce(seedTerms) { $0.intersection(Self.terms($1.title + " " + $1.instruction)) }
                guard common.count >= 2 else { continue }
                let projectIds = Set(cluster.compactMap(\.projectId))
                let confidence = min(0.98, 0.72 + Double(cluster.count - minimumExamples) * 0.04 + (projectIds.count == 1 && !projectIds.isEmpty ? 0.06 : 0))
                let latest = cluster.max(by: { $0.createdAt < $1.createdAt }) ?? seed
                built.append(Skill(id:UUID(),createdAt:Date(),updatedAt:Date(),capabilityId:capabilityId,projectId:projectIds.count == 1 ? projectIds.first:nil,signatureTerms:common.sorted(),provenExamples:cluster.count,confidence:confidence,representativeInstruction:latest.instruction,representativeResult:latest.verifiedResult,successCriteria:latest.successCriteria,useCount:0,lastUsedAt:nil))
            }
        }
        for index in built.indices {
            let newTerms = Set(built[index].signatureTerms)
            if let old = skills.filter({$0.capabilityId == built[index].capabilityId}).max(by:{Self.similarity(newTerms,Set($0.signatureTerms)) < Self.similarity(newTerms,Set($1.signatureTerms))}), Self.similarity(newTerms,Set(old.signatureTerms)) >= 0.75 {
                built[index].useCount=old.useCount;built[index].lastUsedAt=old.lastUsedAt;built[index].createdAt=old.createdAt
            }
        }
        skills=built;persist()
    }

    func bestMatch(instruction:String,capabilityId:String,projectId:UUID?,minimumConfidence:Double=0.80)->Match?{
        let query=Self.terms(instruction);guard query.count>=3 else{return nil};var best:Match?
        for skill in skills where skill.capabilityId==capabilityId {
            let overlap=Self.similarity(query,Set(skill.signatureTerms));let projectBoost=projectId != nil && skill.projectId==projectId ? 0.08:0;let score=min(1,overlap*0.72+skill.confidence*0.20+projectBoost)
            if score>=minimumConfidence && (best==nil || score>best!.confidence){best=Match(skill:skill,confidence:score)}
        };return best
    }

    func markUsed(_ id:UUID){guard let index=skills.firstIndex(where:{$0.id==id})else{return};skills[index].useCount += 1;skills[index].lastUsedAt=Date();persist()}
    func guidance(_ match:Match)->String{"""
    LEARNED LOCAL SKILL
    confidence: \(Int(match.confidence*100))%
    proven verified examples: \(match.skill.provenExamples)
    reusable pattern: \(match.skill.signatureTerms.joined(separator:", "))
    representative proven instruction: \(match.skill.representativeInstruction)
    representative verified result: \(match.skill.representativeResult)
    Treat this as learned procedure evidence, not as current-state evidence. Re-check current inputs before acting.
    """}
    var report:String{let uses=skills.reduce(0){$0+$1.useCount};return "TRAVIS LEARNED SKILLS\nskills: \(skills.count)\nuses: \(uses)\nverified examples required per skill: \(minimumExamples)"}
    private func reload(){guard let data=try? Data(contentsOf:fileURL),let snapshot=try? JSONDecoder().decode(Snapshot.self,from:data),snapshot.version==1 else{return};skills=snapshot.skills}
    private func persist(){guard let data=try? JSONEncoder().encode(Snapshot(version:1,skills:skills))else{return};try? data.write(to:fileURL,options:.atomic)}
    private static func similarity(_ a:Set<String>,_ b:Set<String>)->Double{guard !a.isEmpty,!b.isEmpty else{return 0};return Double(a.intersection(b).count)/Double(a.union(b).count)}
    private static func terms(_ text:String)->Set<String>{let stop:Set<String>=["this","that","with","from","into","then","when","where","what","have","will","should","using","make","create","check","please","και","που","την","τον","των","στο","στη","στην","απο","για","με","να","το","τα","της","του","ενα","μια","πως","οταν"];return Set(text.lowercased().folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).split{!$0.isLetter && !$0.isNumber && $0 != "_"}.map(String.init).filter{$0.count>=3 && !stop.contains($0)})}
}
