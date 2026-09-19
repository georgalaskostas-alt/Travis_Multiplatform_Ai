import Foundation

@MainActor
extension TRAVISAppState {
    func handleSchedulingIntent(_ text: String, recentHistory: [ChatMessage]) async -> Bool {
        let router = SchedulingIntentRouter()
        switch await router.classify(text, recentHistory: recentHistory) {
        case .none:
            return false
        case .list:
            let coordinator = DeferredWorkCoordinator()
            addAssistantMessage(coordinator.diagnosticReport())
            return true
        case .runDue:
            await runDueScheduledWork(recentHistory: recentHistory)
            return true
        case .cancel(let reference):
            cancelScheduledWork(reference: reference)
            return true
        case .schedule(let taskReference, let runAt, let recurrenceSeconds):
            scheduleAutonomousTask(reference: taskReference, runAt: runAt, recurrenceSeconds: recurrenceSeconds)
            return true
        }
    }

    func scheduleAutonomousTask(reference: String?, runAt: Date, recurrenceSeconds: TimeInterval?) {
        let effectiveReference: String?
        if let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveReference = reference
        } else if taskRuntime.tasks.contains(where: { $0.status == .running }) {
            effectiveReference = "running"
        } else if taskRuntime.tasks.contains(where: { $0.status == .paused }) {
            effectiveReference = "paused"
        } else {
            effectiveReference = nil
        }

        switch resolveRuntimeTask(reference: effectiveReference) {
        case .notFound:
            addAssistantMessage("Δεν βρέθηκε autonomous task για scheduling. Χρησιμοποίησε /tasks για να δεις τα διαθέσιμα tasks.")
        case .ambiguous(let tasks):
            let rows = tasks.prefix(8).map {
                "\($0.id.uuidString.prefix(8)) [\($0.status.rawValue)] — \($0.title)"
            }.joined(separator: "\n")
            addAssistantMessage("Βρήκα περισσότερα από ένα πιθανά tasks και δεν θα επιλέξω αυθαίρετα:\n\n\(rows)\n\nΔώσε πιο συγκεκριμένη αναφορά ή short ID.")
        case .found(let task):
            let recurrence: DeferredWorkRecurrence = recurrenceSeconds.map { .interval(seconds: max(60, $0)) } ?? .none
            let coordinator = DeferredWorkCoordinator()
            let item = coordinator.schedule(
                taskId: task.id,
                title: task.title,
                runAt: runAt,
                recurrence: recurrence
            )

            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = TimeZone.current
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let recurrenceText: String
            if let recurrenceSeconds {
                recurrenceText = "κάθε \(humanInterval(recurrenceSeconds))"
            } else {
                recurrenceText = "one-shot"
            }

            addAssistantMessage("""
            AUTONOMOUS TASK SCHEDULED

            SCHEDULE ID
            \(String(item.id.uuidString.prefix(8)))

            TASK
            \(String(task.id.uuidString.prefix(8))) — \(task.title)

            FIRST RUN
            \(formatter.string(from: runAt))

            RECURRENCE
            \(recurrenceText)
            """)
            lastResponseSummary = "Task scheduled for \(formatter.string(from: runAt))"
        }
    }

    func cancelScheduledWork(reference: String) {
        let coordinator = DeferredWorkCoordinator()
        let normalized = reference.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = coordinator.items.filter { item in
            item.id.uuidString.lowercased().hasPrefix(normalized) ||
            item.title.lowercased().contains(normalized)
        }

        guard !matches.isEmpty else {
            addAssistantMessage("Δεν βρέθηκε scheduled job που να ταιριάζει με '\(reference)'.")
            return
        }
        guard matches.count == 1, let match = matches.first else {
            let rows = matches.prefix(8).map { "\($0.id.uuidString.prefix(8)) [\($0.status.rawValue)] — \($0.title)" }.joined(separator: "\n")
            addAssistantMessage("Βρήκα περισσότερα από ένα scheduled jobs:\n\n\(rows)\n\nΔώσε το short schedule ID.")
            return
        }

        coordinator.cancel(id: match.id)
        addAssistantMessage("SCHEDULE CANCELLED\n\n\(String(match.id.uuidString.prefix(8))) — \(match.title)")
    }

    func runDueScheduledWork(recentHistory: [ChatMessage] = []) async {
        let coordinator = DeferredWorkCoordinator()
        let report = await coordinator.dispatchDue(
            runtime: taskRuntime,
            executor: taskExecutor,
            recentHistory: recentHistory,
            limit: 4
        )

        let projectMemory = ProjectMemoryCoordinator()
        for itemId in report.completedIds {
            guard let item = coordinator.items.first(where: { $0.id == itemId }) else { continue }
            await projectMemory.synchronize(taskId: item.taskId, runtime: taskRuntime)
        }

        addAssistantMessage("""
        DEFERRED WORK DISPATCH COMPLETE

        CONSIDERED
        \(report.consideredIds.count)

        EXECUTED
        \(report.executedIds.count)

        COMPLETED / RESCHEDULED
        \(report.completedIds.count)

        FAILED
        \(report.failedIds.count)

        SKIPPED / WAITING
        \(report.skippedIds.count)
        """)
    }

    private func humanInterval(_ seconds: TimeInterval) -> String {
        let seconds = max(60, Int(seconds))
        if seconds % 86_400 == 0 { return "\(seconds / 86_400) ημέρα/ες" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600) ώρα/ες" }
        if seconds % 60 == 0 { return "\(seconds / 60) λεπτά" }
        return "\(seconds) δευτερόλεπτα"
    }
}
