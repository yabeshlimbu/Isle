import SwiftUI

/// CPU / GPU load and temperature, plus memory pressure, described in plain words.
struct StatsPanel: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            StatRow(name: "CPU", usage: stats.cpuUsage, temp: stats.cpuTemp)
            StatRow(name: "GPU", usage: stats.gpuUsage, temp: stats.gpuTemp, shared: stats.gpuTempShared)
            MemoryRow(stats: stats)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .help(helpText)
    }

    private var helpText: String {
        var lines = [stats.summary, ""]
        if let u = stats.cpuUsage { lines.append("CPU: \(SystemStats.usageLevel(u).1)") }
        if let u = stats.gpuUsage { lines.append("GPU: \(SystemStats.usageLevel(u).1)") }
        if let used = stats.memUsed {
            let gb = { (b: UInt64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
            lines.append("Memory: \(gb(used)) used of \(gb(stats.memTotal))")
        }
        lines += ["", "Usage: how hard the chip is working right now.",
                  "Temperature: the hottest sensor in that part of the chip.",
                  "Memory pressure: how hard macOS is working to find free memory."]
        return lines.joined(separator: "\n")
    }
}

private struct MemoryRow: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        let (level, word) = SystemStats.memoryLevel(stats.memState)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("MEMORY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    Image(systemName: "memorychip")
                    Text(word)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(level.color)
            }
            if let pressure = stats.memPressure {
                HStack(spacing: 6) {
                    UsageBar(fraction: pressure, color: level.color)
                    Text("\(Int((pressure * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            } else {
                Text("Measuring…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct StatRow: View {
    let name: String
    let usage: Double?
    let temp: Double?
    var shared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let temp {
                    let (level, word) = SystemStats.tempLevel(temp)
                    HStack(spacing: 2) {
                        Image(systemName: "thermometer.medium")
                        Text("\(Int(temp.rounded()))°C · \(word)")
                    }
                    .help(shared ? "This chip has no separate GPU sensor; CPU and GPU share one die, so this is the chip temperature." : "")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(level.color)
                }
            }
            if let usage {
                let level = SystemStats.usageLevel(usage).0
                HStack(spacing: 6) {
                    UsageBar(fraction: usage, color: level.color)
                    Text("\(Int((usage * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            } else {
                Text("Measuring…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(color)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
}

extension SystemStats.Level {
    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
}
