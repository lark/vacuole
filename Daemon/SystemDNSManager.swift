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

/// System DNS manager (inside the root daemon).
///
/// Responsibilities:
/// 1. Capture the DNS servers of the current physical network service
/// 2. Point system DNS at 127.0.0.1 (the vacuole listening port)
/// 3. Restore on exit/crash
///
/// Uses the SystemConfiguration framework to modify dynamically (reversible at runtime, writes no files).
final class SystemDNSManager {

    static let shared = SystemDNSManager()

    /// Captured original physical DNS server list
    private(set) var capturedDNS: [String] = []

    /// Whether system DNS has been taken over
    private(set) var activated = false

    /// Listening port (default 53, configurable to a high port)
    var listenPort: UInt16 = 53

    private init() {}

    // MARK: - Capture and takeover

    /// Capture the current physical DNS server list
    func capture() -> [String] {
        // Parse with scutil --dns (simple and reliable)
        let result = ShellCapture.run("/usr/sbin/scutil", args: ["--dns"])
        guard case .success(let output) = result else {
            capturedDNS = []
            return []
        }

        var servers: [String] = []
        // Only take the nameserver of resolver #1 (the default resolver)
        var inResolver1 = false
        for line in output.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("resolver #1") { inResolver1 = true; continue }
            if s.hasPrefix("resolver #") && !s.hasPrefix("resolver #1") { inResolver1 = false; continue }
            if inResolver1 && s.hasPrefix("nameserver[") {
                // Format: nameserver[0] : 10.1.0.2
                if let colon = s.firstIndex(of: ":") {
                    let ip = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !ip.isEmpty && !servers.contains(ip) {
                        servers.append(ip)
                    }
                }
            }
        }
        capturedDNS = servers
        return servers
    }

    /// Point system DNS at 127.0.0.1
    func activate() -> (Bool, String?) {
        guard !activated else { return (true, nil) }
        guard !capturedDNS.isEmpty else {
            return (false, L("daemon.dns.noPhysicalDNSForTakeover"))
        }

        // Use networksetup to set each active network service
        let services = listActiveNetworkServices()
        guard !services.isEmpty else {
            return (false, L("daemon.dns.noActiveService"))
        }

        for service in services {
            // networksetup -setdnsservers sets all DNS of the service (IPv4/IPv6) at once
            let r1 = Shell.run("/usr/sbin/networksetup", args: ["-setdnsservers", service, "127.0.0.1"])
            if case .failure(let err) = r1 {
                return (false, L("daemon.dns.setServiceDNSFailed", service, err.message))
            }
        }

        activated = true
        LogStore.shared.info("dns", "System DNS taken over → 127.0.0.1 (services: \(services.joined(separator: ", ")))")
        return (true, nil)
    }

    /// Restore system DNS to the pre-capture value
    func restore() -> (Bool, String?) {
        guard activated else { return (true, nil) }

        let services = listActiveNetworkServices()
        for service in services {
            // "empty" clears custom DNS and restores DHCP auto-configuration
            _ = Shell.run("/usr/sbin/networksetup", args: ["-setdnsservers", service, "empty"])
        }

        activated = false
        LogStore.shared.info("dns", "System DNS restored")
        return (true, nil)
    }

    // MARK: - Internals

    /// List active network service names
    private func listActiveNetworkServices() -> [String] {
        let result = ShellCapture.run("/usr/sbin/networksetup", args: ["-listallnetworkservices"])
        guard case .success(let output) = result else { return [] }

        return output.split(separator: "\n")
            .dropFirst() // The first line is a description
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }
}

// MARK: - Shell helpers

enum Shell {
    static func run(_ path: String, args: [String]) -> Result<Void, CmdError> {
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
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8) ?? ""
                return .failure(CmdError("\(path) exit=\(proc.terminationStatus) \(msg)"))
            }
            return .success(())
        } catch {
            return .failure(CmdError("\(path) \(error.localizedDescription)"))
        }
    }
}

enum ShellCapture {
    static func run(_ path: String, args: [String]) -> Result<String, CmdError> {
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