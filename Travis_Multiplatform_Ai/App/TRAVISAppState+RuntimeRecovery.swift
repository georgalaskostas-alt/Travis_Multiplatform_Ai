import Foundation

@MainActor
extension TRAVISAppState {
    /// Explicitly resumes the most recently recovered/paused autonomous task.
    ///
    /// Recovery never auto-executes work after relaunch. A task restored from
    /// disk remains paused until the user explicitly requests continuation.
    /// This avoids assuming that an interrupted capability had no side effects.
    func resumeRecoveredAutonomousTask() {
        guard let recoveredTask = taskRuntime.tasks.last(where: { $0.status == .paused }) else {
            addAssistantMessage("Δεν υπάρχει paused autonomous task για συνέχιση.")
            lastResponseSummary = "No paused autonomous task"
            return
        }

        let checkpoint = recoveredTask.executionState.lastCheckpoint?.summary ?? "κανένα"
        let progressPercent = Int(taskRuntime.progress(taskId: recoveredTask.id) * 100)

        taskRuntime.resume(taskId: recoveredTask.id)

        guard let resumedTask = taskRuntime.task(id: recoveredTask.id) else {
            addAssistantMessage("Το recovered runtime task δεν βρέθηκε μετά το resume.")
            lastResponseSummary = "Runtime resume failed"
            return
        }

        let nextStep = taskRuntime.nextRunnableStep(taskId: resumedTask.id)
        let nextText = nextStep.map { "#\($0.order) — \($0.title)" } ?? "κανένα"

        let response = """
        AUTONOMOUS TASK RECOVERED

        TASK
        \(resumedTask.id.uuidString)

        STATUS
        \(resumedTask.status.rawValue)

        RECOVERY
        Recovered from durable snapshot after application/process restart.
        Continuation required explicit /resume.

        PROGRESS
        \(progressPercent)%

        LAST VERIFIED CHECKPOINT
        \(checkpoint)

        NEXT RUNNABLE STEP
        \(nextText)

        Το task είναι ξανά διαθέσιμο για /run ή /auto.
        """

        addAssistantMessage(response)
        lastResponseSummary = "Recovered task resumed — \(progressPercent)%"
    }
}
