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
import Network
import VacuoleShared

/// Built-in DNS proxy server (inside the root daemon).
///
/// Listens on 127.0.0.1:53 (UDP) as the system default resolver.
/// - Queries matching the domain set → resolved upstream through the tunnel → A/AAAA aggregated into network routes → answer returned
/// - Non-matching queries → forwarded directly to the captured physical DNS → answer returned
///
/// Route installation and expiry reclamation are delegated to RouteController (aggregated to /24, /64 and reclaimed by TTL).
/// Naturally loop-free: the physical DNS IP ≠ 127.0.0.1, so upstream queries are not re-intercepted by itself.
final class DNSProxyServer {

    static let shared = DNSProxyServer()

    private var listener: NWListener?
    private(set) var running = false
    private var listenPort: NWEndpoint.Port = 53

    /// Matched domain set (exact + wildcard), injected by DomainSetManager
    var managedDomains: Set<String> = []

    /// Where the upstream DNS used for matched domains comes from.
    enum UpstreamMode: String {
        /// DNS servers declared by the active WireGuard config
        case tunnel
        /// User-defined list
        case custom
    }

    /// Fallback upstream when the tunnel config declares no DNS
    static let defaultUpstreamDNS = ["1.1.1.1", "8.8.8.8"]

    /// Upstream source (persisted at /var/db/vacuole/upstream.json)
    private(set) var upstreamMode: UpstreamMode = .tunnel

    /// User-defined upstream DNS (used when `upstreamMode == .custom`)
    private(set) var customUpstreamDNS: [String] = DNSProxyServer.defaultUpstreamDNS

    /// DNS declared by the active WireGuard config (used when `upstreamMode == .tunnel`)
    var tunnelProvidedDNS: [String] = []

    /// The upstream actually used to resolve matched domains
    var effectiveUpstreamDNS: [String] {
        switch upstreamMode {
        case .tunnel:
            return tunnelProvidedDNS.isEmpty ? DNSProxyServer.defaultUpstreamDNS : tunnelProvidedDNS
        case .custom:
            return customUpstreamDNS
        }
    }

    /// Physical DNS servers (captured by SystemDNSManager)
    var physicalUpstreamDNS: [String] = []

    /// Tunnel interface name
    var tunnelInterface: String?

    /// Upstream IPs that currently have host routes installed (for cleanup on change/stop)
    private var routedUpstreamIPs: [String] = []

    private let upstreamStoreFile = "\(VacuoleDaemonConstants.dataDir)/upstream.json"

    private struct PersistedUpstreams: Codable {
        var mode: String?
        var custom: [String]?
    }

    private init() {
        loadPersistedUpstreams()
    }

    // MARK: - Upstream DNS config

    /// Load the persisted upstream config. Also accepts the legacy bare-array format
    /// (a plain list of servers = custom mode) so existing installs keep working.
    private func loadPersistedUpstreams() {
        guard let data = FileManager.default.contents(atPath: upstreamStoreFile) else { return }
        if let legacy = try? JSONDecoder().decode([String].self, from: data), !legacy.isEmpty {
            customUpstreamDNS = legacy
            upstreamMode = .custom
            return
        }
        guard let store = try? JSONDecoder().decode(PersistedUpstreams.self, from: data) else { return }
        if let mode = store.mode, let parsed = UpstreamMode(rawValue: mode) {
            upstreamMode = parsed
        }
        if let custom = store.custom, !custom.isEmpty {
            customUpstreamDNS = custom
        }
    }

    /// Switch the upstream source (tunnel-provided DNS vs custom list).
    func setMode(_ mode: UpstreamMode) {
        upstreamMode = mode
        persistUpstreams()
        refreshUpstreamRouting()
        LogStore.shared.info("dns", "Upstream DNS mode: \(mode.rawValue)")
    }

    /// Set the custom upstream DNS list. Returns whether it succeeded
    /// (an empty list is rejected and the previous value kept).
    @discardableResult
    func setUpstreams(_ servers: [String]) -> Bool {
        let cleaned = servers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return false }

        customUpstreamDNS = cleaned
        persistUpstreams()
        refreshUpstreamRouting()
        LogStore.shared.info("dns", "Custom upstream DNS updated to: \(cleaned.joined(separator: ", "))")
        return true
    }

    /// Point host routes at the current effective upstream DNS so they forward through the tunnel.
    /// Covers the built-in defaults (1.1.1.1 / 8.8.8.8), the tunnel-provided DNS and the custom list:
    /// servers that are no longer used are removed, and only the routes actually installed are tracked.
    func refreshUpstreamRouting() {
        guard tunnelInterface != nil else { return }
        let wanted = effectiveUpstreamDNS
        for ip in routedUpstreamIPs where !wanted.contains(ip) {
            RouteController.shared.removeHost(ip)
            LogStore.shared.info("dns", "Upstream DNS \(ip) no longer used, route removed")
        }
        var installed: [String] = []
        for ip in wanted {
            let result = RouteController.shared.addHost(ip)
            if result.0 {
                installed.append(ip)
            } else {
                // Refused (protected / local subnet / invalid): make sure no stale route survives
                RouteController.shared.removeHost(ip)
                if let err = result.1 {
                    LogStore.shared.warn("dns", "Could not route upstream DNS \(ip) through the tunnel: \(err)")
                }
            }
        }
        if installed != routedUpstreamIPs {
            LogStore.shared.info("dns", "Upstream DNS routed through the tunnel: \(installed.joined(separator: ", "))")
        }
        routedUpstreamIPs = installed
    }

    private func persistUpstreams() {
        let dir = VacuoleDaemonConstants.dataDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = PersistedUpstreams(mode: upstreamMode.rawValue, custom: customUpstreamDNS)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: URL(fileURLWithPath: upstreamStoreFile))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: upstreamStoreFile)
        }
    }

    // MARK: - Start/stop

    func start(port: UInt16 = 53) {
        guard !running else { return }
        listenPort = NWEndpoint.Port(rawValue: port)!

        do {
            let params = NWParameters.udp
            listener = try NWListener(using: params, on: listenPort)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener?.start(queue: .global(qos: .utility))
            running = true
            // Make matched-domain upstream queries go through the tunnel: exact host routes for the effective upstream DNS
            refreshUpstreamRouting()
        } catch {
            running = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        // Reclaim host routes installed for the upstream DNS
        for ip in routedUpstreamIPs {
            RouteController.shared.removeHost(ip)
        }
        routedUpstreamIPs = []
    }

    // MARK: - Query handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receiveMessage { [weak self] data, _, _, error in
            guard error == nil, let data = data else {
                conn.cancel()
                return
            }

            self?.processQuery(data: data, connection: conn)
        }
    }

    private func processQuery(data: Data, connection: NWConnection) {
        guard let queryName = DNSCodec.parseQuery(data) else {
            // Unparseable, discard
            connection.cancel()
            return
        }

        let normalizedName = queryName.lowercased().trimmingCharacters(in: .whitespaces)
        let isManaged = isDomainManaged(normalizedName)

        if isManaged {
            // Hit → resolve via the effective upstream (tunnel DNS or custom list)
            forwardToUpstream(data: data, servers: effectiveUpstreamDNS, connection: connection,
                              isManaged: true, origin: normalizedName)
        } else {
            // Miss → forward to physical DNS
            let upstream = physicalUpstreamDNS.isEmpty ? ["8.8.8.8"] : physicalUpstreamDNS
            forwardToUpstream(data: data, servers: upstream, connection: connection,
                              isManaged: false, origin: nil)
        }
    }

    // MARK: - Forwarding

    private func forwardToUpstream(data: Data, servers: [String], connection: NWConnection,
                                   isManaged: Bool, origin: String?) {
        guard !servers.isEmpty else {
            connection.cancel()
            return
        }

        let server = servers[0]
        let upstreamHost = NWEndpoint.Host(server)
        let upstreamPort = NWEndpoint.Port(rawValue: 53)!

        let params = NWParameters.udp

        // For matched-domain upstream queries, the host routes installed by RouteController already force them through the tunnel; no interface binding is needed here

        let upstreamConn = NWConnection(host: upstreamHost, port: upstreamPort, using: params)
        upstreamConn.start(queue: .global(qos: .utility))

        upstreamConn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                // Upstream failed: try the next server
                if servers.count > 1 {
                    self?.forwardToUpstream(data: data, servers: Array(servers.dropFirst()),
                                            connection: connection, isManaged: isManaged, origin: origin)
                } else {
                    connection.cancel()
                }
                return
            }

            // Receive the upstream response
            upstreamConn.receiveMessage { [weak self] respData, _, _, recvError in
                guard let respData = respData, recvError == nil else {
                    connection.cancel()
                    return
                }

                // Response for a matched domain: install the aggregated route, recording which domain pulled it in
                if isManaged {
                    self?.injectRecords(from: respData, origin: origin)
                }

                // Send the response back to the client
                connection.send(content: respData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        })
    }

    // MARK: - Domain matching

    /// Whether a domain matches the managed set.
    /// A bare entry ("example.com.") covers the domain itself and every subdomain of it;
    /// a wildcard entry ("*.example.com.") covers subdomains only.
    func isDomainManaged(_ name: String) -> Bool {
        // Ensure name ends with "."
        var n = name
        if !n.hasSuffix(".") { n += "." }

        // Exact match
        if managedDomains.contains(n) { return true }

        // Walk up the parent domains: "www.a.example.com." → "a.example.com.", "example.com.", "com."
        var parts = n.split(separator: ".").map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            let parent = parts.joined(separator: ".") + "."
            if managedDomains.contains(parent) { return true }
            if managedDomains.contains("*." + parent) { return true }
        }

        return false
    }

    // MARK: - Record injection

    /// Extract A/AAAA records from a DNS response and install them as aggregated network routes (TTL maintained by RouteController)
    private func injectRecords(from data: Data, origin: String?) {
        let (_, records) = DNSCodec.parseResponse(data)

        for record in records {
            if !record.name.isEmpty {
                LogStore.shared.info("dns", "Resolved \(record.name) → \(record.ipAddress ?? "?")")
            }
            guard let ip = record.ipAddress else { continue }
            // Aggregate to /24 (or /64) and refresh the TTL
            let _ = RouteController.shared.addResolved(ip, origin: origin ?? (record.name.isEmpty ? nil : record.name))
        }
    }

    // MARK: - Config update

    /// Update the managed domain set
    func updateManagedDomains(_ domains: [String]) {
        var set = Set<String>()
        for d in domains {
            var n = d.lowercased().trimmingCharacters(in: .whitespaces)
            if !n.hasSuffix(".") { n += "." }
            set.insert(n)
        }
        managedDomains = set
    }
}