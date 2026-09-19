import Foundation
import Observation

/// Remembers failed approaches so TRAVIS can avoid repeating the same mistake.
@MainActor @Observable
final class FailureLearningStore {
    static let shared = FailureLearningStore()
    struct Failure:Identifiable,Codable,Hashable{
        let id:UUID;var createdAt:Date;let capabilityId:String;let instruction:String;var error:String;let projectId:UUID?;var occurrences:Int
        init(capabilityId:String,instruction:String,error:String,projectId:UUID?){id=UUID();createdAt=Date();self.capabilityId=capabilityId;self.instruction=instruction;self.error=error;self.projectId=projectId;occurrences=1}
    }
    struct Match:Hashable{let failure:Failure;let confidence:Double}
    private struct Snapshot:Codable{let version:Int;let failures:[Failure]}
    private(set) var failures:[Failure]=[]
    private let url:URL
    private init(){let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.temporaryDirectory;let dir=base.appendingPathComponent("TRAVIS",isDirectory:true);try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);url=dir.appendingPathComponent("failure-learning-v1.json");reload()}

    func record(capabilityId:String,instruction:String,error:String,projectId:UUID?){
        let clean=error.trimmingCharacters(in:.whitespacesAndNewlines);guard !clean.isEmpty else{return}
        let instruction=String(instruction.prefix(6000));let q=terms(instruction)
        if let index=failures.lastIndex(where:{$0.capabilityId==capabilityId && $0.projectId==projectId && similarity(q,terms($0.instruction))>=0.90}){
            failures[index].occurrences += 1;failures[index].createdAt=Date();failures[index].error=String(clean.prefix(6000))
        }else{failures.append(Failure(capabilityId:capabilityId,instruction:instruction,error:String(clean.prefix(6000)),projectId:projectId))}
        if failures.count>10_000{failures.removeFirst(failures.count-10_000)};persist()
    }

    func bestMatch(capabilityId:String,instruction:String,projectId:UUID?,minimumConfidence:Double=0.78)->Match?{
        let q=terms(instruction);guard q.count>=3 else{return nil};var best:Match?
        for f in failures.reversed().prefix(750) where f.capabilityId==capabilityId{
            let base=similarity(q,terms(f.instruction));let sameProject=projectId != nil && f.projectId==projectId
            let repetitionBoost=min(0.08,Double(max(0,f.occurrences-1))*0.02)
            let score=min(1,base+(sameProject ? 0.10:0)+repetitionBoost)
            if score>=minimumConfidence && (best==nil || score>best!.confidence){best=Match(failure:f,confidence:score)}
        };return best
    }

    func warning(capabilityId:String,instruction:String,projectId:UUID?)->String?{
        guard let b=bestMatch(capabilityId:capabilityId,instruction:instruction,projectId:projectId) else{return nil}
        return """
        PREVIOUS FAILED APPROACH — DO NOT REPEAT BLINDLY
        confidence: \(Int(b.confidence*100))%
        previous occurrences: \(b.failure.occurrences)
        prior instruction: \(b.failure.instruction)
        prior failure: \(b.failure.error)
        Choose a materially different route if the same failure conditions still exist.
        """
    }

    private func reload(){guard let d=try? Data(contentsOf:url),let s=try? JSONDecoder().decode(Snapshot.self,from:d),s.version==1 else{return};failures=s.failures}
    private func persist(){guard let d=try? JSONEncoder().encode(Snapshot(version:1,failures:failures)) else{return};try? d.write(to:url,options:.atomic)}
    private func similarity(_ a:Set<String>,_ b:Set<String>)->Double{guard !a.isEmpty else{return 0};return Double(a.intersection(b).count)/Double(a.count)}
    private func terms(_ text:String)->Set<String>{Set(text.lowercased().folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).split{!$0.isLetter && !$0.isNumber}.map(String.init).filter{$0.count>=3})}
}
