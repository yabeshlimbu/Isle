import Darwin
import Foundation
import IOKit

/// Samples CPU / GPU usage and temperature, and memory pressure, every couple of seconds.
///
/// - CPU usage: Mach host CPU tick counters.
/// - GPU usage: the IOAccelerator "Device Utilization %" statistic.
/// - Temperatures: Apple Silicon thermal sensors exposed through the HID
///   event system (the same source tools like `powermetrics` use).
///   Values are `nil` when a Mac doesn't expose them.
/// - Memory pressure: the kernel's own pressure level and "memory available"
///   percentage (what Activity Monitor's pressure graph is built from).
final class SystemStats: ObservableObject {
    @Published private(set) var cpuUsage: Double?     // 0...1
    @Published private(set) var gpuUsage: Double?     // 0...1
    @Published private(set) var cpuTemp: Double?      // °C
    @Published private(set) var gpuTemp: Double?      // °C
    /// True when the chip has no separate GPU sensor and `gpuTemp` is the shared die temperature.
    @Published private(set) var gpuTempShared = false
    @Published private(set) var memPressure: Double?  // 0...1, how much of memory is spoken for
    @Published private(set) var memState: MemoryState = .normal
    @Published private(set) var memUsed: UInt64?      // bytes: app + wired + compressed, like Activity Monitor
    let memTotal = ProcessInfo.processInfo.physicalMemory

    enum MemoryState { case normal, warning, critical }

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private let sensors = ThermalSensors()
    private let queue = DispatchQueue(label: "isle.stats", qos: .utility)

    func start() {
        guard timer == nil else { return }
        lastTicks = Self.cpuTicks()
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        queue.async { [weak self] in
            guard let self else { return }
            var cpu: Double?
            if let now = Self.cpuTicks() {
                if let last = self.lastTicks, now.total > last.total {
                    cpu = Double(now.busy - last.busy) / Double(now.total - last.total)
                }
                self.lastTicks = now
            }
            let gpu = Self.gpuUtilization()
            let temps = self.sensors.read()
            let available = Self.sysctlInt("kern.memorystatus_level")          // % of memory still available
            let kernelLevel = Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
            let used = Self.memoryUsed()
            DispatchQueue.main.async {
                self.memPressure = available.map { min(max(1 - Double($0) / 100, 0), 1) }
                self.memState = kernelLevel >= 4 ? .critical : kernelLevel >= 2 ? .warning : .normal
                self.memUsed = used
                if let cpu { self.cpuUsage = min(max(cpu, 0), 1) }
                self.gpuUsage = gpu
                self.cpuTemp = temps.cpu
                self.gpuTemp = temps.gpu ?? temps.cpu
                self.gpuTempShared = temps.gpu == nil && temps.cpu != nil
            }
        }
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func memoryUsed() -> UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let app = UInt64(info.internal_page_count) - min(UInt64(info.purgeable_count), UInt64(info.internal_page_count))
        let pages = app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber
            else { continue }
            best = max(best ?? 0, value.doubleValue / 100)
        }
        return best.map { min(max($0, 0), 1) }
    }
}

// MARK: - Plain-language descriptions

extension SystemStats {
    enum Level { case low, medium, high, critical }

    static func usageLevel(_ u: Double) -> (Level, String) {
        switch u {
        case ..<0.15: return (.low, "Idle")
        case ..<0.45: return (.low, "Light")
        case ..<0.75: return (.medium, "Busy")
        case ..<0.92: return (.high, "Working hard")
        default:      return (.critical, "Maxed out")
        }
    }

    static func memoryLevel(_ state: MemoryState) -> (Level, String) {
        switch state {
        case .normal:   return (.low, "Normal")
        case .warning:  return (.high, "Strained")
        case .critical: return (.critical, "Critical")
        }
    }

    static func tempLevel(_ c: Double) -> (Level, String) {
        switch c {
        case ..<50: return (.low, "Cool")
        case ..<70: return (.medium, "Warm")
        case ..<90: return (.high, "Hot")
        default:    return (.critical, "Very hot")
        }
    }

    /// One-line summary of how the Mac is doing overall.
    var summary: String {
        let usage = max(cpuUsage ?? 0, gpuUsage ?? 0)
        let temp = max(cpuTemp ?? 0, gpuTemp ?? 0)
        if memState == .critical { return "Almost out of memory — close some apps" }
        if temp >= 90 { return "Running very hot — fans should be on" }
        if memState == .warning { return "Memory is tight — things may slow down" }
        if usage >= 0.75 && temp >= 70 { return "Under heavy load and warm" }
        if usage >= 0.75 { return "Under heavy load" }
        if temp >= 70 { return "A bit warm" }
        if usage < 0.15 { return "Relaxed — barely doing anything" }
        return "Running comfortably"
    }
}

// MARK: - Thermal sensors (Apple Silicon)

/// Reads temperatures from the HID event system.  The functions are resolved
/// at runtime so a missing symbol just means "no temperature", never a crash.
private final class ThermalSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double

    private let copyServices: CopyServicesFn?
    private let copyProperty: CopyPropertyFn?
    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?
    private var client: OpaquePointer?

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    init() {
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }   // RTLD_DEFAULT
            return unsafeBitCast(p, to: T.self)
        }
        let create = sym("IOHIDEventSystemClientCreate", CreateFn.self)
        let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)

        if let create, let setMatching, let c = create(kCFAllocatorDefault) {
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = setMatching(c, matching)
            client = c
        }
    }

    func read() -> (cpu: Double?, gpu: Double?) {
        guard let client, let copyServices, let copyProperty, let copyEvent, let getFloat,
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return (nil, nil) }

        var cpuCores: [Double] = [], cpuDie: [Double] = [], gpu: [Double] = []
        for service in services {
            let ref = OpaquePointer(Unmanaged.passUnretained(service).toOpaque())
            guard let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(ref, Self.temperatureEvent, 0, 0) else { continue }
            let value = getFloat(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            guard value > 0, value < 130 else { continue }

            if name.contains("GPU") {
                gpu.append(value)
            } else if name.contains("ACC MTR") || name.contains("PACC") || name.contains("ECPU") || name.contains("PCPU") {
                cpuCores.append(value)
            } else if name.contains("tdie") {
                cpuDie.append(value)
            }
        }
        let cpu = cpuCores.isEmpty ? cpuDie : cpuCores
        return (cpu.max(), gpu.max())
    }
}
