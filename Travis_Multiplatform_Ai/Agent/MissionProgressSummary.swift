import Foundation

struct MissionProgressSummary: Equatable {
    var completed: Int
    var total: Int
    var percent: Int
    var currentStep: String?
    var nextStep: String?

    init(task: AgentTask) {
        let ordered = task.plan.steps.sorted { $0.order < $1.order }
        completed = ordered.filter { $0.status == .completed || $0.status == .skipped }.count
        total = ordered.count
        percent = total > 0 ? Int((Double(completed) / Double(total) * 100).rounded()) : (task.status == .completed ? 100 : 0)
        if let currentId = task.executionState.currentStepId { currentStep = ordered.first { $0.id == currentId }?.title }
        else { currentStep = ordered.first { $0.status == .running }?.title }
        nextStep = ordered.first { step in
            let key = step.status.rawValue.lowercased()
            return key == "pending" || key == "waitingfordependency" || key == "waitingforapproval"
        }?.title
    }
}
