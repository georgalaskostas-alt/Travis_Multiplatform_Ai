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

        // Goal-closure gate: a mission is not complete merely because every step
        // reached a terminal state. At least one completed step must provide
        // durable evidence that plausibly addresses the user's original goal.
        let goalTerms=meaningfulTerms(task.goal)
        let completedEvidence=steps.compactMap { step -> String? in
            guard step.status == .completed else { return nil }
            let result=step.resultSummary?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            guard !result.isEmpty else { return nil }
            return (step.title+" "+step.instructions+" "+result).folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).lowercased()
        }
        if completedEvidence.isEmpty {
            findings.append(.init(severity:.blocker,message:"Mission has no durable completed evidence supporting goal closure."))
        } else if !goalTerms.isEmpty {
            let matched=goalTerms.filter { term in completedEvidence.contains(where:{$0.contains(term)}) }
            let required=min(2,goalTerms.count)
            if matched.count < required {
                findings.append(.init(severity:.blocker,message:"Completed evidence does not sufficiently connect back to the original goal (\(matched.count)/\(required) goal terms evidenced)."))
            }
        }
        let blockers=findings.filter{$0.severity == .blocker}.count
        let warnings=findings.filter{$0.severity == .warning}.count
        let evidence=steps.filter{$0.status == .completed && !($0.resultSummary?.isEmpty ?? true)}.count
        let coverage=steps.isEmpty ? 0:Double(evidence)/Double(steps.count)
        let confidence=max(0,min(1,0.70+coverage*0.30-Double(warnings)*0.04-Double(blockers)*0.25))
        let passed=blockers==0
        return .init(passed:passed,confidence:confidence,findings:findings,summary:passed ? "Mission closure is structurally verified; evidence coverage \(Int(coverage*100))%.":"Mission closure has \(blockers) blocker(s) and must not be treated as fully verified.")
    }

    static func recoveryContext(_ task:AgentTask)->String {
        let report=review(task)
        let blockers=report.findings.filter{$0.severity == .blocker}.map{"- "+$0.message}
        let warnings=report.findings.filter{$0.severity == .warning}.map{"- "+$0.message}
        let missing=meaningfulTerms(task.goal).filter { term in
            !task.plan.steps.contains { step in
                guard step.status == .completed,let result=step.resultSummary,!result.isEmpty else{return false}
                let evidence=(step.title+" "+step.instructions+" "+result).folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).lowercased()
                return evidence.contains(term)
            }
        }
        return """
        GOAL-CLOSURE DIAGNOSIS
        Original goal: \(task.goal)
        Critic confidence: \(Int(report.confidence*100))%
        Blockers:
        \(blockers.isEmpty ? "- None":blockers.joined(separator:"\n"))
        Warnings:
        \(warnings.isEmpty ? "- None":warnings.joined(separator:"\n"))
        Goal concepts without durable evidence:
        \(missing.isEmpty ? "- None":missing.prefix(12).map{"- "+$0}.joined(separator:"\n"))
        Recovery requirement: preserve verified completed work and add only the minimum evidence/action needed to close these specific gaps.
        """
    }

    private static func meaningfulTerms(_ text:String)->[String] {
        let stop:Set<String>=["the","and","for","with","from","that","this","στο","στη","στην","του","της","των","και","για","απο","από","ένα","μια","την","τον","τα","το","σε","με"]
        let normalized=text.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).lowercased()
        var seen=Set<String>()
        return normalized.split{!$0.isLetter && !$0.isNumber}.map(String.init).filter{$0.count>=4 && !stop.contains($0)}.filter{seen.insert($0).inserted}
    }
}
