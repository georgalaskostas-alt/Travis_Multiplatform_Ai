import Foundation

/// Mission-level critic that never buys AI when runtime evidence is sufficient.
/// It checks plan closure, verification evidence, mutation approvals and known failures.
enum MissionCriticV6 {
    struct Finding: Codable, Hashable {
        enum Severity:String,Codable{case info,warning,blocker}
        let severity:Severity
        let message:String
    }
    struct Report:Codable,Hashable {
        let passed:Bool
        let confidence:Double
        let findings:[Finding]
        let summary:String
    }

    static func review(_ task:AgentTask)->Report {
        var findings:[Finding]=[]
        let steps=task.plan.steps.sorted{$0.order<$1.order}
        if steps.isEmpty { findings.append(.init(severity:.blocker,message:"Mission has no executable plan.")) }
        for step in steps {
            switch step.status {
            case .completed,.skipped: break
            default: findings.append(.init(severity:.blocker,message:"Step #\(step.order) is not terminally verified (\(step.status.rawValue))."))
            }
            if step.status == .completed {
                let result=step.resultSummary?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                if result.isEmpty { findings.append(.init(severity:.warning,message:"Step #\(step.order) completed without durable result evidence.")) }
            }
            if step.requiresApproval && step.status == .completed && step.riskLevel == .critical {
                findings.append(.init(severity:.info,message:"Critical step #\(step.order) reached completion through the approval-gated runtime path."))
            }
        }
        if task.failureReason != nil { findings.append(.init(severity:.blocker,message:"Task still carries a failure reason despite completion review.")) }
        let blockers=findings.filter{$0.severity == .blocker}.count
        let warnings=findings.filter{$0.severity == .warning}.count
        let evidence=steps.filter{$0.status == .completed && !($0.resultSummary?.isEmpty ?? true)}.count
        let coverage=steps.isEmpty ? 0:Double(evidence)/Double(steps.count)
        let confidence=max(0,min(1,0.70+coverage*0.30-Double(warnings)*0.04-Double(blockers)*0.25))
        let passed=blockers==0
        return .init(passed:passed,confidence:confidence,findings:findings,summary:passed ? "Mission closure is structurally verified; evidence coverage \(Int(coverage*100))%.":"Mission closure has \(blockers) blocker(s) and must not be treated as fully verified.")
    }
}
