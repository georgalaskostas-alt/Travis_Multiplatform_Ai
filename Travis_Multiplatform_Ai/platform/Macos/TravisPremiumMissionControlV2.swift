#if os(macOS)
import SwiftUI

struct TravisPremiumMissionControlV2: View {
    @Bindable var appState: TRAVISAppState
    @State private var selectedTaskID: UUID?

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(cyan.opacity(0.35))

            if runtimeTasks.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    taskList
                        .frame(minWidth: 360, idealWidth: 430, maxWidth: 500)
                    Divider().overlay(cyan.opacity(0.22))
                    detailPane
                }
            }
        }
        .background(workspaceBackground)
        .onAppear {
            if selectedTaskID == nil { selectedTaskID = runtimeTasks.first?.id }
        }
        .onChange(of: runtimeTasks.map(\.id)) { _, ids in
            if let selectedTaskID, ids.contains(selectedTaskID) { return }
            self.selectedTaskID = ids.first
        }
    }

    private var runtimeTasks: [AgentTask] {
        appState.taskRuntime.tasks.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private var selectedTask: AgentTask? {
        guard let selectedTaskID else { return nil }
        return runtimeTasks.first { $0.id == selectedTaskID }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope").foregroundStyle(cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("MISSION CONTROL V2")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.1)
                Text("DURABLE AUTONOMOUS RUNTIME")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(cyan.opacity(0.82))
            }
            Spacer()
            metric("TASKS", "\(runtimeTasks.count)")
            metric("RUNNING", "\(runtimeTasks.filter { $0.status == .running }.count)")
            metric("BLOCKED", "\(runtimeTasks.filter { $0.status == .waitingForApproval || $0.status == .waitingForDependency }.count)")
            metric("FAILED", "\(runtimeTasks.filter { $0.status == .failed }.count)")
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(LinearGradient(colors: [.white.opacity(0.05), navy.opacity(0.88), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom))
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(runtimeTasks) { task in
                    Button {
                        selectedTaskID = task.id
                    } label: {
                        taskCard(task)
                    }
                    .buttonStyle(.plain)
                    .help("Open task \(shortID(task))")
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let task = selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    taskDetailHeader(task)
                    controls(task)
                    progressPanel(task)
                    stepsPanel(task)
                    eventPanel(task)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a task")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func taskCard(_ task: AgentTask) -> some View {
        let selected = selectedTaskID == task.id
        let progress = appState.taskRuntime.progress(taskId: task.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Circle()
                    .fill(statusColor(task.status))
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor(task.status), radius: 4)
                Text(shortID(task))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(cyan)
                Text(task.status.rawValue.uppercased())
                    .font(.system(size: 7, weight: .heavy, design: .rounded))
                    .foregroundStyle(statusColor(task.status))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(task.title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
            ProgressView(value: progress)
                .tint(statusColor(task.status))
            if let checkpoint = task.executionState.lastCheckpoint?.summary, !checkpoint.isEmpty {
                Text(checkpoint)
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11).fill(selected ? cyan.opacity(0.10) : Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? cyan.opacity(0.75) : cyan.opacity(0.18), lineWidth: selected ? 1.4 : 1))
    }

    private func taskDetailHeader(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(task.title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                Spacer()
                statusBadge(task.status)
            }
            Text(task.goal)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                detailMetric("ID", shortID(task))
                detailMetric("PRIORITY", task.priority.rawValue.uppercased())
                detailMetric("PLAN", "v\(task.plan.version)")
                detailMetric("EVENTS", "\(task.events.count)")
            }
        }
        .padding(14)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    @ViewBuilder
    private func controls(_ task: AgentTask) -> some View {
        HStack(spacing: 8) {
            switch task.status {
            case .running:
                control("RUN STEP", "play.fill", .green) { appState.runAutonomousTask(reference: shortID(task), continuous: false) }
                control("AUTO", "forward.fill", cyan) { appState.runAutonomousTask(reference: shortID(task), continuous: true) }
                control("PAUSE", "pause.fill", .orange) { pause(task) }
                control("CANCEL", "xmark", .red) { appState.cancelAutonomousTask(reference: shortID(task)) }
            case .paused:
                control("RESUME", "play.fill", .green) { appState.resumeAutonomousTask(reference: shortID(task)) }
                control("CANCEL", "xmark", .red) { appState.cancelAutonomousTask(reference: shortID(task)) }
            case .failed:
                control("RETRY", "arrow.clockwise", .orange) { appState.retryAutonomousTask(reference: shortID(task)) }
                control("CANCEL", "xmark", .red) { appState.cancelAutonomousTask(reference: shortID(task)) }
            case .waitingForApproval, .waitingForDependency:
                control("PAUSE", "pause.fill", .orange) { pause(task) }
                control("CANCEL", "xmark", .red) { appState.cancelAutonomousTask(reference: shortID(task)) }
            case .pending:
                control("START", "play.fill", .green) { appState.taskRuntime.start(taskId: task.id) }
                control("CANCEL", "xmark", .red) { appState.cancelAutonomousTask(reference: shortID(task)) }
            case .planning:
                Text("Planning in progress…").font(.caption).foregroundStyle(.secondary)
            case .completed:
                Text("Mission completed").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.green)
            case .cancelled:
                Text("Mission cancelled").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func progressPanel(_ task: AgentTask) -> some View {
        let progress = appState.taskRuntime.progress(taskId: task.id)
        let completed = task.plan.steps.filter { $0.status == .completed || $0.status == .skipped }.count
        let current = task.executionState.currentStepId.flatMap { id in task.plan.steps.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 9) {
            sectionTitle("EXECUTION STATUS", "gauge.with.dots.needle.50percent")
            HStack {
                Text("PROGRESS").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Text("\(completed)/\(task.plan.steps.count) • \(Int(progress * 100))%")
                    .font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(cyan)
            }
            ProgressView(value: progress).tint(statusColor(task.status))
            if let current {
                Text("CURRENT: #\(current.order) — \(current.title)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            } else if let next = appState.taskRuntime.nextRunnableStep(taskId: task.id) {
                Text("NEXT: #\(next.order) — \(next.title)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if let failure = task.failureReason, !failure.isEmpty {
                Text("FAILURE: \(failure)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private func stepsPanel(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("PLAN STEPS", "list.number")
            ForEach(task.plan.steps.sorted { $0.order < $1.order }) { step in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: stepIcon(step.status))
                        .foregroundStyle(stepColor(step.status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("#\(step.order)  \(step.title)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                        HStack(spacing: 7) {
                            Text(step.status.rawValue.uppercased())
                            if step.requiresApproval { Text("APPROVAL") }
                            if let capability = step.capabilityId { Text(capability) }
                            Text("ATTEMPT \(step.attemptCount)/\(step.maxAttempts)")
                        }
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        if let error = step.lastError, !error.isEmpty {
                            Text(error).font(.system(size: 8, design: .rounded)).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 5)
            }
        }
        .padding(14)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private func eventPanel(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("RECENT RUNTIME EVENTS", "clock.arrow.circlepath")
            ForEach(Array(task.events.suffix(12).reversed())) { event in
                HStack(alignment: .top, spacing: 8) {
                    Text(event.createdAt, style: .time)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    Text(event.type.rawValue.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(eventColor(event.type))
                        .frame(width: 82, alignment: .leading)
                    Text(event.message)
                        .font(.system(size: 8, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                        .textSelection(.enabled)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope").font(.system(size: 42)).foregroundStyle(cyan.opacity(0.7))
            Text("NO AUTONOMOUS MISSIONS")
                .font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(cyan)
            Text("Create a mission from TRAVIS Chat or New Mission.")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pause(_ task: AgentTask) {
        if appState.taskExecutor.isTaskExecuting(task.id) {
            _ = appState.taskExecutor.requestCancellation(taskId: task.id, reason: "Pause requested by user")
        }
        appState.taskRuntime.pause(taskId: task.id, reason: "Paused by user from Mission Control")
        appState.lastResponseSummary = "Paused task \(shortID(task))"
    }

    private func control(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.38), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(title.capitalized)
        .accessibilityLabel(title.capitalized)
    }

    private func sectionTitle(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(cyan)
            Text(title).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(0.6)
            Spacer()
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title).font(.system(size: 6, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: 58)
    }

    private func detailMetric(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.system(size: 6, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundStyle(.white)
        }
    }

    private func statusBadge(_ status: AgentTaskStatus) -> some View {
        Text(status.rawValue.uppercased())
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(statusColor(status).opacity(0.08)))
            .overlay(Capsule().stroke(statusColor(status).opacity(0.38), lineWidth: 1))
    }

    private func shortID(_ task: AgentTask) -> String { String(task.id.uuidString.prefix(8)) }

    private func statusColor(_ status: AgentTaskStatus) -> Color {
        switch status {
        case .running: return .green
        case .waitingForApproval, .waitingForDependency: return .yellow
        case .paused, .planning, .pending: return .orange
        case .failed: return .red
        case .completed: return cyan
        case .cancelled: return .secondary
        }
    }

    private func stepColor(_ status: PlanStepStatus) -> Color {
        switch status {
        case .completed: return .green
        case .running: return cyan
        case .waitingForApproval, .waitingForDependency: return .yellow
        case .failed: return .red
        case .cancelled, .skipped: return .secondary
        case .pending, .ready: return .orange
        }
    }

    private func stepIcon(_ status: PlanStepStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .running: return "bolt.circle.fill"
        case .waitingForApproval: return "lock.circle.fill"
        case .waitingForDependency: return "link.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle.fill"
        case .skipped: return "forward.end.circle"
        case .pending, .ready: return "circle"
        }
    }

    private func eventColor(_ type: TaskEventType) -> Color {
        switch type {
        case .failed, .approvalRejected: return .red
        case .completed, .approvalGranted: return .green
        case .paused, .retry: return .orange
        case .approvalRequested: return .yellow
        default: return cyan
        }
    }

    private var panelBackground: some ShapeStyle {
        LinearGradient(colors: [.white.opacity(0.045), cyan.opacity(0.025), Color.black.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 12).stroke(cyan.opacity(0.22), lineWidth: 1)
    }

    private var workspaceBackground: some View {
        LinearGradient(colors: [Color(red:0.002,green:0.014,blue:0.052), Color(red:0.002,green:0.027,blue:0.090), Color.black.opacity(0.96)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
#endif
