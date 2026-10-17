import Foundation

enum AIExecutionScope {
    @TaskLocal static var context: AIInvocationContext = AIInvocationContext(
        workload: .routine,
        capabilityId: nil,
        taskId: nil,
        stepId: nil,
        projectId: nil,
        operation: nil
    )
}
