#if os(macOS)
import Foundation
import Darwin
import Observation

@MainActor
@Observable
final class TravisSystemTelemetry {
    private(set) var cpuPercent: Double = 0
    private(set) var memoryPercent: Double = 0
    private(set) var diskPercent: Double = 0
    private(set) var uptime: String = "--"
    private var timer: Timer?
    private var previousCPU: host_cpu_load_info_data_t?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        cpuPercent = readCPU()
        memoryPercent = readMemory()
        diskPercent = readDisk()
        uptime = formatUptime(ProcessInfo.processInfo.systemUptime)
    }

    private func readCPU() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return cpuPercent }
        defer { previousCPU = info }
        guard let old = previousCPU else { return 0 }
        let user = Double(info.cpu_ticks.0 - old.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 - old.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 - old.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 - old.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return cpuPercent }
        return min(100, max(0, (user + system + nice) / total * 100))
    }

    private func readMemory() -> Double {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return memoryPercent }
        let page = Double(vm_kernel_page_size)
        let used = Double(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count) * page
        return min(100, max(0, used / total * 100))
    }

    private func readDisk() -> Double {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            guard let total = values.volumeTotalCapacity, total > 0,
                  let available = values.volumeAvailableCapacityForImportantUsage else { return diskPercent }
            return min(100, max(0, (1 - Double(available) / Double(total)) * 100))
        } catch { return diskPercent }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let days = hours / 24
        return days > 0 ? "\(days)d \(hours % 24)h" : "\(hours)h \((Int(seconds) % 3600) / 60)m"
    }
}
#endif
