//
//  main.swift
//  fans  —  unified CLI for GenesisFanControl
//
//  Shares GenesisFanControlCore with the SwiftUI app. Examples:
//
//      fans list                     # list all fans + sensors
//      fans get F0                   # show a fan's current state
//      fans sensors                  # list all sensors
//      fans sensor TC0E              # show one sensor's reading
//      fans set F0 auto              # automatic mode (OS-managed)
//      fans set F0 const 3500        # constant 3500 RPM
//      fans set F0 sensor TC0E 45 80 # sensor-controlled (low/high °C)
//      fans watch                    # tail readings every 1 s (Ctrl-C exits)
//

import Foundation
import GenesisFanControlCore

@MainActor
final class FansCLI {
    let state: AppState

    init() {
        // The CLI uses the same AppState — but we disable the polling timer
        // (RunLoop-driven) and call `tick()` ourselves when we need fresh data.
        // CRITICAL: forceSafeReset MUST be false here. AppState's default
        // `AppleSMCService()` does forceSafeReset=true, which on the GUI is
        // correct (cold-start safety after a crash). For the CLI it's
        // catastrophic — every `fans list` would silently revert the user's
        // pinned CONSTANT back to AUTO, indistinguishable from a bug. Cold-
        // start safety is the GUI's job; the CLI is a read/write client.
        let smc: SMCService = AppleSMCService(forceSafeReset: false) ?? MockSMCService()
        self.state = AppState(smc: smc, autoStartPolling: false)
        state.tick()
    }

    func run(args: [String]) throws -> Int32 {
        guard let command = args.first else {
            printUsage()
            return 0
        }
        switch command {
        case "list":         return cmdList()
        case "get":          return cmdGet(args: Array(args.dropFirst()))
        case "sensors":      return cmdSensors()
        case "sensor":       return cmdSensor(args: Array(args.dropFirst()))
        case "set":          return cmdSet(args: Array(args.dropFirst()))
        case "watch":        return cmdWatch(args: Array(args.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
            return 0
        default:
            FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
            printUsage()
            return 64
        }
    }

    // MARK: - Commands

    private func cmdList() -> Int32 {
        print("FANS")
        for fan in state.fans {
            print("  \(pad(fan.id, 4))  \(pad(fan.name, 16))  \(pad("\(fan.currentRPM) RPM", 12))  mode=\(fan.mode.displayName)")
        }
        print("")
        print("SENSORS (\(state.sensors.count))")
        for s in state.sensors {
            print("  \(pad(s.id, 6))  \(pad(s.name, 32))  \(String(format: "%5.1f °C", s.celsius))  [\(s.kind.rawValue)]")
        }
        return 0
    }

    private func cmdGet(args: [String]) -> Int32 {
        guard let id = args.first, let fan = state.fan(withID: id) else {
            FileHandle.standardError.write(Data("Usage: fans get <fanID>\n".utf8))
            return 64
        }
        print("Fan        : \(fan.name) (\(fan.id))")
        print("Mode       : \(fan.mode.displayName)")
        print("Current RPM: \(fan.currentRPM)")
        print("Target RPM : \(fan.targetRPM)")
        print("Range      : \(fan.minRPM) – \(fan.maxRPM)")
        print("Load       : \(Int(fan.loadFraction * 100))%")
        if case .sensorBased(let sid, let pts) = fan.mode {
            print("Sensor     : \(state.sensor(withID: sid)?.name ?? sid) (\(sid))")
            let curve = pts.sorted(by: { $0.tempC < $1.tempC })
                .map { "\(Int($0.tempC))°→\($0.rpm)" }
                .joined(separator: ", ")
            print("Ramp       : \(curve)")
        }
        return 0
    }

    private func cmdSensors() -> Int32 {
        for s in state.sensors {
            print("\(pad(s.id, 6))  \(pad(s.name, 32))  \(String(format: "%5.1f °C", s.celsius))  [\(s.kind.rawValue)]")
        }
        return 0
    }

    private func cmdSensor(args: [String]) -> Int32 {
        guard let id = args.first else {
            FileHandle.standardError.write(Data("Usage: fans sensor <sensorID>\n".utf8))
            return 64
        }
        // Re-tick a few times if the requested sensor is missing —
        // M-series ghost-value filter drops power-gated core reads,
        // so a fresh CLI process can fail on the first read if that
        // core happens to be asleep. Three ticks at ~250ms gives the
        // firmware time to wake it.
        var sensor = state.sensor(withID: id)
        var tries = 0
        while sensor == nil && tries < 4 {
            usleep(250_000)
            state.tick()
            sensor = state.sensor(withID: id)
            tries += 1
        }
        guard let s = sensor else {
            FileHandle.standardError.write(Data("sensor '\(id)' not present (power-gated? unknown ID?)\n".utf8))
            return 1
        }
        print("Sensor : \(s.name)")
        print("SMC key: \(s.id)")
        print("Kind   : \(s.kind.rawValue)")
        print("°C     : \(String(format: "%.2f", s.celsius))")
        print("°F     : \(String(format: "%.2f", s.fahrenheit))")
        return 0
    }

    private func cmdSet(args: [String]) -> Int32 {
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("""
            Usage:
              fans set <fanID> auto
              fans set <fanID> const <rpm>
              fans set <fanID> sensor <sensorID> <lowC> <highC>          (2-point ramp, lo→minRPM, hi→maxRPM)
              fans set <fanID> ramp   <sensorID> <c1:rpm1> <c2:rpm2> ...  (N-point ramp, ≥2 points)

            """.utf8))
            return 64
        }
        let fanID = args[0]
        guard let fan = state.fan(withID: fanID) else {
            FileHandle.standardError.write(Data("Unknown fan: \(fanID)\n".utf8))
            return 65
        }
        let kind = args[1]
        let mode: FanMode
        switch kind {
        case "auto":
            mode = .auto
        case "const":
            guard let rpm = Int(args[safe: 2] ?? "") else {
                FileHandle.standardError.write(Data("fans set <fanID> const <rpm>\n".utf8))
                return 64
            }
            mode = .constant(rpm: rpm)
        case "sensor":
            guard args.count >= 5,
                  let low = Double(args[3]),
                  let high = Double(args[4]) else {
                FileHandle.standardError.write(Data("fans set <fanID> sensor <sensorID> <lowC> <highC>\n".utf8))
                return 64
            }
            let sid = args[2]
            guard state.sensor(withID: sid) != nil else {
                FileHandle.standardError.write(Data("Unknown sensor: \(sid)\n".utf8))
                return 65
            }
            mode = .sensorBased(sensorId: sid,
                                lowTempC: low, highTempC: high,
                                minRPM: fan.minRPM, maxRPM: fan.maxRPM)
        case "ramp":
            // fans set F0 ramp <sensorID> <c:rpm> <c:rpm> ...
            guard args.count >= 5 else {
                FileHandle.standardError.write(Data("fans set <fanID> ramp <sensorID> <c1:rpm1> <c2:rpm2> ...\n".utf8))
                return 64
            }
            let sid = args[2]
            guard state.sensor(withID: sid) != nil else {
                FileHandle.standardError.write(Data("Unknown sensor: \(sid)\n".utf8))
                return 65
            }
            var pts: [RampPoint] = []
            for raw in args.dropFirst(3) {
                let parts = raw.split(separator: ":").map(String.init)
                guard parts.count == 2,
                      let c = Double(parts[0]),
                      let r = Int(parts[1]) else {
                    FileHandle.standardError.write(Data("Bad point '\(raw)' — expected <tempC>:<rpm>\n".utf8))
                    return 64
                }
                pts.append(RampPoint(tempC: c, rpm: r))
            }
            guard pts.count >= 2 else {
                FileHandle.standardError.write(Data("ramp needs at least 2 points\n".utf8))
                return 64
            }
            mode = .sensorBased(sensorId: sid, points: pts)
        default:
            FileHandle.standardError.write(Data("Unknown mode: \(kind) (use auto|const|sensor|ramp)\n".utf8))
            return 64
        }
        state.setMode(mode, for: fanID)
        print("OK — \(fanID) → \(mode.displayName)")
        return 0
    }

    private func cmdWatch(args: [String]) -> Int32 {
        let interval = TimeInterval(args.first.flatMap(Double.init) ?? 1.0)
        print("Watching every \(interval)s — Ctrl-C to stop.\n")
        while true {
            state.tick()
            let f = state.fans.map { "\($0.id)=\($0.currentRPM)" }.joined(separator: " ")
            let headline = state.headlineSensor
                .map { "\($0.id):\(String(format: "%.1f°C", $0.celsius))" } ?? "—"
            let ts = ISO8601DateFormatter().string(from: Date())
            print("\(ts)  \(headline)  \(f)")
            // RunLoop.run(until:) pumps the main run loop during the wait
            // so queued `@MainActor` tasks (e.g. Log.* publishing into
            // LogStore) actually execute. Thread.sleep would block the
            // run loop and starve those tasks indefinitely.
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }

    // MARK: - Helpers

    private func pad(_ s: String, _ n: Int) -> String {
        if s.count >= n { return s }
        return s + String(repeating: " ", count: n - s.count)
    }

    private func printUsage() {
        let text = """
        fans — command-line control for GenesisFanControl

        USAGE
          fans <command> [args]

        COMMANDS
          list                              List fans + sensors
          get   <fanID>                     Show a fan's current state
          sensors                           List all sensors
          sensor <sensorID>                 Show one sensor's reading
          set   <fanID> auto                Switch fan to automatic
          set   <fanID> const <rpm>         Hold a constant RPM
          set   <fanID> sensor <sid> <lo> <hi>
                                            Sensor-controlled fan curve
          watch [intervalSec]               Tail readings (Ctrl-C stops)
          help                              This message

        NOTE
          The current build uses a MOCK SMC backend — readings are synthetic
          and `set` writes don't reach real hardware. Replace MockSMCService
          with an IOKit AppleSMC implementation to drive real fans.
        """
        print(text)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        return indices.contains(i) ? self[i] : nil
    }
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())

let exitCode: Int32 = MainActor.assumeIsolated {
    do {
        return try FansCLI().run(args: args)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}
exit(exitCode)
