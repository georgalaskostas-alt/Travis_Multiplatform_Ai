import Foundation
import Observation

@MainActor
@Observable
final class DeferredWorkCoordinator {
    private(set) var items: [DeferredWorkItem] = []
    private(set) var persistenceError: String?

    private let store: DeferredWorkStore

    init(store: DeferredWorkStore = .shared) {
        self.store = store
        reload()
    }

    @discardableResult
    func schedule(
        taskId: UUID,
        title: String,
        runAt: Date,
        recurrence: DeferredWorkRecurrence = .none
    ) -> DeferredWorkItem {
        var item = DeferredWorkItem(
            taskId: taskId,
            title: title,
            runAt: runAt,
            recurrence: recurrence
        )
        item.nextRunAt = runAt
        items.append(item)
        persist()
        return item
    }

    func cancel(id: UUID) {
        mutate(id) { item in
            guard item.status != .completed else { return }
            item.status = .cancelled
            item.updatedAt = Date()
        }
    }

    func dueItems(now: Date = Date(), limit: Int = 8) -> [DeferredWorkItem] {
        items
            .filter { $0.status == .scheduled && $0.effectiveRunAt <= now }
            .sorted {
                if $0.effectiveRunAt != $1.effectiveRunAt { return $0.effectiveRunAt < $1.effectiveRunAt }
                return $0.createdAt < $1.createdAt
            }
            .prefix(max(1, min(limit, 32)))
            .map { $0 }
    }

    struct DispatchReport: Hashable {
        var consideredIds: [UUID] = []
        var executedIds: [UUID] = []
        var completedIds: [UUID] = []
        var failedIds: [UUID] = []
        var skippedIds: [UUID] = []
    }

    @discardableResult
    func dispatchDue(
        runtime: AgentTaskRuntime,
        executor: AgentTaskExecutor,
        recentHistory: [ChatMessage] = [],
        now: Date = Date(),
        limit: Int = 4
    ) async -> DispatchReport {
        let due = dueItems(now: now, limit: limit)
        var report = DispatchReport(consideredIds: due.map(\.id))

        for item in due {
            guard let task = runtime.task(id: item.taskId) else {
                markFailed(id: item.id, error: "Referenced autonomous task no longer exists.")
                report.failedIds.append(item.id)
                continue
            }

            guard !executor.isTaskExecuting(task.id) else {
                report.skippedIds.append(item.id)
                continue
            }

            switch task.status {
            case .paused:
                runtime.resume(taskId: task.id)
            case .pending:
                runtime.start(taskId: task.id)
            case .running:
                break
            case .completed:
                completeOrReschedule(id: item.id, now: now)
                report.completedIds.append(item.id)
                continue
            case .planning, .waitingForApproval, .waitingForDependency, .failed, .cancelled:
                report.skippedIds.append(item.id)
                continue
            }

            mutate(item.id) { value in
                value.status = .running
                value.lastRunAt = now
                value.runCount += 1
                value.updatedAt = now
                value.lastError = nil
            }

            do {
                let runReport = try await executor.executeUntilBlocked(
                    taskId: task.id,
                    recentHistory: recentHistory,
                    maxStepsPerCycle: 8
                )
                report.executedIds.append(item.id)

                switch runReport.stopReason {
                case .completed:
                    completeOrReschedule(id: item.id, now: now)
                    report.completedIds.append(item.id)
                case .failed, .budgetExceeded:
                    markFailed(id: item.id, error: runReport.failureReason ?? runReport.stopReason.rawValue)
                    report.failedIds.append(item.id)
                case .waitingForApproval, .paused, .noRunnableStep, .safetyStepLimitReached:
                    mutate(item.id) { value in
                        value.status = .scheduled
                        value.nextRunAt = Date().addingTimeInterval(60)
                        value.updatedAt = Date()
                    }
                    report.skippedIds.append(item.id)
                }
            } catch {
                markFailed(id: item.id, error: error.localizedDescription)
                report.failedIds.append(item.id)
            }
        }

        return report
    }

    func diagnosticReport(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = items
            .sorted { $0.effectiveRunAt < $1.effectiveRunAt }
            .prefix(30)
            .map { item in
                let due = item.effectiveRunAt <= now ? "DUE" : formatter.string(from: item.effectiveRunAt)
                return "\(item.id.uuidString.prefix(8)) [\(item.status.rawValue)] task=\(item.taskId.uuidString.prefix(8)) next=\(due) runs=\(item.runCount) — \(item.title)"
            }
            .joined(separator: "\n")
        return rows.isEmpty ? "Δεν υπάρχουν scheduled autonomous jobs." : "DEFERRED WORK\n\n\(rows)"
    }

    func reload() {
        do {
            items = try store.load()
            persistenceError = nil
        } catch {
            items = []
            persistenceError = error.localizedDescription
        }
    }

    private func completeOrReschedule(id: UUID, now: Date) {
        mutate(id) { item in
            switch item.recurrence {
            case .none:
                item.status = .completed
                item.nextRunAt = nil
            case .interval(let seconds):
                item.status = .scheduled
                item.nextRunAt = now.addingTimeInterval(max(60, seconds))
            }
            item.updatedAt = now
            item.lastError = nil
        }
    }

    private func markFailed(id: UUID, error: String) {
        mutate(id) { item in
            item.status = .failed
            item.lastError = error
            item.updatedAt = Date()
        }
    }

    private func mutate(_ id: UUID, _ body: (inout DeferredWorkItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
        persist()
    }

    private func persist() {
        do {
            try store.save(items)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}
