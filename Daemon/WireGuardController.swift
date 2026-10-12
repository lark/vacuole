// Copyright 2026 Wang Jian
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import VacuoleShared

/// Simple command execution error
struct CmdError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// WireGuard tunnel controller (inside the root daemon).
///
/// Orchestrates wireguard-go / wg / ifconfig (does not use wg-quick); split routes are installed separately by RouteController.
/// All operations run synchronously; the XPC caller dispatches them on a background thread.
final class WireGuardController {

    static let shared = WireGuardController()

    private(set) var tunnelState: TunnelState = .stopped
    private(set) var activeConfigName: String?
    private(set) var interfaceName: String?
    private(set) var peerAddress: String?
    /// Address part of the peer endpoint (without port), used to exclude it from the tunnel
    private(set) var endpointAddress: String?
    /// DNS servers declared by the active config (the `DNS =` line, if any)
    private(set) var activeConfigDNSServers: [String] = []
    private(set) var lastError: String?

    private let wireguardGoPath: String?
    private let wgPath: String?
    private var wireguardGoProc: Process?
    /// Output pipe of wireguard-go. The readabilityHandler must be cleared explicitly after the process exits,
    /// otherwise the READ-type DispatchSource keeps firing once the pipe hits EOF, pinning the daemon at 100% CPU.
    private var logPipe: Pipe?

    private init() {
        wireguardGoPath = WireGuardController.findBinary("wireguard-go")
        wgPath = WireGuardController.findBinary("wg")
    }

    // MARK: - Config management

    func importConfig(name: String, rawConfig: String) -> (Bool, String?) {
        let dir = VacuoleDaemonConstants.configsDir
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return (false, L("daemon.config.createDirFailed", dir, error.localizedDescription))
        }
        let lower = rawConfig.lowercased()
        guard lower.contains("[interface]") else {
            return (false, L("daemon.config.missingInterfaceSection"))
        }
        guard lower.contains("[peer]") else {
            return (false, L("daemon.config.missingPeerSection"))
        }
        let path = "\(dir)/\(name).conf"
        do {
            try rawConfig.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return (true, nil)
        } catch {
            return (false, L("daemon.config.writeFailed", error.localizedDescription))
        }
    }

    func deleteConfig(name: String) -> (Bool, String?) {
        let path = "\(VacuoleDaemonConstants.configsDir)/\(name).conf"
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, L("daemon.config.notFound", name))
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return (true, nil)
        } catch {
            return (false, L("daemon.config.deleteFailed", error.localizedDescription))
        }
    }

    struct ConfigEntry: Codable {
        let name: String
        let rawConfig: String
    }

    func listConfigs() -> (Data?, String?) {
        let dir = VacuoleDaemonConstants.configsDir
        guard FileManager.default.fileExists(atPath: dir) else {
            return (try? JSONEncoder().encode([ConfigEntry]()), nil)
        }
        var entries: [ConfigEntry] = []
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: dir)
                .filter { $0.hasSuffix(".conf") }
                .sorted()
            for file in files {
                let name = String(file.dropLast(".conf".count))
                let path = "\(dir)/\(file)"
                let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                entries.append(ConfigEntry(name: name, rawConfig: raw))
            }
        } catch {
            return (nil, L("daemon.config.readDirFailed", error.localizedDescription))
        }
        guard let data = try? JSONEncoder().encode(entries) else {
            return (nil, L("daemon.config.encodeFailed"))
        }
        return (data, nil)
    }

    // MARK: - Tunnel start/stop

    func startTunnel(configName: String) -> (Bool, String?) {
        guard tunnelState != .running && tunnelState != .starting else {
            return (false, L("daemon.tunnel.alreadyRunning"))
        }
        guard let wgGo = wireguardGoPath else {
            return (false, L("daemon.tunnel.wireguardGoMissing"))
        }
        guard let wg = wgPath else {
            return (false, L("daemon.tunnel.wgMissing"))
        }

        tunnelState = .starting

        // 1. Read config
        let confPath = "\(VacuoleDaemonConstants.configsDir)/\(configName).conf"
        guard FileManager.default.fileExists(atPath: confPath) else {
            tunnelState = .error
            return (false, L("daemon.config.notFound", configName))
        }
        let rawConfig = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
        let parsed = WGConfigParser.parse(rawConfig)

        guard let firstAddr = parsed.addresses.first else {
            tunnelState = .error
            return (false, L("daemon.tunnel.addressMissing"))
        }
        guard let peer = parsed.peers.first, !peer.publicKey.isEmpty else {
            tunnelState = .error
            LogStore.shared.error("wg", "Config \(configName) is missing [Peer] PublicKey")
            return (false, L("daemon.tunnel.peerPublicKeyMissing"))
        }

        LogStore.shared.info("wg", "Starting tunnel: config=\(configName) address=\(firstAddr)")

        // 2. Start wireguard-go and obtain the utun interface name
        let startResult = startWireguardGo(at: wgGo)
        switch startResult {
        case .success(let ifname):
            self.interfaceName = ifname
            LogStore.shared.info("wg", "wireguard-go started, interface=\(ifname)")
        case .failure(let err):
            tunnelState = .error
            LogStore.shared.error("wg", "Failed to start wireguard-go: \(err.message)")
            return (false, L("daemon.tunnel.wireguardGoStartFailed", err.message))
        }
        guard let ifname = self.interfaceName else {
            tunnelState = .error
            return (false, L("daemon.tunnel.ifnameUnavailable"))
        }

        // 3. Generate a wg-compatible config (strip wg-quick-specific fields)
        let wgConf = WireGuardController.stripWgQuickDirectives(rawConfig)
        let tmpConf = "/tmp/vacuole_\(configName)_wg.conf"
        do {
            try wgConf.write(toFile: tmpConf, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpConf)
        } catch {
            stopWireguardGo()
            tunnelState = .error
            return (false, L("daemon.tunnel.writeTempConfigFailed", error.localizedDescription))
        }

        // 4. wg setconf
        let setResult = runCommand(path: wg, args: ["setconf", ifname, tmpConf])
        if case .failure(let err) = setResult {
            stopWireguardGo()
            try? FileManager.default.removeItem(atPath: tmpConf)
            tunnelState = .error
            return (false, L("daemon.tunnel.setconfFailed", err.message))
        }

        // 5. Configure the interface address via ifconfig (point-to-point)
        let addrOnly = firstAddr.split(separator: "/").first.map(String.init) ?? firstAddr

        // macOS utun is a point-to-point interface: the destination must be this interface's own address.
        // If a public endpoint is used, a route pointing the endpoint back into the tunnel itself is created,
        // causing handshake packets to loop into the tunnel and never get sent (connection cannot be established).
        let peerAddr = addrOnly

        let ifconfigResult = runCommand(path: "/sbin/ifconfig", args: [ifname, "inet", "\(addrOnly)/32", peerAddr, "alias"])
        if case .failure(let err) = ifconfigResult {
            stopWireguardGo()
            try? FileManager.default.removeItem(atPath: tmpConf)
            tunnelState = .error
            return (false, L("daemon.tunnel.ifconfigAddrFailed", err.message))
        }

        // 6. ifconfig up
        let upResult = runCommand(path: "/sbin/ifconfig", args: [ifname, "up"])
        if case .failure(let err) = upResult {
            stopWireguardGo()
            try? FileManager.default.removeItem(atPath: tmpConf)
            tunnelState = .error
            return (false, L("daemon.tunnel.ifconfigUpFailed", err.message))
        }

        // 7. Set MTU (optional)
        if let mtu = parsed.mtu {
            _ = runCommand(path: "/sbin/ifconfig", args: [ifname, "mtu", String(mtu)])
        }

        try? FileManager.default.removeItem(atPath: tmpConf)

        tunnelState = .running
        activeConfigName = configName
        peerAddress = peerAddr
        endpointAddress = WireGuardController.hostPart(peer.endpoint)
        activeConfigDNSServers = parsed.dnsServers
        LogStore.shared.info("wg", "Tunnel running: \(ifname) address=\(addrOnly) endpoint=\(endpointAddress ?? "?")")
        return (true, nil)
    }

    func stopTunnel() -> (Bool, String?) {
        guard tunnelState == .running || tunnelState == .error else {
            return (false, L("daemon.tunnel.notRunning"))
        }
        LogStore.shared.info("wg", "Stopping tunnel: \(activeConfigName ?? "?")")
        tunnelState = .stopping

        stopWireguardGo()

        if let ifname = interfaceName {
            _ = runCommand(path: "/sbin/ifconfig", args: [ifname, "down"])
        }

        tunnelState = .stopped
        activeConfigName = nil
        interfaceName = nil
        peerAddress = nil
        endpointAddress = nil
        activeConfigDNSServers = []
        return (true, nil)
    }

    /// Extract the host part from an endpoint string (supports the IPv6 "[..]:port" form)
    private static func hostPart(_ endpoint: String?) -> String? {
        guard let endpoint = endpoint, !endpoint.isEmpty else { return nil }
        if endpoint.hasPrefix("[") {
            if let close = endpoint.firstIndex(of: "]") {
                return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            }
            return nil
        }
        // Only split as host:port when there is exactly one colon (unbracketed IPv6 has several)
        let colonCount = endpoint.filter { $0 == ":" }.count
        if colonCount == 1, let colon = endpoint.firstIndex(of: ":") {
            return String(endpoint[..<colon])
        }
        return endpoint
    }

    // MARK: - Internals

    private func startWireguardGo(at path: String) -> Result<String, CmdError> {
        // Run with -f (foreground) so this process can supervise and reliably terminate it; otherwise wireguard-go daemonizes itself.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-f", "utun"]

        // Use WG_TUN_NAME_FILE to have wireguard-go report the real interface name (more reliable than parsing stdout)
        let nameFile = "/var/run/wireguard/vacuole.name"
        try? FileManager.default.createDirectory(atPath: "/var/run/wireguard",
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: nameFile)

        var env = ProcessInfo.processInfo.environment
        env["WG_TUN_NAME_FILE"] = nameFile
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        logPipe = pipe
        // Drain the pipe asynchronously so a full buffer doesn't block wireguard-go, while capturing logs into LogStore.
        // Note: clear the handler on EOF, otherwise the READ source keeps firing (the root cause of runaway 100% CPU).
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            guard let s = String(data: d, encoding: .utf8) else { return }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                LogStore.shared.info("wg-go", trimmed)
            }
        }

        do {
            try proc.run()
        } catch {
            return .failure(CmdError("Process start failed: \(error.localizedDescription)"))
        }
        wireguardGoProc = proc

        // 1) Poll the name file (up to 5s)
        var ifname: String?
        let nameDeadline = Date().addingTimeInterval(5)
        while Date() < nameDeadline {
            if let content = try? String(contentsOfFile: nameFile, encoding: .utf8) {
                let name = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && name.lowercased().hasPrefix("utun") {
                    ifname = name
                    break
                }
            }
            if !proc.isRunning {
                return .failure(CmdError("wireguard-go exited immediately after start"))
            }
            usleep(100_000)
        }
        guard let name = ifname else {
            stopWireguardGo()
            return .failure(CmdError("Timed out waiting for wireguard-go to report the interface name"))
        }

        // 2) Poll for socket readiness (up to 3s), otherwise wg setconf reports No such file or directory
        let sockPath = "/var/run/wireguard/\(name).sock"
        let sockDeadline = Date().addingTimeInterval(3)
        while Date() < sockDeadline {
            if FileManager.default.fileExists(atPath: sockPath) {
                return .success(name)
            }
            usleep(100_000)
        }
        return .failure(CmdError("Timed out waiting for the interface socket to become ready: \(sockPath)"))
    }

    private func stopWireguardGo() {
        if let proc = wireguardGoProc {
            if proc.isRunning {
                proc.terminate()   // SIGTERM
                // Wait up to 3s, then SIGKILL if still running
                let deadline = Date().addingTimeInterval(3)
                while proc.isRunning && Date() < deadline {
                    usleep(100_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
            proc.waitUntilExit()
            wireguardGoProc = nil
        }
        // Explicitly clear and close the output pipe: after exit the pipe is at EOF and an uncancelled READ source keeps firing
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logPipe?.fileHandleForReading.closeFile()
        logPipe = nil
    }

    // MARK: - Startup fallback

    /// Clean up wireguard-go processes and tunnel interfaces left from a previous run.
    ///
    /// vacuole always starts the tunnel with `wireguard-go -f utun` (foreground); `-f` is this app's signature argument,
    /// third parties (such as wg-quick) don't pass `-f`, so leftover processes can be matched precisely by this signature and killed.
    /// When the process exits its utun interface is removed by the kernel, avoiding the stale state where the app
    /// has not started a tunnel but the utun still exists and target addresses remain reachable.
    func cleanupOrphaned() {
        let result = WireGuardController.runCommandCapture(path: "/usr/bin/pgrep",
                                                           args: ["-f", "wireguard-go -f utun"])
        if case .success(let out) = result {
            for line in out.split(separator: "\n") {
                let pid = line.trimmingCharacters(in: .whitespaces)
                guard let n = Int32(pid) else { continue }
                kill(n, SIGKILL)
                LogStore.shared.warn("wg", "Startup fallback: killing leftover wireguard-go process pid=\(pid)")
            }
        }
        try? FileManager.default.removeItem(atPath: "/var/run/wireguard/vacuole.name")
    }

    // MARK: - Utilities

    private static func findBinary(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        if case .success(let out) = runCommandCapture(path: "/usr/bin/which", args: [name]) {
            let p = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty && FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        return nil
    }

    private static func stripWgQuickDirectives(_ text: String) -> String {
        let strippedKeys: Set<String> = [
            "address", "dns", "mtu", "table", "preup", "predown", "postup", "postdown",
            "saveconfig"
        ]
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") {
                lines.append(line)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                lines.append(line)
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if strippedKeys.contains(key) { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shell helpers

    private func runCommand(path: String, args: [String]) -> Result<Void, CmdError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? ""
                return .failure(CmdError("\(path) \(args.joined(separator: " ")) exit=\(proc.terminationStatus) \(errMsg)"))
            }
            return .success(())
        } catch {
            return .failure(CmdError("\(path) \(error.localizedDescription)"))
        }
    }

    private static func runCommandCapture(path: String, args: [String]) -> Result<String, CmdError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if proc.terminationStatus != 0 {
                return .failure(CmdError("\(path) exit=\(proc.terminationStatus)"))
            }
            return .success(output)
        } catch {
            return .failure(CmdError("\(path) \(error.localizedDescription)"))
        }
    }
}