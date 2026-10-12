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

public enum VacuoleDaemonConstants {
    /// XPC mach service name of the root daemon (matches MachServices in the LaunchDaemon plist).
    public static let machServiceName = "com.vacuole.daemon"
    /// Name of the LaunchDaemon plist shipped with the app.
    public static let plistName = "com.vacuole.daemon.plist"
    /// App bundle id.
    public static let appBundleIdentifier = "com.vacuole.app"
    /// Daemon data directory.
    public static let dataDir = "/var/db/vacuole"
    /// Config files subdirectory.
    public static let configsDir = "/var/db/vacuole/configs"
}

/// XPC interface between the GUI and the root daemon.
@objc public protocol VacuoleDaemonProtocol {
    // ── P0: connectivity ──
    func echo(_ message: String, withReply reply: @escaping (String) -> Void)
    func daemonVersion(withReply reply: @escaping (String) -> Void)
    func fetchStatus(withReply reply: @escaping (Data?, String?) -> Void)

    // ── P1: WireGuard config management ──
    /// Import/update a WG config (returns success flag + error message).
    func importConfig(_ name: String, rawConfig: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Delete a WG config.
    func deleteConfig(_ name: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// List all saved WG configs (JSON-encoded [WireGuardConfig]).
    func listConfigs(withReply reply: @escaping (Data?, String?) -> Void)

    // ── P1: tunnel control ──
    /// Start the tunnel (using the config with the given name).
    func startTunnel(_ configName: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Stop the tunnel.
    func stopTunnel(withReply reply: @escaping (Bool, String?) -> Void)

    // ── P2: kernel routing policy split ──
    /// List DNS-matched route prefixes (aggregated into /24 and /64).
    func listResolvedRoutes(withReply reply: @escaping (Data?, String?) -> Void)

    /// Add a static CIDR route.
    func addStaticRoute(_ cidr: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Remove a static CIDR route.
    func removeStaticRoute(_ cidr: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// List static CIDR route entries.
    func listStaticRoutes(withReply reply: @escaping (Data?, String?) -> Void)

    /// Query whether split routing is active (tunnel interface bound).
    func routingActive(withReply reply: @escaping (Bool) -> Void)

    /// Set the expiry time for DNS-matched routes (seconds, range 60–43200, max 12 hours).
    func setRouteTTL(_ seconds: Double, withReply reply: @escaping (Bool, String?) -> Void)
    /// Query the current route expiry time (seconds).
    func getRouteTTL(withReply reply: @escaping (Double) -> Void)

    // ── P3: DNS subsystem ──
    /// Start the DNS proxy (capture physical DNS + change system DNS + start listener).
    func startDNS(withReply reply: @escaping (Bool, String?) -> Void)
    /// Stop the DNS proxy (restore system DNS).
    func stopDNS(withReply reply: @escaping (Bool, String?) -> Void)
    /// Query DNS proxy status + list of captured physical DNS servers.
    func dnsStatus(withReply reply: @escaping (Data?, String?) -> Void)
    /// Update the managed domain set.
    func updateManagedDomains(_ domains: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Set the custom upstream DNS list (newline-separated; used when the upstream mode is "custom").
    func setUpstreamDNS(_ servers: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Set where the upstream DNS comes from: "tunnel" (DNS declared by the active WG config) or "custom".
    func setUpstreamMode(_ mode: String, withReply reply: @escaping (Bool, String?) -> Void)

    // ── P4: domain set management ──
    /// List all domain sets + the currently active ID (JSON: DomainSetListEnvelope).
    func listDomainSets(withReply reply: @escaping (Data?, String?) -> Void)
    /// Save (create or update) a domain set (JSON: DomainSet).
    func saveDomainSet(_ json: Data, withReply reply: @escaping (Bool, String?) -> Void)
    /// Delete a domain set.
    func deleteDomainSet(_ id: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Activate a domain set.
    func activateDomainSet(_ id: String, withReply reply: @escaping (Bool, String?) -> Void)

    // ── P5: logs ──
    /// Fetch the most recent logs (JSON: [LogEntry]).
    func fetchLogs(_ limit: Int, withReply reply: @escaping (Data?, String?) -> Void)
}