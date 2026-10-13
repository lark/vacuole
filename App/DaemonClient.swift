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

/// XPC client used by the GUI side to communicate with the root daemon
@MainActor
final class DaemonClient: ObservableObject {
    static let shared = DaemonClient()

    @Published private(set) var connected = false
    @Published private(set) var daemonVersion: String?
    @Published private(set) var lastError: String?

    // P1: tunnel state and config list
    @Published private(set) var tunnelState: TunnelState = .stopped
    @Published private(set) var activeConfigName: String?
    @Published var configs: [ConfigListItem] = []

    // P2: split-routing routes (DNS-hit aggregated prefixes + static CIDRs)
    @Published private(set) var resolvedRoutes: [ResolvedRouteInfo] = []
    @Published private(set) var staticRoutes: [String] = []
    @Published private(set) var routingActive = false
    @Published private(set) var routeTTL: Double = 600

    private let ttlKey = "vacuole.routeTTL"
    private let autoStartDNSKey = "vacuole.autoStartDNS"

    /// Whether to auto-start the DNS proxy when starting the tunnel (on by default)
    @Published var autoStartDNS: Bool =
        UserDefaults.standard.object(forKey: "vacuole.autoStartDNS") as? Bool ?? true

    // P3: DNS subsystem
    @Published private(set) var dnsRunning = false
    @Published private(set) var dnsActivated = false
    @Published private(set) var capturedDNS: [String] = []
    /// Upstream source: "tunnel" (DNS from the active WG config) or "custom"
    @Published private(set) var upstreamMode: String = "tunnel"
    /// User-defined upstream list (used when `upstreamMode == "custom"`)
    @Published private(set) var customUpstream: [String] = []
    /// DNS declared by the active WG config (used when `upstreamMode == "tunnel"`)
    @Published private(set) var tunnelProvidedDNS: [String] = []
    /// The upstream actually in effect
    @Published private(set) var effectiveUpstream: [String] = []

    // P4: domain sets
    @Published private(set) var domainSets: [DomainSet] = []
    @Published private(set) var activeSetID: UUID?

    // P5: logs
    @Published private(set) var logs: [LogEntry] = []

    private var connection: NSXPCConnection?
    private var pollTimer: Timer?

    struct ConfigListItem: Codable, Identifiable, Hashable {
        let name: String
        let rawConfig: String
        var id: String { name }
    }

    func connect() {
        invalidate()

        let conn = NSXPCConnection(machServiceName: VacuoleDaemonConstants.machServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: VacuoleDaemonProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connected = false }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connected = false }
        }
        conn.resume()
        connection = conn

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }) as? VacuoleDaemonProtocol else {
            lastError = L("ui.error.xpcProxy")
            return
        }

        proxy.daemonVersion { [weak self] version in
            Task { @MainActor in
                self?.daemonVersion = version
                self?.connected = true
                self?.lastError = nil
                self?.refreshStatus()
                self?.refreshConfigs()
                self?.refreshDNSStatus()
                self?.refreshDomainSets()
                self?.syncRouteTTL()
                self?.startPolling()
            }
        }
    }

    /// Periodically poll daemon status (every 2s)
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.connected else { return }
                self.refreshStatus()
                self.refreshDNSStatus()
            }
        }
        pollTimer = timer
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
        connected = false
    }

    func reportError(_ msg: String) {
        lastError = msg
    }

    /// Flush the system DNS resolver cache. The daemon does the work because the flush commands
    /// need root; the CLI used depends on the running macOS version.
    func flushDNSCache(completion: ((Bool) -> Void)? = nil) {
        proxy()?.flushDNSCache { [weak self] ok, err in
            Task { @MainActor in
                if !ok { self?.reportError(err ?? L("ui.error.flushDNSFailed")) }
                completion?(ok)
            }
        }
    }

    private func proxy() -> VacuoleDaemonProtocol? {
        connection?.remoteObjectProxy as? VacuoleDaemonProtocol
    }

    // MARK: - Status and config sync

    func refreshStatus() {
        proxy()?.fetchStatus { [weak self] data, _ in
            guard let data, let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                // Only publish when the value truly changes, to avoid the 2s poll triggering
                // pointless menu bar / UI rebuilds with identical values
                if self.tunnelState != status.tunnelState { self.tunnelState = status.tunnelState }
                if self.activeConfigName != status.activeConfigName { self.activeConfigName = status.activeConfigName }
            }
        }
    }

    func refreshConfigs() {
        proxy()?.listConfigs { [weak self] data, err in
            guard let data,
                  let items = try? JSONDecoder().decode([ConfigListItem].self, from: data) else {
                // Surface the failure instead of silently keeping an empty list, which used to look
                // like "all configs disappeared" after a daemon-side read failure.
                Task { @MainActor in
                    if let err { self?.lastError = err }
                }
                return
            }
            Task { @MainActor in
                self?.configs = items
            }
        }
    }

    // MARK: - Config management

    func importConfig(name: String, rawConfig: String) {
        proxy()?.importConfig(name, rawConfig: rawConfig) { [weak self] ok, err in
            Task { @MainActor in
                if ok {
                    self?.refreshConfigs()
                    self?.refreshStatus()
                } else {
                    self?.lastError = err ?? L("ui.error.importFailed")
                }
            }
        }
    }

    func deleteConfig(name: String) {
        proxy()?.deleteConfig(name) { [weak self] ok, err in
            Task { @MainActor in
                if ok {
                    self?.refreshConfigs()
                } else {
                    self?.lastError = err ?? L("ui.error.deleteFailed")
                }
            }
        }
    }

    /// Rename a config. The daemon owns the files, so on success both the config list and the status
    /// are refreshed, which also updates the menu bar (it is rebuilt from `configs` / `activeConfigName`).
    func renameConfig(from oldName: String, to newName: String, completion: ((Bool) -> Void)? = nil) {
        proxy()?.renameConfig(oldName, to: newName) { [weak self] ok, err in
            Task { @MainActor in
                if ok {
                    self?.refreshConfigs()
                    self?.refreshStatus()
                } else {
                    self?.lastError = err ?? L("ui.error.renameFailed")
                }
                completion?(ok)
            }
        }
    }

    // MARK: - Tunnel control

    func startTunnel(configName: String) {
        tunnelState = .starting
        proxy()?.startTunnel(configName) { [weak self] ok, err in
            Task { @MainActor in
                guard let self else { return }
                if !ok {
                    self.tunnelState = .error
                    self.lastError = err ?? L("ui.error.startFailed")
                } else {
                    self.tunnelState = .running
                    self.activeConfigName = configName
                    // Auto-start the DNS proxy per settings after the tunnel starts (when not already running)
                    if self.autoStartDNS && !self.dnsRunning {
                        self.startDNS()
                    }
                }
            }
        }
    }

    func stopTunnel() {
        tunnelState = .stopping
        proxy()?.stopTunnel { [weak self] ok, err in
            Task { @MainActor in
                if ok {
                    self?.tunnelState = .stopped
                    self?.activeConfigName = nil
                    self?.refreshRoutes()
                    // Stopping the tunnel now also releases the DNS takeover; refresh so the UI no longer shows stale captured DNS
                    self?.refreshDNSStatus()
                } else {
                    self?.tunnelState = .error
                    self?.lastError = err ?? L("ui.error.stopFailed")
                }
            }
        }
    }

    // MARK: - P2: split-routing route management

    func refreshRoutes() {
        proxy()?.listResolvedRoutes { [weak self] data, _ in
            guard let data, let routes = try? JSONDecoder().decode([ResolvedRouteInfo].self, from: data) else { return }
            Task { @MainActor in self?.resolvedRoutes = routes }
        }
        proxy()?.listStaticRoutes { [weak self] data, _ in
            guard let data, let cidrs = try? JSONDecoder().decode([String].self, from: data) else { return }
            Task { @MainActor in self?.staticRoutes = cidrs }
        }
        proxy()?.routingActive { [weak self] active in
            Task { @MainActor in self?.routingActive = active }
        }
    }

    func addStaticRoute(_ cidr: String) {
        proxy()?.addStaticRoute(cidr) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshRoutes() }
                else { self?.lastError = err ?? L("ui.error.addFailed") }
            }
        }
    }

    func removeStaticRoute(_ cidr: String) {
        proxy()?.removeStaticRoute(cidr) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshRoutes() }
                else { self?.lastError = err ?? L("ui.error.deleteFailed") }
            }
        }
    }

    /// Set the route expiry time (seconds). Persisted locally and pushed back to the daemon after connecting.
    func setRouteTTL(_ seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: ttlKey)
        proxy()?.setRouteTTL(seconds) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshRouteTTL() }
                else { self?.lastError = err ?? L("ui.error.setTTLFailed") }
            }
        }
    }

    func refreshRouteTTL() {
        proxy()?.getRouteTTL { [weak self] ttl in
            Task { @MainActor in self?.routeTTL = ttl }
        }
    }

    /// Push the locally saved TTL preference to the daemon after connecting, and refresh the displayed value.
    private func syncRouteTTL() {
        let saved = UserDefaults.standard.double(forKey: ttlKey)
        let value = saved > 0 ? saved : 600
        routeTTL = value
        proxy()?.setRouteTTL(value) { _, _ in }
        refreshRouteTTL()
    }

    // MARK: - P3: DNS control

    func startDNS() {
        proxy()?.startDNS { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshDNSStatus() }
                else { self?.lastError = err ?? L("ui.error.dnsStartFailed") }
            }
        }
    }

    func stopDNS() {
        proxy()?.stopDNS { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshDNSStatus() }
                else { self?.lastError = err ?? L("ui.error.dnsStopFailed") }
            }
        }
    }

    func refreshDNSStatus() {
        proxy()?.dnsStatus { [weak self] data, _ in
            guard let data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Task { @MainActor in
                guard let self else { return }
                // Only publish when the value truly changes: @Published fires unconditionally even
                // for value-type arrays, so assigning the same value on the 2s poll would rebuild
                // the menu bar scene pointlessly.
                let running = dict["running"] as? Bool ?? false
                let activated = dict["activated"] as? Bool ?? false
                let captured = dict["capturedDNS"] as? [String] ?? []
                let mode = dict["upstreamMode"] as? String ?? "tunnel"
                let custom = dict["customUpstream"] as? [String] ?? []
                let tunnelProvided = dict["tunnelProvided"] as? [String] ?? []
                let effective = dict["effectiveUpstream"] as? [String] ?? []
                if self.dnsRunning != running { self.dnsRunning = running }
                if self.dnsActivated != activated { self.dnsActivated = activated }
                if self.capturedDNS != captured { self.capturedDNS = captured }
                if self.upstreamMode != mode { self.upstreamMode = mode }
                if self.customUpstream != custom { self.customUpstream = custom }
                if self.tunnelProvidedDNS != tunnelProvided { self.tunnelProvidedDNS = tunnelProvided }
                if self.effectiveUpstream != effective { self.effectiveUpstream = effective }
            }
        }
    }

    func updateManagedDomains(_ domains: [String]) {
        let joined = domains.joined(separator: "\n")
        proxy()?.updateManagedDomains(joined) { _, _ in }
    }

    /// Set the custom upstream DNS list (used when the mode is "custom"). Persisted by the daemon as the single source of truth.
    func setUpstreamDNS(_ servers: [String]) {
        let joined = servers.joined(separator: "\n")
        proxy()?.setUpstreamDNS(joined) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshDNSStatus() }
                else { self?.lastError = err ?? L("ui.error.setUpstreamFailed") }
            }
        }
    }

    /// Choose where the upstream DNS comes from: "tunnel" (from the active WG config) or "custom".
    func setUpstreamMode(_ mode: String) {
        proxy()?.setUpstreamMode(mode) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshDNSStatus() }
                else { self?.lastError = err ?? L("ui.error.setUpstreamFailed") }
            }
        }
    }

    /// Synchronously stop DNS (blocks up to timeout seconds). Used before app exit to ensure the system DNS is restored;
    /// otherwise the process exits before the async XPC returns, possibly leaving 127.0.0.1 behind and causing network loss.
    func stopDNSSync(timeout: TimeInterval = 3) {
        guard let proxy = proxy() else { return }
        let sem = DispatchSemaphore(value: 0)
        proxy.stopDNS { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }

    /// Synchronously stop the tunnel (blocks up to timeout seconds). Used on app exit: the daemon
    /// outlives the GUI, so without this the kernel routes, the utun interface and wireguard-go would
    /// stay behind with nobody left to stop them.
    func stopTunnelSync(timeout: TimeInterval = 8) {
        guard let proxy = proxy() else { return }
        let sem = DispatchSemaphore(value: 0)
        proxy.stopTunnel { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        tunnelState = .stopped
        activeConfigName = nil
    }

    /// Set "auto-start DNS proxy when starting the tunnel" and persist it.
    func setAutoStartDNS(_ enabled: Bool) {
        autoStartDNS = enabled
        UserDefaults.standard.set(enabled, forKey: autoStartDNSKey)
    }

    // MARK: - P4: domain set management

    func refreshDomainSets() {
        proxy()?.listDomainSets { [weak self] data, _ in
            guard let data,
                  let envelope = try? JSONDecoder().decode(DomainSetListEnvelope.self, from: data) else { return }
            Task { @MainActor in
                self?.domainSets = envelope.sets
                self?.activeSetID = envelope.activeSetID
            }
        }
    }

    func saveDomainSet(_ set: DomainSet) {
        guard let data = try? JSONEncoder().encode(set) else {
            lastError = L("ui.error.encodeDomainSet")
            return
        }
        proxy()?.saveDomainSet(data) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshDomainSets() }
                else { self?.lastError = err ?? L("ui.error.saveFailed") }
            }
        }
    }

    func deleteDomainSet(id: UUID) {
        proxy()?.deleteDomainSet(id.uuidString) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshDomainSets() }
                else { self?.lastError = err ?? L("ui.error.deleteFailed") }
            }
        }
    }

    func activateDomainSet(id: UUID) {
        proxy()?.activateDomainSet(id.uuidString) { [weak self] ok, err in
            Task { @MainActor in
                if ok { self?.refreshDomainSets() }
                else { self?.lastError = err ?? L("ui.error.activateFailed") }
            }
        }
    }

    // MARK: - P5: logs

    func refreshLogs(limit: Int = 300) {
        proxy()?.fetchLogs(limit) { [weak self] data, _ in
            guard let data,
                  let entries = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
            Task { @MainActor in
                self?.logs = entries
            }
        }
    }
}