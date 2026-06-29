//
//  HelperInstaller.swift
//  GenesisFanControlCore
//
//  Installs the genesis-fan-control-helper daemon by asking the user for an
//  admin password via osascript, then copying the helper binary into
//  /usr/local/sbin, dropping a launchd plist in /Library/LaunchDaemons,
//  and loading it.
//
//  This is the unsigned-developer path. A production app would do this
//  via SMAppService.daemon(plistName:).register() with a signed bundle
//  carrying the helper at Contents/Library/LaunchDaemons/.
//

import Foundation

public enum HelperInstallError: Error, CustomStringConvertible {
    case helperBinaryNotFound(searched: [String])
    case osascript(String)
    case timeout

    public var description: String {
        switch self {
        case .helperBinaryNotFound(let s):
            return "genesis-fan-control-helper binary not found. Looked in:\n  - \(s.joined(separator: "\n  - "))"
        case .osascript(let s):
            return "Privileged install failed: \(s)"
        case .timeout:
            return "Privileged install timed out (did you cancel the prompt?)."
        }
    }
}

public enum HelperInstaller {
    /// Where the helper binary might live in dev. swift build emits it to
    /// .build/<config>/genesis-fan-control-helper next to the GUI binary.
    private static func candidateHelperPaths() -> [String] {
        var paths: [String] = []
        // sibling of the running binary (the normal dev path)
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        paths.append(exe.appendingPathComponent("genesis-fan-control-helper").path)
        // explicit env override useful for CI / packaging
        if let env = ProcessInfo.processInfo.environment["GFC_HELPER_BINARY"] {
            paths.insert(env, at: 0)
        }
        // .build/debug + .build/release relative to cwd
        let cwd = FileManager.default.currentDirectoryPath
        paths.append("\(cwd)/.build/debug/genesis-fan-control-helper")
        paths.append("\(cwd)/.build/release/genesis-fan-control-helper")
        return paths
    }

    /// Runs an osascript "do shell script ... with administrator privileges"
    /// — pops the system password prompt once, executes our install script
    /// as root. Returns when the helper socket actually answers.
    public static func install() throws {
        let helperBinary = try locateHelperBinary()

        // The shell script copies, writes the plist, loads it via launchctl.
        let plistXML = launchdPlistContents()
        let script = """
        set -e
        # Sweep up legacy MacsFanControl-era helper — different label/path,
        # so the new daemon would otherwise race with the old buggy one.
        launchctl bootout system /Library/LaunchDaemons/dev.foltyn.macsfancontrol.helper.plist 2>/dev/null || true
        rm -f /Library/LaunchDaemons/dev.foltyn.macsfancontrol.helper.plist
        rm -f /usr/local/sbin/macsfancontrol-helper
        rm -f /var/run/macsfancontrol.sock
        mkdir -p /usr/local/sbin
        cp '\(helperBinary)' '\(HelperConstants.installedHelperPath)'
        chown root:wheel '\(HelperConstants.installedHelperPath)'
        chmod 755 '\(HelperConstants.installedHelperPath)'
        cat > '\(HelperConstants.launchDaemonPath)' << 'PLIST_EOF'
        \(plistXML)
        PLIST_EOF
        chown root:wheel '\(HelperConstants.launchDaemonPath)'
        chmod 644 '\(HelperConstants.launchDaemonPath)'
        launchctl bootout system '\(HelperConstants.launchDaemonPath)' 2>/dev/null || true
        launchctl bootstrap system '\(HelperConstants.launchDaemonPath)'
        launchctl enable system/\(HelperConstants.helperLabel) 2>/dev/null || true
        launchctl kickstart -k system/\(HelperConstants.helperLabel)
        """

        try runWithAdminPrivileges(script: script)

        // Wait up to 3s for the socket to come up.
        let deadline = Date().addingTimeInterval(3.0)
        let client = HelperClient()
        while Date() < deadline {
            if client.ping() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HelperInstallError.timeout
    }

    /// Uninstall via the same admin prompt. Used by a "Remove" button (or
    /// from the CLI for cleanup during development).
    public static func uninstall() throws {
        let script = """
        launchctl bootout system '\(HelperConstants.launchDaemonPath)' 2>/dev/null || true
        rm -f '\(HelperConstants.launchDaemonPath)'
        rm -f '\(HelperConstants.installedHelperPath)'
        rm -f '\(HelperConstants.socketPath)'
        """
        try runWithAdminPrivileges(script: script)
    }

    // MARK: -

    private static func locateHelperBinary() throws -> String {
        let candidates = candidateHelperPaths()
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw HelperInstallError.helperBinaryNotFound(searched: candidates)
    }

    private static func runWithAdminPrivileges(script: String) throws {
        // Build an AppleScript that wraps our shell script in a privileged
        // shell call. Escape single quotes by closing/reopening the string.
        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(escaped)" with administrator privileges
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]

        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        do {
            try task.run()
        } catch {
            throw HelperInstallError.osascript("could not launch osascript: \(error)")
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw HelperInstallError.osascript(stderr.isEmpty ? "exit \(task.terminationStatus)" : stderr)
        }
    }

    private static func launchdPlistContents() -> String {
        return #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\#(HelperConstants.helperLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\#(HelperConstants.installedHelperPath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>/var/log/genesis-fan-control-helper.log</string>
          <key>StandardErrorPath</key>
          <string>/var/log/genesis-fan-control-helper.err.log</string>
        </dict>
        </plist>
        """#
    }
}
