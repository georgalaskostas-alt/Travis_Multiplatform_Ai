#if os(iOS)

import SwiftUI

struct iOSLiveMacTasksWorkspace: View {
    @Bindable var appState: TRAVISAppState
    @State private var bridge = TravisDeviceBridgeService.shared

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

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, navy, panel.opacity(0.92), navy], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 13) {
                    header
                    summaryGrid

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
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                if bridge.isConnected { bridge.requestStatus() }
                try? await Task.sleep(for: .seconds(2))
            }
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(2)
                    Text(task.goal).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 8)
                statusBadge(task.status)
            }

            ProgressView(value: Double(task.completedSteps), total: Double(max(task.totalSteps, 1))).tint(cyan)
            HStack {
                Text("\(task.completedSteps)/\(task.totalSteps) STEPS")
                Spacer()
                Text(task.priority.uppercased())
            }
            .font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)

            if let step = task.currentStep, !step.isEmpty { detailRow("CURRENT STEP", step, "bolt.fill") }
            if let checkpoint = task.checkpoint, !checkpoint.isEmpty { detailRow("LAST CHECKPOINT", checkpoint, "flag.checkered") }
            if let report = task.finalReport, !report.isEmpty { finalReportBlock(report) }
        }
        .padding(13)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    private func localTaskCard(_ task: AgentTask) -> some View {
        let completed = task.plan.steps.filter { $0.status == .completed }.count
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(2)
                    Text(task.goal).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 8)
                statusBadge(task.status.rawValue)
            }
            ProgressView(value: Double(completed), total: Double(max(task.plan.steps.count, 1))).tint(cyan)
            HStack {
                Text("\(completed)/\(task.plan.steps.count) STEPS")
                Spacer()
                Text(task.priority.rawValue.uppercased())
            }.font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
        }
        .padding(13)
        .liveTaskHUD(cyan: cyan, panel: panel)
    }

    private func detailRow(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: icon).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(cyan)
            Text(value).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.82)).lineLimit(4)
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
                if !status.lastSummary.isEmpty { Text(status.lastSummary).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3) }
            } else {
                Text("Waiting for Mac runtime connection…").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .liveTaskHUD(cyan: cyan, panel: panel)
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
        let key = normalize(status)
        let color: Color = switch key {
        case "completed": .green
        case "failed", "cancelled": .red
        case "running", "planning": cyan
        case "waitingforapproval", "waitingfordependency", "paused": .orange
        default: .secondary
        }
        return Text(status.replacingOccurrences(of: "waitingFor", with: "WAIT ").uppercased())
            .font(.system(size: 7, weight: .heavy, design: .rounded)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.7))
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
