// Lists every temperature sensor Isle can see.  Run:  swift tools/sensors.swift
import Foundation
typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Int32
typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
typealias CopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double
func sym<T>(_ n: String, _: T.Type) -> T { unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), n)!, to: T.self) }
let client = sym("IOHIDEventSystemClientCreate", CreateFn.self)(kCFAllocatorDefault)!
_ = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
let services = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)(client)!.takeRetainedValue() as [AnyObject]
var rows: [(String, Double)] = []
for s in services {
    let ref = OpaquePointer(Unmanaged.passUnretained(s).toOpaque())
    guard let name = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)(ref, "Product" as CFString)?.takeRetainedValue() as? String,
          let ev = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)(ref, 15, 0, 0) else { continue }
    rows.append((name, sym("IOHIDEventGetFloatValue", GetFloatFn.self)(ev, 15 << 16)))
}
for (n, v) in rows.sorted(by: { $0.0 < $1.0 }) {
    let kind = n.contains("GPU") ? "GPU" : (n.contains("ACC MTR") || n.contains("PACC") || n.contains("ECPU") || n.contains("PCPU")) ? "CPU" : n.contains("tdie") ? "die" : ""
    print(n.padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: "%6.1f °C  ", v) + kind)
}
