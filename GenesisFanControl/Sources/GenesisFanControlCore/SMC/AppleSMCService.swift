//
//  AppleSMCService.swift
//  GenesisFanControlCore
//
//  Real System Management Controller backend via IOKit. Talks to the
//  AppleSMC IOService using the standard 80-byte SMCParamStruct.
//
//  - Reads are unprivileged.
//  - Writes (mode/target RPM) require root on most Macs; we attempt them
//    anyway and log the SMC `result` byte on failure so the caller can
//    surface "needs sudo / privileged helper" in the UI.
//

import Foundation
import IOKit

// MARK: - Wire-level SMC types

private typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Explicit trailing pad — the C struct is 12 bytes; Swift would
    // otherwise pack it down to 9 and the kernel rejects the call.
    var _pad0: UInt8 = 0
    var _pad1: UInt8 = 0
    var _pad2: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers: SMCVersion = .init()
    var pLimitData: SMCPLimitData = .init()
    var keyInfo: SMCKeyInfoData = .init()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                              0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private enum SMCCall: UInt8 {
    case readKey    = 5
    case writeKey   = 6
    case getKeyInfo = 9
}

private let kSMCHandleYPCEvent: UInt32 = 2

// MARK: - Helpers

@inline(__always)
private func fourCC(_ s: String) -> UInt32 {
    precondition(s.utf8.count == 4, "SMC keys are 4 bytes")
    var v: UInt32 = 0
    for b in s.utf8 { v = (v << 8) | UInt32(b) }
    return v
}

@inline(__always)
private func fourCCString(_ k: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((k >> 24) & 0xFF),
        UInt8((k >> 16) & 0xFF),
        UInt8((k >> 8) & 0xFF),
        UInt8(k & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

/// Decode the 32-byte payload by type tag.
private enum SMCDecoder {
    static func toDouble(type: UInt32, size: UInt32, bytes: SMCBytes32) -> Double? {
        var b = bytes
        return withUnsafeBytes(of: &b) { raw -> Double? in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            switch fourCCString(type) {
            case "ui8 ":
                return Double(p[0])
            case "ui16":
                let v = (UInt16(p[0]) << 8) | UInt16(p[1])
                return Double(v)
            case "ui32":
                let v = (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
                return Double(v)
            case "si8 ":
                return Double(Int8(bitPattern: p[0]))
            case "si16":
                let raw = (UInt16(p[0]) << 8) | UInt16(p[1])
                return Double(Int16(bitPattern: raw))
            case "fpe2":
                let raw = (UInt16(p[0]) << 8) | UInt16(p[1])
                return Double(raw) / 4.0     // 14-bit int, 2-bit fraction
            case "sp78":
                let raw = Int16(bitPattern: (UInt16(p[0]) << 8) | UInt16(p[1]))
                return Double(raw) / 256.0   // signed 8.8 fixed-point
            case "flt ":
                var f: Float = 0
                memcpy(&f, p, 4)
                return Double(f)
            default:
                return nil
            }
        }
    }

    /// Encode an integer RPM into the 2-byte fpe2 payload most fan targets use.
    static func encodeFPE2(_ value: Int) -> (UInt8, UInt8) {
        let raw = UInt16(max(0, min(0x3FFF, value))) << 2   // 14.2 fixed
        return (UInt8(raw >> 8), UInt8(raw & 0xFF))
    }
}

// MARK: - AppleSMCService

public final class AppleSMCService: SMCService, @unchecked Sendable {
    public let backendName = "AppleSMC"
    public let isSimulated = false

    private var connection: io_connect_t = 0
    private var fanIndices: [Int] = []
    private var sensorKeys: [(key: String, name: String, kind: SensorKind)] = []
    private var cachedFans: [Fan] = []
    private var cachedSensors: [TempSensor] = []
    /// Routes writes through the privileged helper when direct SMC writes
    /// hit `kIOReturnNotPrivileged`. Set on construction; can be probed
    /// lazily later when the helper is installed.
    private let helperClient: HelperClient
    /// Per-fan cached mode-key case (F0Md vs F0md — varies by machine).
    private var modeKeyCache: [Int: String] = [:]

    /// Convenience init that returns nil if AppleSMC can't be opened
    /// (e.g. running in a sandbox without the kext, headless CI, etc.).
    /// `forceSafeReset` (default true) drops every fan we find in
    /// F0Md=1 back to F0Md=0 (auto) before the first snapshot. This
    /// closes review HIGH #5: if a previous run crashed mid-constant,
    /// thermalmonitord left F0Tg at whatever it last clamped, and a
    /// fresh init would otherwise adopt that value as "user intent"
    /// and re-assert it forever. Opt-out path exists for tests.
    public init?(helperClient: HelperClient = HelperClient(),
                 forceSafeReset: Bool = true) {
        self.helperClient = helperClient
        // Catch struct-layout regressions before they corrupt SMC writes.
        precondition(MemoryLayout<SMCParamStruct>.stride == 80,
                     "SMCParamStruct layout is wrong (expected 80 bytes, got \(MemoryLayout<SMCParamStruct>.stride)).")
        guard openSMC() else {
            Log.smc.error("AppleSMC could not be opened — falling back to mock backend")
            return nil
        }
        Log.smc.info("AppleSMC opened (connection=\(connection))")
        discoverFans()
        discoverSensors()
        Log.smc.info("AppleSMC discovered \(fanIndices.count) fans, \(sensorKeys.count) temperature sensors")
        if forceSafeReset {
            safeResetAllFansToAuto()
        }
        primeSnapshot()
    }

    /// Drop every fan currently in CONSTANT mode back to AUTO. Called
    /// at the start of every launch so a crashed previous run can't
    /// strand a fan pinned at the wrong RPM. Best-effort: failures are
    /// logged but don't block startup (helper might not be installed
    /// yet on first launch — user has to opt in via the elevation
    /// banner anyway).
    private func safeResetAllFansToAuto() {
        for i in fanIndices {
            let md = readDouble(modeKey(forFan: i)) ?? 0
            guard md >= 1 else { continue }
            // Use the same .auto path setMode does — direct then helper
            // fallback. Errors are logged inside.
            let fanID = "F\(i)"
            let ok = setMode(.auto, for: fanID)
            Log.fans.info("safeResetAllFansToAuto: \(fanID) was in CONSTANT, reset → \(ok ? "OK" : "failed (helper not yet available?)")")
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    // MARK: SMCService

    public func snapshot() -> (fans: [Fan], sensors: [TempSensor]) {
        return (cachedFans, cachedSensors)
    }

    public func refresh() {
        primeSnapshot()
    }

    @discardableResult
    public func setMode(_ mode: FanMode, for fanID: String) -> Bool {
        guard let idx = Int(fanID.dropFirst()) else {
            Log.fans.error("setMode: invalid fanID '\(fanID)'")
            return false
        }
        switch mode {
        case .auto:
            // Apple-Silicon-correct release: F0Md MUST be set back to 0
            // BEFORE Ftst is dropped. The firmware re-locks the moment
            // Ftst goes 1→0, and any subsequent F0Md write while the
            // lock is back silently fails — leaving the fan stuck in
            // CONSTANT despite us thinking we released. Symptom: user
            // clicks "Auto", UI optimistically flips to auto, helper
            // returns false, AppState reverts UI to the previous
            // constant ("blink and back to old setting").
            let mKey = modeKey(forFan: idx)
            if writeUInt8(key: mKey, value: 0) && writeUInt8(key: "Ftst", value: 0) {
                Log.fans.info("Fan \(fanID) -> AUTO (direct, F0Md=0 then Ftst=0)")
                updateCachedMode(for: fanID, to: .auto)
                return true
            }
            if helperClient.setMode(.auto, for: fanID) {
                Log.fans.info("Fan \(fanID) -> AUTO (via helper)")
                updateCachedMode(for: fanID, to: .auto)
                return true
            }
            Log.fans.error("Fan \(fanID) AUTO: direct + helper both failed")
            return false
        case .constant(let rpm):
            if unlockFanControl(fanIdx: idx) && writeRPM(fanIdx: idx, rpm: rpm) {
                Log.fans.info("Fan \(fanID) -> CONSTANT \(rpm) (direct)")
                updateCachedMode(for: fanID, to: .constant(rpm: rpm), targetRPM: rpm)
                return true
            }
            if helperClient.setMode(.constant(rpm: rpm), for: fanID) {
                Log.fans.info("Fan \(fanID) -> CONSTANT \(rpm) (via helper)")
                updateCachedMode(for: fanID, to: .constant(rpm: rpm), targetRPM: rpm)
                return true
            }
            Log.fans.error("Fan \(fanID) CONSTANT \(rpm): direct + helper both failed")
            return false
        case .sensorBased:
            // Sensor-based is host-driven (we compute the target RPM from
            // the chosen sensor each poll tick), but the SMC itself still
            // needs to be in CONSTANT (F0Md=1, Ftst unlocked) so the per-
            // tick writeRPM in primeSnapshot() actually moves the fan.
            // Without this, F0Md stayed at 0 (auto) and the firmware
            // ignored every F0Tg write — fan sat at its idle floor.
            if unlockFanControl(fanIdx: idx) {
                updateCachedMode(for: fanID, to: mode)
                Log.fans.info("Fan \(fanID) -> SENSOR-BASED (host-driven, unlocked direct)")
                return true
            }
            if helperClient.setMode(.constant(rpm: cachedFans.first(where: { $0.id == fanID })?.targetRPM ?? minSafeRPM(forFan: idx)),
                                    for: fanID) {
                // Helper successfully put us in constant. Switch cached
                // mode to sensorBased (host loop will drive target).
                updateCachedMode(for: fanID, to: mode)
                Log.fans.info("Fan \(fanID) -> SENSOR-BASED (host-driven, via helper)")
                return true
            }
            Log.fans.error("Fan \(fanID) SENSOR-BASED: failed to unlock fan control (direct + helper)")
            return false
        }
    }

    /// Floor used when we have to ask the helper to enter constant mode
    /// before sensor-based takes over driving — we don't want to spike
    /// the fan during the brief moment between the helper write and the
    /// next poll-tick target push.
    private func minSafeRPM(forFan idx: Int) -> Int {
        let minR = readDouble("F\(idx)Mn") ?? 1200
        return Int(minR)
    }


    // MARK: - Apple Silicon fan-control dance

    /// Apple Silicon firmware silently rejects `F0Md = 1` unless `Ftst`
    /// is unlocked first. Sequence cribbed from exelban/stats SMC.swift.
    private func unlockFanControl(fanIdx: Int) -> Bool {
        let mKey = modeKey(forFan: fanIdx)
        // Fast path: direct mode write (works on Intel + M5+).
        if writeUInt8(key: mKey, value: 1) { return true }

        // Slow path: read Ftst, write it to 1, wait, retry.
        let alreadyUnlocked: Bool
        if let v = readDouble("Ftst") {
            alreadyUnlocked = v >= 1
        } else {
            // No Ftst key — give up; either firmware is locking us out
            // some other way, or we're going through the helper anyway.
            return false
        }

        if alreadyUnlocked {
            for _ in 0..<20 {
                if writeUInt8(key: mKey, value: 1) { return true }
                usleep(50_000)
            }
            return false
        }

        var pushed = false
        for _ in 0..<100 {
            if writeUInt8(key: "Ftst", value: 1) { pushed = true; break }
            usleep(50_000)
        }
        if !pushed { return false }

        // Give thermalmonitord up to 3 s to yield control.
        usleep(3_000_000)
        for _ in 0..<300 {
            if writeUInt8(key: mKey, value: 1) { return true }
            usleep(100_000)
        }
        return false
    }

    /// Safety floor for any RPM write. The UI clamps in
    /// `AppState.applyOptimisticMode` but that's display-only; raw CLI /
    /// helper / programmatic calls bypass it. Anything below 800 RPM
    /// will be silently bumped — most Apple Silicon Macs spin their
    /// fans at 1200+ RPM minimum, and an actual 0 written into F0Tg can
    /// stall the bearing (review HIGH #2).
    private static let absoluteMinSafeRPM: Int = 800

    /// Write a target RPM honoring the key's actual data type. On
    /// Apple Silicon `F\(i)Tg` is `flt ` (4-byte IEEE 754); on Intel
    /// it's `fpe2` (2-byte 14.2 fixed-point). Caller-supplied `rpm` is
    /// clamped against the absolute floor BEFORE encoding so no path
    /// (CLI, helper, host re-assertion) can hit zero.
    private func writeRPM(fanIdx: Int, rpm rawRPM: Int) -> Bool {
        let rpm = max(Self.absoluteMinSafeRPM, rawRPM)
        if rpm != rawRPM {
            Log.fans.debug("Clamped F\(fanIdx)Tg write \(rawRPM) → \(rpm) (safety floor)")
        }
        let key = "F\(fanIdx)Tg"
        var info = SMCParamStruct()
        info.key = fourCC(key)
        info.data8 = SMCCall.getKeyInfo.rawValue
        guard let infoOut = call(input: info) else { return false }

        var write = SMCParamStruct()
        write.key = fourCC(key)
        write.keyInfo = infoOut.keyInfo
        write.data8 = SMCCall.writeKey.rawValue

        let typeStr = fourCCString(infoOut.keyInfo.dataType)
        switch typeStr {
        case "fpe2":
            let (hi, lo) = SMCDecoder.encodeFPE2(rpm)
            write.bytes.0 = hi
            write.bytes.1 = lo
        case "flt ":
            let f = Float(rpm)
            let bits = f.bitPattern
            // SMC stores flt little-endian — matches how we decode it.
            write.bytes.0 = UInt8(bits & 0xFF)
            write.bytes.1 = UInt8((bits >> 8) & 0xFF)
            write.bytes.2 = UInt8((bits >> 16) & 0xFF)
            write.bytes.3 = UInt8((bits >> 24) & 0xFF)
        case "ui16":
            let v = UInt16(max(0, min(Int(UInt16.max), rpm)))
            write.bytes.0 = UInt8(v >> 8)
            write.bytes.1 = UInt8(v & 0xFF)
        default:
            Log.smc.error("Unsupported \(key) type '\(typeStr)' — refusing to write")
            return false
        }

        guard let writeOut = call(input: write) else { return false }
        return writeOut.result == 0
    }

    /// Probes both `F\(i)Md` (uppercase) and `F\(i)md` (lowercase) and
    /// caches whichever one the SMC answers. Different machines expose
    /// different case.
    private func modeKey(forFan idx: Int) -> String {
        if let cached = modeKeyCache[idx] { return cached }
        let upper = "F\(idx)Md"
        let lower = "F\(idx)md"
        if readDouble(upper) != nil { modeKeyCache[idx] = upper; return upper }
        if readDouble(lower) != nil { modeKeyCache[idx] = lower; return lower }
        modeKeyCache[idx] = upper
        return upper
    }

    // MARK: - SMC primitives

    private func openSMC() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        return kr == KERN_SUCCESS
    }

    /// Look up data type + size for a key, then read the payload.
    private func readKey(_ key: String) -> (type: UInt32, size: UInt32, bytes: SMCBytes32)? {
        // Phase 1: getKeyInfo
        var info = SMCParamStruct()
        info.key = fourCC(key)
        info.data8 = SMCCall.getKeyInfo.rawValue
        guard let infoOut = call(input: info) else { return nil }
        let size = infoOut.keyInfo.dataSize
        let type = infoOut.keyInfo.dataType
        guard size > 0 else { return nil }

        // Phase 2: readKey
        var read = SMCParamStruct()
        read.key = fourCC(key)
        read.keyInfo.dataSize = size
        read.data8 = SMCCall.readKey.rawValue
        guard let readOut = call(input: read) else { return nil }
        if readOut.result != 0 {
            Log.smc.debug("SMC read \(key) result=\(readOut.result)")
            return nil
        }
        return (type, size, readOut.bytes)
    }

    /// Read a key and pull the numeric value as a Double — works for
    /// fpe2 / sp78 / flt / ui* / si* tagged payloads.
    private func readDouble(_ key: String) -> Double? {
        guard let r = readKey(key) else { return nil }
        return SMCDecoder.toDouble(type: r.type, size: r.size, bytes: r.bytes)
    }

    private func writeUInt8(key: String, value: UInt8) -> Bool {
        // Get the existing key info first so the kernel accepts the write.
        var info = SMCParamStruct()
        info.key = fourCC(key)
        info.data8 = SMCCall.getKeyInfo.rawValue
        guard let infoOut = call(input: info) else { return false }
        var write = SMCParamStruct()
        write.key = fourCC(key)
        write.keyInfo = infoOut.keyInfo
        write.data8 = SMCCall.writeKey.rawValue
        write.bytes.0 = value
        guard let writeOut = call(input: write) else { return false }
        return writeOut.result == 0
    }

    private func call(input: SMCParamStruct) -> SMCParamStruct? {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let inputSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input, inputSize,
            &output, &outputSize
        )
        guard kr == KERN_SUCCESS else {
            Log.smc.debug("IOConnectCallStructMethod kr=\(kr)")
            return nil
        }
        return output
    }

    // MARK: - Discovery

    private func discoverFans() {
        guard let n = readDouble("FNum") else {
            fanIndices = []
            return
        }
        fanIndices = (0..<Int(n)).map { $0 }
    }

    /// Known SMC keys that resolve on Apple Silicon Macs (M1/M2/M3/M4)
    /// plus a few Intel-era keys for backward compatibility. We probe each
    /// at discovery time and only keep the ones the chip actually answers.
    private static let candidateSensors: [(String, String, SensorKind)] = [
        // CPU
        ("TC0E", "CPU Die Temperature", .cpu),
        ("TC0F", "CPU Die Filtered", .cpu),
        ("TC0P", "CPU Proximity", .cpu),
        ("TC0H", "CPU Heatpipe", .cpu),
        ("TC1C", "CPU Core 1", .cpu),
        ("TC2C", "CPU Core 2", .cpu),
        ("TC3C", "CPU Core 3", .cpu),
        ("TC4C", "CPU Core 4", .cpu),
        // Apple-Silicon performance cores (M1/M2/M3/M4 — up to 8 per cluster)
        ("Tp09", "CPU Performance Core 1", .cpu),
        ("Tp0T", "CPU Performance Core 2", .cpu),
        ("Tp0b", "CPU Performance Core 3", .cpu),
        ("Tp0d", "CPU Performance Core 4", .cpu),
        ("Tp01", "CPU Performance Core 5", .cpu),
        ("Tp05", "CPU Performance Core 6", .cpu),
        ("Tp0D", "CPU Performance Core 7", .cpu),
        ("Tp0X", "CPU Performance Core 8", .cpu),
        // Apple-Silicon efficiency cores
        ("Tp0f", "CPU Efficiency Core 1", .cpu),
        ("Tp0n", "CPU Efficiency Core 2", .cpu),
        ("Tp0r", "CPU Efficiency Core 3", .cpu),
        ("Tp0t", "CPU Efficiency Core 4", .cpu),
        ("Tp0v", "CPU Efficiency Core 5", .cpu),
        ("Tp0z", "CPU Efficiency Core 6", .cpu),
        // GPU
        ("TG0D", "GPU Die", .gpu),
        ("TG0P", "GPU Proximity", .gpu),
        ("TG0H", "GPU Heatpipe", .gpu),
        ("Tg05", "GPU Cluster 1", .gpu),
        ("Tg0D", "GPU Cluster 2", .gpu),
        ("Tg0L", "GPU Cluster 3", .gpu),
        ("Tg0T", "GPU Cluster 4", .gpu),
        ("Tg0V", "GPU Cluster 5", .gpu),
        ("Tg0d", "GPU Cluster 6", .gpu),
        // Battery
        ("TB0T", "Battery", .battery),
        ("TB1T", "Battery Cell 1", .battery),
        ("TB2T", "Battery Cell 2", .battery),
        // Storage
        ("TH0a", "NVMe SSD", .storage),
        ("TH0b", "NVMe SSD Drive", .storage),
        ("TH0x", "SSD Hottest", .storage),
        // Airport / Thunderbolt / Misc proximities
        ("TW0P", "Airport Proximity", .airport),
        ("TTLD", "Thunderbolt Left", .thunderbolt),
        ("TTRD", "Thunderbolt Right", .thunderbolt),
        ("TPCD", "Platform Controller", .proximity),
        ("Ts0S", "Palm Rest", .proximity),
        // Power
        ("TPDA", "Power Manager Die Avg", .power),
        ("TPSP", "Power Supply Proximity", .power),
        // Trackpad — different M-series machines expose different keys.
        ("TTPD", "Trackpad", .trackpad),
        ("Ttp0", "Trackpad", .trackpad),
        ("TaaP", "Trackpad", .trackpad),
        ("TaaS", "Trackpad Surface", .trackpad),
    ]

    private func discoverSensors() {
        var found: [(String, String, SensorKind)] = []
        for (key, name, kind) in Self.candidateSensors {
            if readDouble(key) != nil {
                found.append((key, name, kind))
            }
        }
        sensorKeys = found
    }

    // MARK: - Snapshot

    private func primeSnapshot() {
        // Fans
        var newFans: [Fan] = []
        for i in fanIndices {
            let actual = readDouble("F\(i)Ac") ?? 0
            let minR   = readDouble("F\(i)Mn") ?? 0
            let maxR   = readDouble("F\(i)Mx") ?? max(actual, 6000)
            let target = readDouble("F\(i)Tg") ?? actual
            let md     = readDouble(modeKey(forFan: i)) ?? 0

            let existing = cachedFans.first(where: { $0.id == "F\(i)" })
            let baseMode: FanMode
            if md >= 1 {
                baseMode = .constant(rpm: Int(target))
            } else {
                baseMode = .auto
            }
            // Preserve host-driven modes — SMC doesn't reliably report
            // them back to us:
            //  • .sensorBased: SMC has no concept of it, so we keep ours.
            //  • .constant: Apple Silicon's thermalmonitord can clamp F0Tg
            //    back to whatever it thinks the current load needs (e.g.
            //    we wrote 5500, readback returns 4142). Trust the value
            //    we last wrote, not the firmware's claw-back. The host
            //    loop at the bottom of this method re-asserts the write
            //    on every tick so the physical fan stays where we put it.
            let mode: FanMode
            let displayedTarget: Int
            if case .sensorBased = existing?.mode {
                mode = existing!.mode
                displayedTarget = existing?.targetRPM ?? Int(target)
            } else if case .constant(let cachedRPM) = existing?.mode, md >= 1 {
                mode = .constant(rpm: cachedRPM)
                displayedTarget = cachedRPM
            } else {
                mode = baseMode
                displayedTarget = Int(target)
            }

            newFans.append(Fan(
                id: "F\(i)",
                name: fanName(for: i),
                minRPM: Int(minR),
                maxRPM: Int(maxR),
                currentRPM: Int(actual),
                targetRPM: displayedTarget,
                mode: mode
            ))
        }

        // Real sensors
        var newSensors: [TempSensor] = []
        for (key, name, kind) in sensorKeys {
            guard let c = readDouble(key) else { continue }
            // Out-of-band readings (sensor not populated) — skip
            guard c > -20, c < 130 else { continue }
            newSensors.append(TempSensor(id: key, name: name, kind: kind, celsius: c))
        }

        // Virtual aggregates — avg/max across logical groups. These appear
        // in both the right rail and the sensor-based mode picker so the
        // user can target "hottest CPU core" with a single selection.
        newSensors.append(contentsOf: virtualSensors(from: newSensors))

        cachedFans = newFans
        cachedSensors = newSensors

        // Host-side per-tick fan-control re-assertion. Two cases:
        //  • .sensorBased: compute the curve value from the chosen sensor.
        //  • .constant: re-push the user's setpoint. Apple Silicon's
        //    thermalmonitord otherwise claws F0Tg back to whatever it
        //    thinks the current load needs, so the physical fan drifts
        //    away from what the user pinned.
        //
        // Routing: try a direct writeRPM first (fast, no IPC, succeeds
        // when this process happens to have SMC write privileges); on
        // failure route through helper.setTarget (one cheap socket call
        // — the helper runs as root so the SMC write actually lands).
        // The GUI is non-root, so on Apple Silicon the helper path is
        // typically the one that actually moves the fan.
        for fan in cachedFans {
            guard let fanIdx = Int(fan.id.dropFirst()) else { continue }
            let target: Int?
            switch fan.mode {
            case .sensorBased(let sid, let pts):
                if let s = newSensors.first(where: { $0.id == sid }) {
                    target = rpmForTemp(s.celsius, fan: fan, points: pts)
                } else {
                    target = nil
                }
            case .constant(let rpm):
                target = rpm
            case .auto:
                target = nil
            }
            guard let rpm = target else { continue }
            // No dedupe by "target unchanged" — we MUST push every tick
            // even when our intent is identical, because the firmware's
            // claw-back changes the SMC's view (F0Tg/F0Ac) without
            // changing ours. Re-pushing is what keeps the physical fan
            // pinned. helperClient.setMode(.constant(...)) wraps a single
            // socket round-trip + unlock-already-succeeded fast path; the
            // cost is in the order of a millisecond per fan per tick.
            if !writeRPM(fanIdx: fanIdx, rpm: rpm) {
                _ = helperClient.setMode(.constant(rpm: rpm), for: fan.id)
            }
        }
    }

    private func fanName(for index: Int) -> String {
        switch index {
        case 0: return "Left side"
        case 1: return "Right side"
        case 2: return "Fan 3"
        case 3: return "Fan 4"
        default: return "Fan \(index + 1)"
        }
    }

    /// Piecewise-linear interpolation over the user's ramp. Points are
    /// sorted by tempC; outside the range, the endpoint rpm is held.
    /// Returned rpm is clamped into the fan's [minRPM, maxRPM] envelope.
    private func rpmForTemp(_ c: Double, fan: Fan, points: [RampPoint]) -> Int {
        let sorted = points.sorted(by: { $0.tempC < $1.tempC })
        guard let first = sorted.first else { return fan.minRPM }
        guard sorted.count >= 2 else { return clampRPM(first.rpm, fan: fan) }
        if c <= first.tempC { return clampRPM(first.rpm, fan: fan) }
        if c >= sorted.last!.tempC { return clampRPM(sorted.last!.rpm, fan: fan) }
        // Find the segment [a, b] enclosing c.
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if c >= a.tempC && c <= b.tempC {
                let span = b.tempC - a.tempC
                guard span > 0 else { return clampRPM(a.rpm, fan: fan) }
                let t = (c - a.tempC) / span
                let rpm = Double(a.rpm) + t * Double(b.rpm - a.rpm)
                return clampRPM(Int(rpm.rounded()), fan: fan)
            }
        }
        return clampRPM(sorted.last!.rpm, fan: fan)
    }

    private func clampRPM(_ rpm: Int, fan: Fan) -> Int {
        max(fan.minRPM, min(fan.maxRPM, rpm))
    }

    // MARK: - Virtual sensors

    /// Compute aggregate temperatures for the picker / right rail. IDs
    /// are prefixed with "__" so they can't collide with real SMC keys.
    /// `sensorBased` mode picks them up automatically because the host
    /// loop in `primeSnapshot()` looks the chosen sensor up by ID inside
    /// the returned list (which now includes these aggregates).
    private func virtualSensors(from real: [TempSensor]) -> [TempSensor] {
        var out: [TempSensor] = []

        // CPU performance cores
        let perf = real.filter { isPerformanceCore($0.id) }
        if let avg = avg(perf), let mx = mx(perf) {
            out.append(.init(id: "__cpu_perf_avg",
                             name: "CPU Performance · Avg",
                             kind: .cpu, celsius: avg))
            out.append(.init(id: "__cpu_perf_max",
                             name: "CPU Performance · Max",
                             kind: .cpu, celsius: mx))
        }

        // CPU efficiency cores
        let eff = real.filter { isEfficiencyCore($0.id) }
        if let avg = avg(eff), let mx = mx(eff) {
            out.append(.init(id: "__cpu_eff_avg",
                             name: "CPU Efficiency · Avg",
                             kind: .cpu, celsius: avg))
            out.append(.init(id: "__cpu_eff_max",
                             name: "CPU Efficiency · Max",
                             kind: .cpu, celsius: mx))
        }

        // Whole-CPU rollup (all cores combined)
        let allCPU = real.filter { $0.kind == .cpu }
        if let avg = avg(allCPU), let mx = mx(allCPU) {
            out.append(.init(id: "__cpu_all_avg",
                             name: "CPU All Cores · Avg",
                             kind: .cpu, celsius: avg))
            out.append(.init(id: "__cpu_all_max",
                             name: "CPU All Cores · Max",
                             kind: .cpu, celsius: mx))
        }

        // GPU clusters
        let gpu = real.filter { $0.kind == .gpu && $0.id.hasPrefix("Tg") }
        if let avg = avg(gpu), let mx = mx(gpu) {
            out.append(.init(id: "__gpu_avg",
                             name: "GPU Clusters · Avg",
                             kind: .gpu, celsius: avg))
            out.append(.init(id: "__gpu_max",
                             name: "GPU Clusters · Max",
                             kind: .gpu, celsius: mx))
        }
        return out
    }

    private func isPerformanceCore(_ id: String) -> Bool {
        // 4-char keys starting with "Tp" and ending in 9 / T / b / d (M1/M2)
        // or 1 / 5 / D / X (M3/M4 extensions).
        guard id.hasPrefix("Tp"), id.count == 4 else { return false }
        let suffix = id.suffix(1)
        return ["9", "T", "b", "d", "1", "5", "D", "X"].contains(String(suffix))
    }

    private func isEfficiencyCore(_ id: String) -> Bool {
        // Efficiency cores use Tp0{f,n,r,t,v,z} on M-series.
        guard id.hasPrefix("Tp0"), id.count == 4 else { return false }
        let suffix = id.suffix(1)
        return ["f", "n", "r", "t", "v", "z"].contains(String(suffix))
    }

    private func avg(_ xs: [TempSensor]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.map(\.celsius).reduce(0, +) / Double(xs.count)
    }

    private func mx(_ xs: [TempSensor]) -> Double? {
        xs.map(\.celsius).max()
    }

    // MARK: - In-memory mode bookkeeping

    private func updateCachedMode(for fanID: String, to mode: FanMode, targetRPM: Int? = nil) {
        guard let i = cachedFans.firstIndex(where: { $0.id == fanID }) else { return }
        cachedFans[i].mode = mode
        if let t = targetRPM { cachedFans[i].targetRPM = t }
    }
}
