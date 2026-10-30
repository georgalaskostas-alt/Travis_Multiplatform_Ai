import Foundation

struct RuntimeSelfCheckResult: Equatable {
    var passed: Bool
    var checks: [String]
    var failures: [String]
}

@MainActor
enum RuntimeSelfCheck {
    static func run(appState: TRAVISAppState) -> RuntimeSelfCheckResult {
        var checks: [String] = []
        var failures: [String] = []
        let tasks = appState.taskRuntime.tasks
        let ids = tasks.map(\.id)

        if Set(ids).count == ids.count { checks.append("Task IDs are unique") }
        else { failures.append("Duplicate runtime task IDs detected") }

        let invalidPlans = tasks.filter { task in
            let orders = task.plan.steps.map(\.order)
            return Set(orders).count != orders.count
        }
        if invalidPlans.isEmpty { checks.append("Step ordering is unique within each mission") }
        else { failures.append("\(invalidPlans.count) mission(s) contain duplicate step order values") }

        let impossibleProgress = tasks.filter { task in
            let summary = MissionProgressSummary(task: task)
            return summary.completed > summary.total || summary.percent < 0 || summary.percent > 100
        }
        if impossibleProgress.isEmpty { checks.append("Mission progress invariants are valid") }
        else { failures.append("Invalid mission progress detected") }

        let executingMissing = tasks.filter { appState.taskExecutor.isTaskExecuting($0.id) && $0.status == .completed }
        if executingMissing.isEmpty { checks.append("No completed mission is still marked executing") }
        else { failures.append("Completed mission remains registered as executing") }

        return RuntimeSelfCheckResult(passed: failures.isEmpty, checks: checks, failures: failures)
    }
}
