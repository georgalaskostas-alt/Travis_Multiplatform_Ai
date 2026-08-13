import Foundation

/// Persistent-agent domain models. These are deliberately plain Codable
/// values for Runtime v1 so the execution semantics can stabilize before
/// they are committed to a versioned SwiftData schema.
struct AgentTask: Identifiable, Codable, Hashable {
    let id: UUID
    var goal: String
    var title: String
    var status: AgentTaskStatus
    var priority: AgentTaskPriority
    var plan: TaskPlan
    var executionState: TaskExecutionState
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var dueDate: Date?
    var failureReason: String?
    var artifacts: [TaskArtifact]
    var events: [TaskEvent]
    var budget: TaskExecutionBudget

    init(
        id: UUID = UUID(),
        goal: String,
        title: String? = nil,
        status: AgentTaskStatus = .pending,
        priority: AgentTaskPriority = .medium,
        plan: TaskPlan = TaskPlan(),
        executionState: TaskExecutionState = TaskExecutionState(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        dueDate: Date? = nil,
        failureReason: String? = nil,
        artifacts: [TaskArtifact] = [],
        events: [TaskEvent] = [],
        budget: TaskExecutionBudget = TaskExecutionBudget()
    ) {
        self.id = id
        self.goal = goal
        self.title = title ?? String(goal.prefix(72))
        self.status = status
        self.priority = priority
        self.plan = plan
        self.executionState = executionState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.dueDate = dueDate
        self.failureReason = failureReason
        self.artifacts = artifacts
        self.events = events
        self.budget = budget
    }
}

enum AgentTaskStatus: String, Codable, CaseIterable {
    case pending
    case planning
    case running
    case waitingForApproval
    case waitingForDependency
    case paused
    case completed
    case failed
    case cancelled
}

enum AgentTaskPriority: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case critical
}

struct TaskPlan: Identifiable, Codable, Hashable {
    let id: UUID
    var version: Int
    var summary: String
    var steps: [PlanStep]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        version: Int = 1,
        summary: String = "",
        steps: [PlanStep] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.version = version
        self.summary = summary
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct PlanStep: Identifiable, Codable, Hashable {
    let id: UUID
    var order: Int
    var title: String
    var instructions: String
    var status: PlanStepStatus
    var capabilityId: String?
    var dependencyStepIds: [UUID]
    var attemptCount: Int
    var maxAttempts: Int
    var startedAt: Date?
    var completedAt: Date?
    var lastError: String?
    var resultSummary: String?

    init(
        id: UUID = UUID(),
        order: Int,
        title: String,
        instructions: String = "",
        status: PlanStepStatus = .pending,
        capabilityId: String? = nil,
        dependencyStepIds: [UUID] = [],
        attemptCount: Int = 0,
        maxAttempts: Int = 3,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        lastError: String? = nil,
        resultSummary: String? = nil
    ) {
        self.id = id
        self.order = order
        self.title = title
        self.instructions = instructions
        self.status = status
        self.capabilityId = capabilityId
        self.dependencyStepIds = dependencyStepIds
        self.attemptCount = attemptCount
        self.maxAttempts = maxAttempts
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastError = lastError
        self.resultSummary = resultSummary
    }
}

enum PlanStepStatus: String, Codable, CaseIterable {
    case pending
    case ready
    case running
    case waitingForApproval
    case waitingForDependency
    case completed
    case failed
    case skipped
    case cancelled
}

struct TaskExecutionState: Codable, Hashable {
    var currentStepId: UUID?
    var lastCheckpoint: TaskCheckpoint?
    var consecutiveFailures: Int
    var replanCount: Int
    var lastHeartbeatAt: Date?
    var nextEligibleRunAt: Date?

    init(
        currentStepId: UUID? = nil,
        lastCheckpoint: TaskCheckpoint? = nil,
        consecutiveFailures: Int = 0,
        replanCount: Int = 0,
        lastHeartbeatAt: Date? = nil,
        nextEligibleRunAt: Date? = nil
    ) {
        self.currentStepId = currentStepId
        self.lastCheckpoint = lastCheckpoint
        self.consecutiveFailures = consecutiveFailures
        self.replanCount = replanCount
        self.lastHeartbeatAt = lastHeartbeatAt
        self.nextEligibleRunAt = nextEligibleRunAt
    }
}

struct TaskCheckpoint: Identifiable, Codable, Hashable {
    let id: UUID
    var taskId: UUID
    var stepId: UUID?
    var summary: String
    var nextAction: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        taskId: UUID,
        stepId: UUID? = nil,
        summary: String,
        nextAction: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.stepId = stepId
        self.summary = summary
        self.nextAction = nextAction
        self.createdAt = createdAt
    }
}

struct TaskEvent: Identifiable, Codable, Hashable {
    let id: UUID
    var type: TaskEventType
    var message: String
    var createdAt: Date

    init(id: UUID = UUID(), type: TaskEventType, message: String, createdAt: Date = Date()) {
        self.id = id
        self.type = type
        self.message = message
        self.createdAt = createdAt
    }
}

enum TaskEventType: String, Codable, CaseIterable {
    case created
    case planned
    case started
    case progress
    case checkpoint
    case approvalRequested
    case approvalGranted
    case approvalRejected
    case retry
    case replanned
    case paused
    case resumed
    case completed
    case failed
    case cancelled
}

struct TaskArtifact: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var kind: String
    var location: String?
    var summary: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: String,
        location: String? = nil,
        summary: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.summary = summary
        self.createdAt = createdAt
    }
}

struct TaskExecutionBudget: Codable, Hashable {
    var maxRuntimeSeconds: TimeInterval?
    var maxSteps: Int?
    var maxRetriesPerStep: Int
    var maxReplans: Int

    init(
        maxRuntimeSeconds: TimeInterval? = nil,
        maxSteps: Int? = 100,
        maxRetriesPerStep: Int = 3,
        maxReplans: Int = 10
    ) {
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.maxSteps = maxSteps
        self.maxRetriesPerStep = maxRetriesPerStep
        self.maxReplans = maxReplans
    }
}
