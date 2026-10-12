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

/// Daemon service implementation: delegates XPC calls to the various controllers.
final class DaemonService: NSObject, VacuoleDaemonProtocol {

    private let startedAt = Date()
    private let wg = WireGuardController.shared
    private let route = RouteController.shared
    private let dns = DNSProxyServer.shared
    private let sysDNS = SystemDNSManager.shared
    private let domainSets = DomainSetManager.shared

    /// Collect protected addresses to exclude from the tunnel (WG endpoint + physical DNS servers)
    private func protectedIPs() -> [String] {
        var list: [String] = []
        if let ep = wg.endpointAddress { list.append(ep) }
        list.append(contentsOf: sysDNS.capturedDNS)
        list.append(contentsOf: dns.physicalUpstreamDNS)
        return Array(Set(list))
    }

    // ── P0: connectivity ──

    func echo(_ message: String, withReply reply: @escaping (String) -> Void) {
        reply("echo: \(message)")
    }

    func daemonVersion(withReply reply: @escaping (String) -> Void) {
        let uptime = Int(Date().timeIntervalSince(startedAt))
        reply("vacuoled 0.1.0 (P2, uptime \(uptime)s)")
    }

    func fetchStatus(withReply reply: @escaping (Data?, String?) -> Void) {
        let status = DaemonStatus(
            tunnelState: wg.tunnelState,
            activeConfigName: wg.activeConfigName,
            capturedUpstreamDNS: []
        )
        do {
            reply(try JSONEncoder().encode(status), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    // ── P1: config management ──

    func importConfig(_ name: String, rawConfig: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let result = wg.importConfig(name: name, rawConfig: rawConfig)
        reply(result.0, result.1)
    }

    func deleteConfig(_ name: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let result = wg.deleteConfig(name: name)
        reply(result.0, result.1)
    }

    func renameConfig(_ oldName: String, to newName: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let result = wg.renameConfig(from: oldName, to: newName)
        reply(result.0, result.1)
    }

    func listConfigs(withReply reply: @escaping (Data?, String?) -> Void) {
        let result = wg.listConfigs()
        reply(result.0, result.1)
    }

    // ── P1: tunnel control ──

    func startTunnel(_ configName: String, withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.wg.startTunnel(configName: configName)
            // After the tunnel starts, bind the route controller with "WG endpoint + physical DNS" as protected addresses
            if result.0, let ifname = self.wg.interfaceName {
                self.route.start(interface: ifname, protectedIPs: self.protectedIPs())
                // Feed the tunnel-provided DNS (from the config) into the DNS proxy and re-route its upstreams
                self.dns.tunnelInterface = ifname
                self.dns.tunnelProvidedDNS = self.wg.activeConfigDNSServers
                self.dns.refreshUpstreamRouting()
                // Re-apply the static routes of the currently active domain set
                self.domainSets.reapplyActiveRoutes()
            }
            reply(result.0, result.1)
        }
    }

    func stopTunnel(withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // First reclaim all routes installed by this controller
            self.route.stop()
            let result = self.wg.stopTunnel()
            // The tunnel is gone: drop the tunnel-provided DNS so the upstream falls back to the default list
            self.dns.tunnelProvidedDNS = []
            self.dns.tunnelInterface = nil
            reply(result.0, result.1)
        }
    }

    // ── P2: kernel route policy split ──

    func listResolvedRoutes(withReply reply: @escaping (Data?, String?) -> Void) {
        let routes = route.listResolvedRoutes()
        reply(try? JSONEncoder().encode(routes), nil)
    }

    func addStaticRoute(_ cidr: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let result = route.addStatic(cidr)
        reply(result.0, result.1)
    }

    func removeStaticRoute(_ cidr: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let result = route.removeStatic(cidr)
        reply(result.0, result.1)
    }

    func listStaticRoutes(withReply reply: @escaping (Data?, String?) -> Void) {
        let routes = route.listStaticRoutes()
        reply(try? JSONEncoder().encode(routes), nil)
    }

    func routingActive(withReply reply: @escaping (Bool) -> Void) {
        reply(route.routingActive)
    }

    func setRouteTTL(_ seconds: Double, withReply reply: @escaping (Bool, String?) -> Void) {
        route.setRouteTTL(seconds)
        reply(true, nil)
    }

    func getRouteTTL(withReply reply: @escaping (Double) -> Void) {
        reply(route.currentRouteTTL)
    }

    // ── P3: DNS subsystem ──

    func startDNS(withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Capture physical DNS
            let captured = self.sysDNS.capture()
            guard !captured.isEmpty else {
                reply(false, L("daemon.dns.physicalNotFound"))
                return
            }

            // 2. Start the DNS proxy listener
            self.dns.physicalUpstreamDNS = captured
            self.dns.tunnelInterface = self.wg.interfaceName
            self.dns.tunnelProvidedDNS = self.wg.activeConfigDNSServers
            self.dns.start(port: 53)

            // Add physical DNS servers to protected addresses so aggregated prefixes don't swallow them into the tunnel
            self.route.setProtectedIPs(self.protectedIPs())

            // 3. Point system DNS at 127.0.0.1
            let activateResult = self.sysDNS.activate()
            if !activateResult.0 {
                self.dns.stop()
                reply(false, L("daemon.dns.takeoverFailed", activateResult.1 ?? ""))
                return
            }

            reply(true, nil)
        }
    }

    func stopDNS(withReply reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Restore system DNS
            _ = self.sysDNS.restore()
            // 2. Stop the DNS proxy listener
            self.dns.stop()
            reply(true, nil)
        }
    }

    func dnsStatus(withReply reply: @escaping (Data?, String?) -> Void) {
        let status: [String: Any] = [
            "running": dns.running,
            "activated": sysDNS.activated,
            "capturedDNS": sysDNS.capturedDNS,
            "upstreamMode": dns.upstreamMode.rawValue,
            "customUpstream": dns.customUpstreamDNS,
            "tunnelProvided": dns.tunnelProvidedDNS,
            "effectiveUpstream": dns.effectiveUpstreamDNS,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            reply(data, nil)
        } else {
            reply(nil, L("daemon.dns.serializeFailed"))
        }
    }

    func updateManagedDomains(_ domains: String, withReply reply: @escaping (Bool, String?) -> Void) {
        // domains is a newline-separated list of domains
        let list = domains.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        dns.updateManagedDomains(list)
        reply(true, nil)
    }

    func setUpstreamDNS(_ servers: String, withReply reply: @escaping (Bool, String?) -> Void) {
        // servers is a newline-separated list of DNS server addresses
        let list = servers.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !list.isEmpty else {
            reply(false, L("daemon.dns.needUpstream"))
            return
        }
        dns.setUpstreams(list)
        reply(true, nil)
    }

    func setUpstreamMode(_ mode: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let parsed = DNSProxyServer.UpstreamMode(rawValue: mode) else {
            reply(false, L("daemon.dns.invalidUpstreamMode"))
            return
        }
        dns.setMode(parsed)
        reply(true, nil)
    }

    // ── P4: domain set management ──

    func listDomainSets(withReply reply: @escaping (Data?, String?) -> Void) {
        let envelope = DomainSetListEnvelope(sets: domainSets.sets, activeSetID: domainSets.activeSetID)
        do {
            reply(try JSONEncoder().encode(envelope), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func saveDomainSet(_ json: Data, withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            let set = try JSONDecoder().decode(DomainSet.self, from: json)
            let result = domainSets.upsertSet(set)
            reply(result.0, result.1)
        } catch {
            reply(false, L("daemon.domainSet.parseFailed", error.localizedDescription))
        }
    }

    func deleteDomainSet(_ id: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: id) else {
            reply(false, L("daemon.domainSet.invalidId"))
            return
        }
        let result = domainSets.deleteSet(id: uuid)
        reply(result.0, result.1)
    }

    func activateDomainSet(_ id: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: id) else {
            reply(false, L("daemon.domainSet.invalidId"))
            return
        }
        let result = domainSets.activate(id: uuid)
        reply(result.0, result.1)
    }

    // ── P5: logs ──

    func fetchLogs(_ limit: Int, withReply reply: @escaping (Data?, String?) -> Void) {
        guard let data = LogStore.shared.encoded(limit: min(max(limit, 1), 1000)) else {
            reply(nil, L("daemon.log.encodeFailed"))
            return
        }
        reply(data, nil)
    }
}