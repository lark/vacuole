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

/// Flushes the macOS DNS resolver cache. Runs inside the root daemon, as the flush commands
/// require root.
///
/// The right command depends on the macOS version:
/// - 10.4–10.6 (Tiger … Snow Leopard): `dscacheutil -flushcache`
/// - 10.7–10.9 (Lion … Mavericks): `killall -HUP mDNSResponder`
/// - 10.10.0–10.10.3 (Yosemite): `discoveryutil mdnsflushcache` + `udnsflushcaches`
/// - 10.10.4+ (Yosemite update) and 10.11+ (El Capitan and later): `dscacheutil -flushcache`
///   followed by `killall -HUP mDNSResponder`
///
/// vacuole supports macOS 13+, so only the last case runs in practice; the older branches are kept
/// so the table stays correct.
enum DNSCacheFlusher {

    private struct Step {
        let path: String
        let args: [String]
    }

    /// Flush the resolver cache for the running macOS version.
    /// Returns nil on success, or the message of the first failing step.
    @discardableResult
    static func flush() -> String? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var failure: String?
        for step in steps(for: version) {
            if let error = run(step) {
                failure = error
                break
            }
        }
        if let failure {
            LogStore.shared.error("dns", "Resolver cache flush failed: \(failure)")
            return failure
        }
        LogStore.shared.info("dns", "Resolver cache flushed (\(version.majorVersion).\(version.minorVersion).\(version.patchVersion))")
        return nil
    }

    /// Flush commands for a given macOS version.
    private static func steps(for version: OperatingSystemVersion) -> [Step] {
        // 10.0–10.6: only the directory-service cache exists
        if version.majorVersion == 10, version.minorVersion < 7 {
            return [flushDirectoryCache]
        }
        // 10.7–10.9: mDNSResponder owns the resolver cache
        if version.majorVersion == 10, version.minorVersion < 10 {
            return [hupResponder]
        }
        // 10.10.0–10.10.3: briefly replaced by discoveryutil
        if version.majorVersion == 10, version.minorVersion == 10, version.patchVersion < 4 {
            return [Step(path: "/usr/bin/discoveryutil", args: ["mdnsflushcache"]),
                    Step(path: "/usr/bin/discoveryutil", args: ["udnsflushcaches"])]
        }
        // 10.10.4+ and 10.11+ (every version vacuole supports)
        return [flushDirectoryCache, hupResponder]
    }

    private static let flushDirectoryCache = Step(path: "/usr/bin/dscacheutil", args: ["-flushcache"])
    private static let hupResponder = Step(path: "/usr/bin/killall", args: ["-HUP", "mDNSResponder"])

    /// Run one step; returns nil on success, otherwise the command output
    private static func run(_ step: Step) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: step.path)
        proc.arguments = step.args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                return "\(step.path) \(step.args.joined(separator: " ")) exit=\(proc.terminationStatus) \(output)"
            }
            return nil
        } catch {
            return "\(step.path) \(error.localizedDescription)"
        }
    }
}