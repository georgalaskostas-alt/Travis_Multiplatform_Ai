#if os(iOS)

import SwiftUI

struct iOSPremiumMacTasksWorkspace: View {
    @Bindable var appState: TRAVISAppState
    @State private var bridge = TravisDeviceBridgeService.shared

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

    private var tasks: [TravisBridgeTaskSnapshot] {
        bridge.lastStatus?.runtimeTasks.sorted { $0.updatedAt > $1.updatedAt } ?? []
    }

    private var runningCount: Int {
        tasks.filter { normalized($0.status) == "running" || normalized($0.status) == "planning" }.count
    }

    private var waitingCount: Int {
        tasks.filter {
            let value = normalized($0.status)
            return value == "pending" || value == "paused" || value.contains("waiting")
        }.count
    }

    private var completedCount: Int {
        tasks.filter { normalized($0.status) == "completed" }.count
    }

    private var failedCount: Int {
        tasks.filter {
            let value = normalized($0.status)
            return value == "failed" || value == "cancelled"
        }.count
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, navy, panel.opacity(0.92), navy],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 13) {
                    header
                    summaryGrid

                    if bridge.isConnected {
                        if tasks.isEmpty {
                            emptyMacQueue
                        } else {
                            ForEach(tasks) { task in
                                macTaskCard(task)
                            }
                        }
                    } else {
                        offlineCard
                    }

                    macRuntimeCard
                }
                .padding(14)
                .padding(.bottom, 28)
            }
            .refreshable {
                bridge.requestStatus()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            bridge.start()
            while !Task.isCancelled {
                if bridge.isConnected {
                    bridge.requestStatus()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(cyan.opacity(0.09))
                    .frame(width: 48, height: 48)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(cyan.opacity(0.48), lineWidth: 1)
                    .frame(width: 48, height: 48)
                Image(systemName: "checklist")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(cyan)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("TASK CONTROL")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .tracking(1)
                Text(bridge.isConnected ? "MAC AUTONOMOUS RUNTIME · LIVE" : "AUTONOMOUS RUNTIME QUEUE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(cyan)
            }

            Spacer()

            Circle()
                .fill(bridge.isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: bridge.isConnected ? .green : .orange, radius: 5)
        }
        .padding(14)
        .macTaskHUD(cyan: cyan, panel: panel)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            summaryTile("RUNNING", "\(runningCount)", .green)
            summaryTile("WAITING", "\(waitingCount)", .orange)
            summaryTile("COMPLETED", "\(completedCount)", cyan)
            summaryTile("FAILED", "\(failedCount)", .red)
        }
    }

    private var emptyMacQueue: some View {
        VStack(spacing: 9) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(cyan)
            Text("MAC RUNTIME QUEUE EMPTY")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            Text("Connected to Mac TRAVIS. New missions and runtime changes will appear here automatically.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .macTaskHUD(cyan: cyan, panel: panel)
    }

    private var offlineCard: some View {
        VStack(spacing: 9) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            Text("MAC TRAVIS OFFLINE")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            Text("Task Control will switch back to the live Mac queue as soon as the device link reconnects.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .macTaskHUD(cyan: cyan, panel: panel)
    }

    private func macTaskCard(_ task: TravisBridgeTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Text(task.goal)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                statusBadge(task.status)
            }

            if task.totalSteps > 0 {
                ProgressView(
                    value: Double(min(task.completedSteps, task.totalSteps)),
                    total: Double(max(task.totalSteps, 1))
                )
                .tint(cyan)

                HStack {
                    Text("\(task.completedSteps)/\(task.totalSteps) STEPS")
                    Spacer()
                    Text(task.priority.uppercased())
                }
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            }

            if let currentStep = task.currentStep, !currentStep.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .foregroundStyle(cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CURRENT STEP")
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .foregroundStyle(cyan)
                        Text(currentStep)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }

            if let checkpoint = task.checkpoint, !checkpoint.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "flag.checkered")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LAST CHECKPOINT")
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .foregroundStyle(.green)
                        Text(checkpoint)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
        }
        .padding(13)
        .macTaskHUD(cyan: cyan, panel: panel)
    }

    private var macRuntimeCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("MAC TRAVIS", systemImage: "desktopcomputer")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(cyan)
                Spacer()
                Text(bridge.isConnected ? "CONNECTED" : "OFFLINE")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(bridge.isConnected ? .green : .orange)
            }

            if let status = bridge.lastStatus {
                HStack {
                    Text("ACTIVE RUNTIME TASKS")
                    Spacer()
                    Text("\(status.activeRuntimeTasks)")
                        .foregroundStyle(cyan)
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))

                HStack {
                    Text("SYNCED TASK SNAPSHOTS")
                    Spacer()
                    Text("\(status.runtimeTasks.count)")
                        .foregroundStyle(cyan)
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

                if !status.lastSummary.isEmpty {
                    Text(status.lastSummary)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } else {
                Text("Waiting for runtime status…")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .macTaskHUD(cyan: cyan, panel: panel)
    }

    private func summaryTile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.24), lineWidth: 0.8))
    }

    private func statusBadge(_ rawStatus: String) -> some View {
        let value = normalized(rawStatus)
        let color: Color

        if value == "completed" {
            color = .green
        } else if value == "failed" || value == "cancelled" {
            color = .red
        } else if value == "running" || value == "planning" {
            color = cyan
        } else if value == "pending" || value == "paused" || value.contains("waiting") {
            color = .orange
        } else {
            color = .secondary
        }

        return Text(displayStatus(rawStatus))
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.7))
    }

    private func normalized(_ status: String) -> String {
        status
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private func displayStatus(_ status: String) -> String {
        status
            .replacingOccurrences(of: "waitingFor", with: "WAIT ")
            .replacingOccurrences(of: "_", with: " ")
            .uppercased()
    }
}

private extension View {
    func macTaskHUD(cyan: Color, panel: Color) -> some View {
        background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.05), panel.opacity(0.96), Color.black.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.16), cyan.opacity(0.48), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.65), radius: 12, y: 7)
        .shadow(color: cyan.opacity(0.06), radius: 8)
    }
}

#endif
