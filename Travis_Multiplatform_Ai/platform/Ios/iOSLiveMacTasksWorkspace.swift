#if os(iOS)

import SwiftUI
import UserNotifications
import UIKit

struct iOSLiveMacTasksWorkspace: View {
    @Bindable var appState: TRAVISAppState
    @State private var bridge = TravisDeviceBridgeService.shared
    @State private var expandedTaskIDs: Set<UUID> = []
    @State private var pendingDeleteTask: TravisBridgeTaskSnapshot?
    @State private var showDeleteTaskAlert = false
    @State private var showDeleteAllAlert = false
    @State private var terminalTaskIDs: Set<UUID> = []
    @State private var didSeedNotificationState = false
    @State private var completionToast: String?

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

    private var macTasks: [TravisBridgeTaskSnapshot] {
        guard bridge.isConnected else { return [] }
        return (bridge.lastStatus?.runtimeTasks ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    private var localTasks: [AgentTask] {
        appState.taskRuntime.tasks.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var usingMac: Bool { bridge.isConnected }
    private var activeMacTasks: Int { bridge.lastStatus?.activeRuntimeTasks ?? 0 }
    private var canDeleteHistory: Bool { usingMac && activeMacTasks == 0 }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color.black, navy, panel.opacity(0.92), navy], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 13) {
                    header
                    summaryGrid
                    if usingMac && !macTasks.isEmpty { historyActions }

                    if usingMac {
                        if macTasks.isEmpty { emptyMacState }
                        else { ForEach(macTasks) { macTaskCard($0) } }
                    } else {
                        if localTasks.isEmpty { emptyLocalState }
                        else { ForEach(localTasks) { localTaskCard($0) } }
                    }

                    runtimeCard
                }
                .padding(14)
                .padding(.bottom, 28)
            }

            if let completionToast {
                completionBanner(completionToast)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            requestNotificationAuthorization()
            while !Task.isCancelled {
                if bridge.isConnected {
                    bridge.requestStatus()
                    try? await Task.sleep(for: .milliseconds(350))
                    processTerminalTaskChanges()
                }
                try? await Task.sleep(for: .milliseconds(1650))
            }
        }
        .alert("Delete task?", isPresented: $showDeleteTaskAlert, presenting: pendingDeleteTask) { task in
            Button("Delete", role: .destructive) { deleteTask(task) }
            Button("Cancel", role: .cancel) { pendingDeleteTask = nil }
        } message: { task in
            Text("Delete \(task.title) from the Mac TRAVIS runtime history?")
        }
        .alert("Delete all task history?", isPresented: $showDeleteAllAlert) {
            Button("Delete All", role: .destructive) { deleteAllTasks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all completed, failed and cancelled runtime tasks. Active missions must be finished or cancelled first.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(cyan.opacity(0.09)).frame(width: 48, height: 48)
                RoundedRectangle(cornerRadius: 12).stroke(cyan.opacity(0.48), lineWidth: 1).frame(width: 48, height: 48)
                Image(systemName: "checklist").font(.system(size: 20, weight: .bold)).foregroundStyle(cyan)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("TASK CONTROL").font(.system(size: 19, weight: .heavy, design: .rounded)).tracking(1)
                Text(usingMac ? "CONNECTED MAC RUNTIME" : "LOCAL FALLBACK")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(usingMac ? Color.green : Color.orange)
            }
            Spacer()
            Circle().fill(usingMac ? Color.green : Color.orange).frame(width: 7, height: 7)
                .shadow(color: usingMac ? .green : .orange, radius: 5)
        }
        .padding(14)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    private var summaryGrid: some View {
        let statuses = usingMac ? macTasks.map { normalize($0.status) } : localTasks.map { normalize($0.status.rawValue) }
        let running = statuses.filter { $0 == "running" || $0 == "planning" }.count
        let waiting = statuses.filter { ["waitingforapproval", "waitingfordependency", "paused", "pending"].contains($0) }.count
        let completed = statuses.filter { $0 == "completed" }.count
        let failed = statuses.filter { $0 == "failed" || $0 == "cancelled" }.count

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            summaryTile("RUNNING", running, .green)
            summaryTile("WAITING", waiting, .orange)
            summaryTile("COMPLETED", completed, cyan)
            summaryTile("FAILED", failed, .red)
        }
    }

    private var historyActions: some View {
        HStack(spacing: 10) {
            Label(canDeleteHistory ? "HISTORY READY" : "ACTIVE MISSIONS PROTECTED", systemImage: canDeleteHistory ? "checkmark.shield" : "shield.fill")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(canDeleteHistory ? Color.green : Color.orange)
            Spacer()
            Button {
                showDeleteAllAlert = true
            } label: {
                Label("DELETE ALL", systemImage: "trash.fill")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(canDeleteHistory ? Color.red : Color.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Capsule().fill(Color.red.opacity(canDeleteHistory ? 0.09 : 0.03)))
                    .overlay(Capsule().stroke(Color.red.opacity(canDeleteHistory ? 0.35 : 0.10), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .disabled(!canDeleteHistory)
        }
        .padding(11)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    private var emptyMacState: some View {
        emptyState(title: "NO MAC RUNTIME TASKS", detail: "Mac TRAVIS is connected. New missions will appear here live.")
    }

    private var emptyLocalState: some View {
        emptyState(title: "NO LOCAL TASKS", detail: "Mac TRAVIS is offline. Showing the iPhone local runtime fallback.")
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(cyan)
            Text(title).font(.system(size: 13, weight: .heavy, design: .rounded))
            Text(detail).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    private func macTaskCard(_ task: TravisBridgeTaskSnapshot) -> some View {
        let progress = task.totalSteps > 0 ? Double(task.completedSteps) / Double(task.totalSteps) : 0
        let percent = Int(progress * 100)
        let expanded = expandedTaskIDs.contains(task.id)
        let statusKey = normalize(task.status)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(String(task.id.uuidString.prefix(8)).uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(cyan)
                        Text("• \(percent)%")
                            .font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                    }
                    Text(task.title).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(2)
                    Text(task.goal).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 8)
                statusBadge(task.status)
            }

            VStack(spacing: 5) {
                ProgressView(value: progress).tint(statusColor(task.status))
                HStack {
                    Text("\(task.completedSteps)/\(task.totalSteps) STEPS • \(percent)%")
                    Spacer()
                    Text(task.priority.uppercased())
                }
                .font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }

            if statusKey == "planning" {
                detailRow("MISSION STATE", "Planning executable steps…", "brain.head.profile")
            }
            if let step = task.currentStep, !step.isEmpty { detailRow("CURRENT STEP", step, "bolt.fill") }
            if task.currentStep == nil, let next = nextPendingStep(task) {
                detailRow("NEXT STEP", "#\(next.order) — \(next.title)", "arrow.right.circle")
            }
            if let checkpoint = task.checkpoint, !checkpoint.isEmpty { detailRow("LAST CHECKPOINT", checkpoint, "flag.checkered") }
            if let failure = task.failureReason, !failure.isEmpty { detailRow("FAILURE", failure, "exclamationmark.triangle.fill") }

            remoteControls(task)

            if let steps = task.steps, !steps.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expanded { expandedTaskIDs.remove(task.id) } else { expandedTaskIDs.insert(task.id) }
                    }
                } label: {
                    HStack {
                        Label(expanded ? "HIDE PLAN" : "SHOW PLAN", systemImage: expanded ? "chevron.up" : "list.number")
                        Spacer()
                        Text("\(steps.count) STEPS")
                    }
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(cyan)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if expanded { planSteps(steps) }
            }

            if let report = task.finalReport, !report.isEmpty { finalReportBlock(report) }

            if ["completed", "failed", "cancelled"].contains(statusKey) {
                HStack {
                    Spacer()
                    Button {
                        pendingDeleteTask = task
                        showDeleteTaskAlert = true
                    } label: {
                        Label("DELETE TASK", systemImage: "trash")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundStyle(canDeleteHistory ? Color.red : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDeleteHistory)
                }
            }
        }
        .padding(13)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    @ViewBuilder
    private func remoteControls(_ task: TravisBridgeTaskSnapshot) -> some View {
        let key = normalize(task.status)
        HStack(spacing: 7) {
            switch key {
            case "running":
                controlButton("PAUSE", "pause.fill", .orange) { sendRemote("/remote-pause-task \(task.id.uuidString)") }
                controlButton("CANCEL", "xmark", .red) { sendRemote("/remote-cancel-task \(task.id.uuidString)") }
            case "paused":
                controlButton("RESUME", "play.fill", .green) { sendRemote("/remote-resume-task \(task.id.uuidString)") }
                controlButton("CANCEL", "xmark", .red) { sendRemote("/remote-cancel-task \(task.id.uuidString)") }
            case "waitingforapproval", "waitingfordependency":
                controlButton("PAUSE", "pause.fill", .orange) { sendRemote("/remote-pause-task \(task.id.uuidString)") }
                controlButton("CANCEL", "xmark", .red) { sendRemote("/remote-cancel-task \(task.id.uuidString)") }
            case "failed":
                controlButton("RETRY", "arrow.clockwise", .orange) { sendRemote("/remote-retry-task \(task.id.uuidString)") }
            default:
                EmptyView()
            }
            Spacer()
        }
    }

    private func planSteps(_ steps: [TravisBridgeStepSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps.sorted { $0.order < $1.order }) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: stepIcon(step.status))
                        .foregroundStyle(stepColor(step.status))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(step.order)  \(step.title)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                        HStack(spacing: 6) {
                            Text(step.status.uppercased())
                            if let capability = step.capability { Text(capability) }
                            Text("TRY \(step.attemptCount)/\(step.maxAttempts)")
                            if step.requiresApproval { Text("APPROVAL") }
                        }
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        if let error = step.lastError, !error.isEmpty {
                            Text(error).font(.system(size: 8, design: .rounded)).foregroundStyle(.red).lineLimit(3)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.16), lineWidth: 0.7))
    }

    private func localTaskCard(_ task: AgentTask) -> some View {
        let completed = task.plan.steps.filter { $0.status == .completed }.count
        let total = task.plan.steps.count
        let progress = total > 0 ? Double(completed) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(2)
                    Text(task.goal).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 8)
                statusBadge(task.status.rawValue)
            }
            ProgressView(value: progress).tint(cyan)
            HStack {
                Text("\(completed)/\(total) STEPS • \(Int(progress * 100))%")
                Spacer()
                Text(task.priority.rawValue.uppercased())
            }.font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
        }
        .padding(13)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    private func detailRow(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: icon).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(label == "FAILURE" ? .red : cyan)
            Text(value).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.82)).lineLimit(5)
        }
        .padding(.top, 2)
    }

    private func finalReportBlock(_ report: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("FINAL REPORT", systemImage: "doc.text.fill")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.green)
            Text(report)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.22), lineWidth: 0.8))
        .padding(.top, 3)
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("MAC TRAVIS", systemImage: "desktopcomputer").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(cyan)
                Spacer()
                Text(bridge.isConnected ? "CONNECTED" : "OFFLINE").font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundStyle(bridge.isConnected ? .green : .orange)
            }
            if let status = bridge.lastStatus, bridge.isConnected {
                HStack {
                    Text("ACTIVE RUNTIME TASKS")
                    Spacer()
                    Text("\(status.activeRuntimeTasks)").foregroundStyle(cyan)
                }.font(.system(size: 11, weight: .bold, design: .rounded))
                if !status.lastSummary.isEmpty { Text(status.lastSummary).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(4) }
            } else {
                Text("Waiting for Mac runtime connection…").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    private func completionBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("MISSION READY").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.green)
                Text(text).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.55), lineWidth: 1))
        .shadow(color: .green.opacity(0.22), radius: 12)
    }

    private func summaryTile(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.24), lineWidth: 0.8))
    }

    private func statusBadge(_ status: String) -> some View {
        let color = statusColor(status)
        return Text(status.replacingOccurrences(of: "waitingFor", with: "WAIT ").uppercased())
            .font(.system(size: 7, weight: .heavy, design: .rounded)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.7))
    }

    private func statusColor(_ status: String) -> Color {
        switch normalize(status) {
        case "completed": return .green
        case "failed", "cancelled": return .red
        case "running", "planning": return cyan
        case "waitingforapproval", "waitingfordependency", "paused", "pending": return .orange
        default: return .secondary
        }
    }

    private func stepIcon(_ status: String) -> String {
        switch normalize(status) {
        case "completed": return "checkmark.circle.fill"
        case "running": return "bolt.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "waitingforapproval": return "lock.circle.fill"
        case "cancelled": return "minus.circle.fill"
        default: return "circle"
        }
    }

    private func stepColor(_ status: String) -> Color {
        switch normalize(status) {
        case "completed": return .green
        case "running": return cyan
        case "failed": return .red
        case "waitingforapproval": return .orange
        default: return .secondary
        }
    }

    private func nextPendingStep(_ task: TravisBridgeTaskSnapshot) -> TravisBridgeStepSnapshot? {
        task.steps?.sorted { $0.order < $1.order }.first {
            let key = normalize($0.status)
            return key == "pending" || key == "ready"
        }
    }

    private func controlButton(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func sendRemote(_ command: String) {
        guard bridge.isConnected else { return }
        bridge.sendCommandToMac(command)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            bridge.requestStatus()
        }
    }

    private func deleteTask(_ task: TravisBridgeTaskSnapshot) {
        pendingDeleteTask = nil
        sendRemote("/remote-delete-task \(task.id.uuidString)")
    }

    private func deleteAllTasks() {
        sendRemote("/remote-delete-all-tasks")
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func processTerminalTaskChanges() {
        guard let tasks = bridge.lastStatus?.runtimeTasks else { return }
        let terminal = tasks.filter { ["completed", "failed"].contains(normalize($0.status)) }
        if !didSeedNotificationState {
            terminalTaskIDs = Set(terminal.map(\.id))
            didSeedNotificationState = true
            return
        }

        for task in terminal where !terminalTaskIDs.contains(task.id) {
            terminalTaskIDs.insert(task.id)
            let completed = normalize(task.status) == "completed"
            let detail = completed
                ? (task.finalReport ?? task.checkpoint ?? "Mission completed successfully.")
                : (task.failureReason ?? task.checkpoint ?? "Mission stopped with an error.")
            postMissionNotification(task: task, completed: completed, detail: detail)
        }

        let currentIDs = Set(tasks.map(\.id))
        terminalTaskIDs = terminalTaskIDs.filter { currentIDs.contains($0) }
    }

    private func postMissionNotification(task: TravisBridgeTaskSnapshot, completed: Bool, detail: String) {
        let content = UNMutableNotificationContent()
        content.title = completed ? "TRAVIS Mission Ready" : "TRAVIS Mission Needs Attention"
        content.subtitle = task.title
        content.body = String(detail.replacingOccurrences(of: "\n", with: " ").prefix(180))
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "travis-mission-\(task.id.uuidString)-\(task.status)", content: content, trigger: nil)
        )

        UINotificationFeedbackGenerator().notificationOccurred(completed ? .success : .error)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            completionToast = completed ? "\(task.title) — completed" : "\(task.title) — needs attention"
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.2)) { completionToast = nil }
        }
    }

    private func normalize(_ status: String) -> String {
        status.lowercased().filter { $0.isLetter }
    }
}

private extension View {
    func liveTaskHUD(cyan: Color, panel: Color) -> some View {
        background(RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [.white.opacity(0.05), panel.opacity(0.96), Color.black.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [.white.opacity(0.16), cyan.opacity(0.48), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(0.65), radius: 12, y: 7)
    }
}

#endif
