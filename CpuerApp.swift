// CpuerApp.swift — macOS menu bar CPU monitor
//
// Based on Gpuer (https://github.com/simonw/gpuer) and
// Bandwidther (https://github.com/simonw/bandwidther) by Simon Willison.
// Architecture, UI components, and design patterns derived from his work.
// CPU-specific implementation generated with AI assistance (GitHub Copilot CLI).

import SwiftUI
import AppKit
import Darwin
import Foundation

// MARK: - Data Models

struct CPUTickCounts {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

struct CoreUsage: Identifiable {
    let id: Int
    let usage: Double          // 0.0–1.0 total active fraction
    let userFraction: Double
    let systemFraction: Double
    let isPerformance: Bool    // P-core (true) or E-core (false)
}

struct CPUStats {
    let userPercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let nicePercent: Double
    let coreUsages: [CoreUsage]
    let model: String
    let physicalCores: Int
    let logicalCores: Int
    let pCores: Int
    let eCores: Int
    let loadAvg1: Double
    let loadAvg5: Double
    let loadAvg15: Double
    let uptime: TimeInterval

    var totalActivePercent: Double { userPercent + systemPercent + nicePercent }
    var activeCoreEstimate: Double { totalActivePercent / 100.0 * Double(logicalCores) }
}

struct ProcessCPU: Identifiable {
    let id: String
    let name: String
    let pid: Int
    let cpuPercent: Double
    let memMB: Double
}

enum ProcessSortKey: String, CaseIterable {
    case cpu = "CPU"
    case memory = "Memory"
    case name = "Name"
    case pid = "PID"
}

// MARK: - System Info Helpers

func getCPUModel() -> String {
    var size: size_t = 0
    if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
        var buffer = [CChar](repeating: 0, count: size)
        if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
            let brand = String(cString: buffer)
            if !brand.isEmpty { return brand }
        }
    }
    return "Apple Silicon"
}

func getPhysicalCPUCount() -> Int {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("hw.physicalcpu", &count, &size, nil, 0)
    return Int(count)
}

func getLogicalCPUCount() -> Int {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("hw.logicalcpu", &count, &size, nil, 0)
    return Int(count)
}

func getPerfLevelCores() -> (pCores: Int, eCores: Int) {
    var pCores: Int32 = 0
    var eCores: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.logicalcpu", &pCores, &size, nil, 0) == 0 {
        size = MemoryLayout<Int32>.size
        _ = sysctlbyname("hw.perflevel1.logicalcpu", &eCores, &size, nil, 0)
        return (Int(pCores), Int(eCores))
    }
    return (0, 0)
}

func getLoadAverages() -> (Double, Double, Double) {
    var loadavg = [Double](repeating: 0, count: 3)
    getloadavg(&loadavg, 3)
    return (loadavg[0], loadavg[1], loadavg[2])
}

func getUptime() -> TimeInterval {
    var boottime = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    sysctl(&mib, 2, &boottime, &size, nil, 0)
    return Date().timeIntervalSince1970 - Double(boottime.tv_sec) - Double(boottime.tv_usec) / 1_000_000
}

// MARK: - CPU Tick Collection

func getPerCoreTicks() -> [CPUTickCounts]? {
    var numCPUs: natural_t = 0
    var cpuInfo: processor_info_array_t?
    var numCPUInfo: mach_msg_type_number_t = 0

    let result = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &numCPUs,
        &cpuInfo,
        &numCPUInfo
    )

    guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }

    var ticks: [CPUTickCounts] = []
    for i in 0..<Int(numCPUs) {
        let offset = Int(CPU_STATE_MAX) * i
        ticks.append(CPUTickCounts(
            user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
            system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
            idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
            nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)])
        ))
    }

    let cpuInfoSize = vm_size_t(MemoryLayout<integer_t>.stride * Int(numCPUInfo))
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), cpuInfoSize)

    return ticks
}

func computeCPUStats(current: [CPUTickCounts], previous: [CPUTickCounts],
                     pCores: Int, eCores: Int, model: String,
                     physCores: Int, logCores: Int) -> CPUStats {
    var totalUser: UInt64 = 0
    var totalSystem: UInt64 = 0
    var totalIdle: UInt64 = 0
    var totalNice: UInt64 = 0
    var coreUsages: [CoreUsage] = []

    let count = min(current.count, previous.count)
    for i in 0..<count {
        // Wrapping subtraction handles UInt32 overflow correctly
        let dUser = UInt64(current[i].user &- previous[i].user)
        let dSystem = UInt64(current[i].system &- previous[i].system)
        let dIdle = UInt64(current[i].idle &- previous[i].idle)
        let dNice = UInt64(current[i].nice &- previous[i].nice)
        let dTotal = dUser + dSystem + dIdle + dNice

        totalUser += dUser
        totalSystem += dSystem
        totalIdle += dIdle
        totalNice += dNice

        let usage = dTotal > 0 ? Double(dUser + dSystem + dNice) / Double(dTotal) : 0
        let userFrac = dTotal > 0 ? Double(dUser) / Double(dTotal) : 0
        let sysFrac = dTotal > 0 ? Double(dSystem) / Double(dTotal) : 0

        coreUsages.append(CoreUsage(
            id: i,
            usage: usage,
            userFraction: userFrac,
            systemFraction: sysFrac,
            isPerformance: pCores > 0 ? i < pCores : true
        ))
    }

    let grandTotal = totalUser + totalSystem + totalIdle + totalNice
    let userPct = grandTotal > 0 ? Double(totalUser) / Double(grandTotal) * 100 : 0
    let systemPct = grandTotal > 0 ? Double(totalSystem) / Double(grandTotal) * 100 : 0
    let idlePct = grandTotal > 0 ? Double(totalIdle) / Double(grandTotal) * 100 : 0
    let nicePct = grandTotal > 0 ? Double(totalNice) / Double(grandTotal) * 100 : 0

    let load = getLoadAverages()
    let uptime = getUptime()

    return CPUStats(
        userPercent: userPct, systemPercent: systemPct,
        idlePercent: idlePct, nicePercent: nicePct,
        coreUsages: coreUsages, model: model,
        physicalCores: physCores, logicalCores: logCores,
        pCores: pCores, eCores: eCores,
        loadAvg1: load.0, loadAvg5: load.1, loadAvg15: load.2,
        uptime: uptime
    )
}

// MARK: - Process Collection

func readTopProcesses() -> [ProcessCPU] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-eo", "pid,pcpu,rss,comm", "-r"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return [] }

    // Read before waitUntilExit to avoid pipe buffer deadlock on large output
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    struct AggProc {
        var totalCPU: Double = 0
        var totalMB: Double = 0
        var count: Int = 0
        var pid: Int = 0
    }

    var aggregated: [String: AggProc] = [:]
    for line in output.components(separatedBy: "\n").dropFirst() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 4,
              let pid = Int(parts[0]),
              let cpu = Double(parts[1]),
              let rss = Double(parts[2]) else { continue }
        let name = (String(parts[3]) as NSString).lastPathComponent

        var entry = aggregated[name] ?? AggProc()
        entry.totalCPU += cpu
        entry.totalMB += rss / 1024.0
        entry.count += 1
        if entry.pid == 0 { entry.pid = pid }
        aggregated[name] = entry
    }

    return aggregated.map { (name, agg) in
        let displayName = agg.count > 1 ? "\(name) (\(agg.count))" : name
        return ProcessCPU(id: name, name: displayName, pid: agg.pid,
                         cpuPercent: agg.totalCPU, memMB: agg.totalMB)
    }.sorted { $0.cpuPercent > $1.cpuPercent }
}

// MARK: - CPU Monitor

class CPUMonitor: ObservableObject {
    @Published var cpuStats: CPUStats
    @Published var processes: [ProcessCPU] = []
    @Published var processSortKey: ProcessSortKey = .cpu
    @Published var processSortAscending: Bool = false
    @Published var cpuHistory: [Double] = []
    @Published var userHistory: [Double] = []
    @Published var systemHistory: [Double] = []

    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private let maxHistory = 60
    private var previousTicks: [CPUTickCounts] = []
    private let cpuModel: String
    private let physCores: Int
    private let logCores: Int
    private let pCoreCount: Int
    private let eCoreCount: Int

    init() {
        cpuModel = getCPUModel()
        physCores = getPhysicalCPUCount()
        logCores = getLogicalCPUCount()
        let perf = getPerfLevelCores()
        pCoreCount = perf.pCores
        eCoreCount = perf.eCores

        cpuStats = CPUStats(
            userPercent: 0, systemPercent: 0, idlePercent: 100, nicePercent: 0,
            coreUsages: [], model: cpuModel,
            physicalCores: physCores, logicalCores: logCores,
            pCores: pCoreCount, eCores: eCoreCount,
            loadAvg1: 0, loadAvg5: 0, loadAvg15: 0, uptime: 0
        )

        previousTicks = getPerCoreTicks() ?? []
        refreshProcesses()

        fastTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshProcesses()
        }

        // First delta after brief delay to get meaningful data
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }

    deinit {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
    }

    func refresh() {
        let prevTicks = self.previousTicks
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let currentTicks = getPerCoreTicks() else { return }

            if prevTicks.isEmpty {
                DispatchQueue.main.async { self.previousTicks = currentTicks }
                return
            }

            let stats = computeCPUStats(
                current: currentTicks, previous: prevTicks,
                pCores: self.pCoreCount, eCores: self.eCoreCount,
                model: self.cpuModel, physCores: self.physCores, logCores: self.logCores
            )

            DispatchQueue.main.async {
                self.previousTicks = currentTicks
                self.cpuStats = stats

                self.cpuHistory.append(stats.totalActivePercent)
                if self.cpuHistory.count > self.maxHistory { self.cpuHistory.removeFirst() }
                self.userHistory.append(stats.userPercent)
                if self.userHistory.count > self.maxHistory { self.userHistory.removeFirst() }
                self.systemHistory.append(stats.systemPercent)
                if self.systemHistory.count > self.maxHistory { self.systemHistory.removeFirst() }
            }
        }
    }

    func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let procs = readTopProcesses()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.processes = self.sortProcesses(procs)
            }
        }
    }

    func sortProcesses(_ procs: [ProcessCPU]) -> [ProcessCPU] {
        let sorted: [ProcessCPU]
        switch processSortKey {
        case .cpu: sorted = procs.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: sorted = procs.sorted { $0.memMB > $1.memMB }
        case .name: sorted = procs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: sorted = procs.sorted { $0.pid < $1.pid }
        }
        return processSortAscending ? sorted.reversed() : sorted
    }

    func resortProcesses() {
        processes = sortProcesses(processes)
    }
}

// MARK: - Formatting

func formatMB(_ mb: Double) -> String {
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
}

func formatUptime(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let mins = (total % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h \(mins)m" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

// MARK: - Views

struct SparklineView: View {
    let data: [Double]
    let color: Color
    let maxValue: Double?

    init(data: [Double], color: Color, maxValue: Double? = nil) {
        self.data = data
        self.color = color
        self.maxValue = maxValue
    }

    var body: some View {
        GeometryReader { geo in
            let maxVal = maxValue ?? max((data.max() ?? 1), 0.001)
            let w = geo.size.width
            let h = geo.size.height

            if data.count > 1 {
                Path { path in
                    for (i, val) in data.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(data.count - 1)
                        let y = h - (h * CGFloat(val / maxVal))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, lineWidth: 1.5)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    for (i, val) in data.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(data.count - 1)
                        let y = h - (h * CGFloat(val / maxVal))
                        if i == 0 { path.addLine(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.15))
            }
        }
    }
}

struct UsageBarView: View {
    let segments: [(Double, Color)]
    let height: CGFloat

    init(segments: [(Double, Color)], height: CGFloat = 20) {
        self.segments = segments
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(seg.1)
                            .frame(width: max(0, geo.size.width * CGFloat(min(seg.0, 1.0))))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: height)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.primary)
    }
}

struct RateCardView: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}

struct SortButton: View {
    let label: String
    let key: ProcessSortKey
    @Binding var currentKey: ProcessSortKey
    @Binding var ascending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            if currentKey == key {
                ascending.toggle()
            } else {
                currentKey = key
                ascending = false
            }
            action()
        }) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: currentKey == key ? .bold : .medium))
                if currentKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .foregroundColor(currentKey == key ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ProcessRowView: View {
    let proc: ProcessCPU
    let maxCPU: Double

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(proc.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            HStack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.5))
                            .frame(width: max(0, geo.size.width * CGFloat(proc.cpuPercent / max(maxCPU, 0.1))))
                    }
                }
                .frame(height: 4)
                Text(formatMB(proc.memMB))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Core Grid View

struct CoreBarView: View {
    let core: CoreUsage

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: max(0, w * CGFloat(core.userFraction)))
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: max(0, w * CGFloat(core.systemFraction)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
            .frame(height: 14)
            Text("\(Int(core.usage * 100))%")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

struct CoreGridView: View {
    let cores: [CoreUsage]
    let pCoreCount: Int
    let eCoreCount: Int

    private func gridColumns(for count: Int) -> [GridItem] {
        let cols = min(count, 6)
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: max(cols, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let pCores = cores.filter { $0.isPerformance }
            let eCores = cores.filter { !$0.isPerformance }

            if !pCores.isEmpty {
                Text("Performance (\(pCores.count))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                LazyVGrid(columns: gridColumns(for: pCores.count), spacing: 6) {
                    ForEach(pCores) { core in
                        CoreBarView(core: core)
                    }
                }
            }

            if !eCores.isEmpty {
                Text("Efficiency (\(eCores.count))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                LazyVGrid(columns: gridColumns(for: eCores.count), spacing: 6) {
                    ForEach(eCores) { core in
                        CoreBarView(core: core)
                    }
                }
            }

            if pCores.isEmpty && eCores.isEmpty && cores.isEmpty {
                Text("Waiting for data\u{2026}")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var monitor = CPUMonitor()

    private var loadColor: Color {
        let active = monitor.cpuStats.totalActivePercent
        if active < 40 { return .green }
        if active < 75 { return .orange }
        return .red
    }

    private var coreDescription: String {
        let stats = monitor.cpuStats
        if stats.pCores > 0 && stats.eCores > 0 {
            return "\(stats.logicalCores) cores (\(stats.pCores)P + \(stats.eCores)E)"
        }
        return "\(stats.logicalCores) cores"
    }

    private var headroomMessage: String {
        let active = monitor.cpuStats.totalActivePercent
        if active < 20 { return "System is idle \u{2014} plenty of headroom" }
        if active < 40 { return "Light load \u{2014} most cores are relaxed" }
        if active < 60 { return "Moderate CPU load" }
        if active < 80 { return "Heavy CPU load \u{2014} consider closing apps" }
        return "CPU is saturated \u{2014} system may feel slow"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // LEFT COLUMN
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cpuer")
                                .font(.system(size: 20, weight: .bold))
                            Text("\(monitor.cpuStats.model) \u{2022} \(coreDescription)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Uptime")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(formatUptime(monitor.cpuStats.uptime))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    // HEADLINE: CPU Active %
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.0f", monitor.cpuStats.totalActivePercent))
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(loadColor)
                            Text("% Active")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(loadColor.opacity(0.8))
                        }
                        let busyCores = monitor.cpuStats.activeCoreEstimate
                        Text("~\(String(format: "%.1f", busyCores)) of \(monitor.cpuStats.logicalCores) cores busy on average")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(headroomMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(loadColor.opacity(0.06))
                    .cornerRadius(12)

                    // CPU BREAKDOWN
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CPU Breakdown")
                            .font(.system(size: 13, weight: .semibold))

                        UsageBarView(segments: [
                            (monitor.cpuStats.userPercent / 100, .blue),
                            (monitor.cpuStats.systemPercent / 100, .orange),
                        ], height: 28)

                        HStack(spacing: 14) {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 10, height: 10)
                                Text("User \(String(format: "%.1f%%", monitor.cpuStats.userPercent))")
                                    .font(.system(size: 10))
                            }
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 10, height: 10)
                                Text("System \(String(format: "%.1f%%", monitor.cpuStats.systemPercent))")
                                    .font(.system(size: 10))
                            }
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)).frame(width: 10, height: 10)
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                Text("Idle \(String(format: "%.1f%%", monitor.cpuStats.idlePercent))")
                                    .font(.system(size: 10))
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // LOAD AVERAGE
                    RateCardView(
                        title: "LOAD AVERAGE",
                        value: String(format: "%.2f", monitor.cpuStats.loadAvg1),
                        subtitle: "1 min \u{2022} 5 min: \(String(format: "%.2f", monitor.cpuStats.loadAvg5)) \u{2022} 15 min: \(String(format: "%.2f", monitor.cpuStats.loadAvg15))",
                        icon: "gauge.with.dots.needle.33percent",
                        color: .blue
                    )

                    // PER-CORE UTILIZATION
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Per-Core Utilization")
                            .font(.system(size: 13, weight: .semibold))

                        CoreGridView(
                            cores: monitor.cpuStats.coreUsages,
                            pCoreCount: monitor.cpuStats.pCores,
                            eCoreCount: monitor.cpuStats.eCores
                        )

                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 10, height: 4)
                                Text("User").font(.system(size: 9)).foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 10, height: 4)
                                Text("System").font(.system(size: 9)).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // HISTORY
                    VStack(alignment: .leading, spacing: 8) {
                        Text("History (2 min)")
                            .font(.system(size: 12, weight: .semibold))

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total CPU")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                SparklineView(data: monitor.cpuHistory, color: loadColor, maxValue: 100.0)
                                    .frame(height: 44)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("User / System")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                ZStack {
                                    SparklineView(data: monitor.userHistory, color: .blue, maxValue: 100.0)
                                    SparklineView(data: monitor.systemHistory, color: .orange, maxValue: 100.0)
                                }
                                .frame(height: 44)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }
                .padding(16)
            }
            .frame(width: 520)

            Divider()

            // RIGHT COLUMN: Process CPU
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader(title: "CPU Consumers", icon: "cpu")
                    Spacer()
                    Text("\(monitor.processes.count) processes")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("Sort:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    ForEach(ProcessSortKey.allCases, id: \.self) { key in
                        SortButton(
                            label: key.rawValue, key: key,
                            currentKey: $monitor.processSortKey,
                            ascending: $monitor.processSortAscending,
                            action: { monitor.resortProcesses() }
                        )
                    }
                }

                let maxCPU = monitor.processes.map(\.cpuPercent).max() ?? 1.0

                if monitor.processes.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading\u{2026}")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(monitor.processes) { proc in
                                ProcessRowView(proc: proc, maxCPU: maxCPU)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 320)
        }
        .frame(width: 840, height: 720)
        .background(.background)
    }
}

// MARK: - App Delegate for Menu Bar

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Cpuer")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 840, height: 720)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover

        NSApp.setActivationPolicy(.accessory)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - App Entry Point

@main
struct CpuerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
