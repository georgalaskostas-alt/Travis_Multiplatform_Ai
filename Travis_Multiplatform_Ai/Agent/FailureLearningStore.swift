import Foundation
import Observation

/// Remembers failed approaches so TRAVIS can avoid repeating the same mistake.
@MainActor @Observable
final class FailureLearningStore {
    static let shared = FailureLearningStore()
    struct Failure:Identifiable,Codable,Hashable{let id:UUID;let createdAt:Date;let capabilityId:String;let instruction:String;let error:String;let projectId:UUID?;init(capabilityId:String,instruction:String,error:String,projectId:UUID?){id=UUID();createdAt=Date();self.capabilityId=capabilityId;self.instruction=instruction;self.error=error;self.projectId=projectId}}
    private struct Snapshot:Codable{let version:Int;let failures:[Failure]}
    private(set) var failures:[Failure]=[]
    private let url:URL
    private init(){let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.temporaryDirectory;let dir=base.appendingPathComponent("TRAVIS",isDirectory:true);try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);url=dir.appendingPathComponent("failure-learning-v1.json");reload()}
    func record(capabilityId:String,instruction:String,error:String,projectId:UUID?){let clean=error.trimmingCharacters(in:.whitespacesAndNewlines);guard !clean.isEmpty else{return};failures.append(Failure(capabilityId:capabilityId,instruction:String(instruction.prefix(6000)),error:String(clean.prefix(6000)),projectId:projectId));if failures.count>10_000{failures.removeFirst(failures.count-10_000)};persist()}
    func warning(capabilityId:String,instruction:String,projectId:UUID?)->String?{let q=terms(instruction);guard q.count>=3 else{return nil};var best:(Failure,Double)?;for f in failures.reversed().prefix(500) where f.capabilityId==capabilityId{let t=terms(f.instruction);let overlap=q.intersection(t);let score=Double(overlap.count)/Double(q.count)+(projectId != nil && f.projectId==projectId ? 0.12:0);if score>=0.78 && (best==nil || score>best!.1){best=(f,min(score,1))}};guard let b=best else{return nil};return "PREVIOUS FAILED APPROACH (avoid repeating blindly):\nconfidence: \(Int(b.1*100))%\nprior instruction: \(b.0.instruction)\nprior failure: \(b.0.error)"}
    private func reload(){guard let d=try? Data(contentsOf:url),let s=try? JSONDecoder().decode(Snapshot.self,from:d),s.version==1 else{return};failures=s.failures}
    private func persist(){guard let d=try? JSONEncoder().encode(Snapshot(version:1,failures:failures)) else{return};try? d.write(to:url,options:.atomic)}
    private func terms(_ text:String)->Set<String>{Set(text.lowercased().folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).split{!$0.isLetter && !$0.isNumber}.map(String.init).filter{$0.count>=3})}
}
