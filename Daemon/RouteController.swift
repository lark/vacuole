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

/// Kernel route controller (inside the root daemon).
///
/// Owns all policy routing: directs targets that "match a domain set / static list" to the WireGuard
/// utun interface. Uses **kernel routing table entries** (`route add -net <prefix> -interface utunN`),
/// so the kernel automatically chooses the tunnel source address during route lookup — hence **no nat**
/// and TCP/UDP stay clean (unlike the pf route-to approach where the kernel swallows the first packet of each new UDP flow).
///
/// Two containment measures (to reduce route count):
/// 1. **Prefix aggregation**: a single DNS-resolved IP is folded into an IPv4 /24 or IPv6 /64 network route;
/// 2. **Expiry reclamation**: a TTL is tracked per dest; if not refreshed within `routeTTL` after being
///    added or hit (refreshed), it is removed, avoiding long-term accumulation of useless prefixes.
///
/// Safety guardrails:
/// - Protected addresses (WG endpoint, physical DNS) never enter the tunnel; if an aggregated prefix would
///   contain them, it degrades to a /32 (or /128) host route for that target itself.
/// - If an aggregated prefix overlaps a directly connected local subnet (en*), skip it to avoid hijacking the LAN/gateway.
///
/// Startup fallback: routes left from the previous run (persisted in `routes.json`) are all deleted at startup,
/// preventing dangling routes pointing at a vanished utun from breaking connectivity after an abnormal daemon exit.
final class RouteController {

    static let shared = RouteController()

    // MARK: - Tunables

    /// IPv4 aggregation prefix length
    var ipv4PrefixLength = 24
    /// IPv6 aggregation prefix length (/64 or /56)
    var ipv6PrefixLength = 64
    /// Route lifetime (seconds): removed if not hit again within this time after being added/refreshed
    var routeTTL: TimeInterval = 600

    // MARK: - Internal state

    private let queue = DispatchQueue(label: "com.vacuole.route")
    private(set) var interfaceName: String?

    /// Protected addresses: never enter the tunnel (WG endpoint, physical DNS)
    private var protectedIPs: Set<String> = []
    /// Locally connected subnets (to avoid hijacking the LAN)
    private var localSubnets: [Subnet] = []

    private struct Subnet {
        var bytes: [UInt8]
        var plen: Int
        var v6: Bool
    }

    private struct Entry {
        var v6: Bool
        var expires: Date?     // nil = permanent (static / upstream)
        var source: String     // "dns" / "static" / "upstream"
        /// Domains that pulled this route in (key: domain, value: time it was first added)
        var origins: [String: Date] = [:]
    }
    private var entries: [String: Entry] = [:]   // key: dest CIDR, e.g. "10.0.0.0/24"

    private var timer: DispatchSourceTimer?
    private let storeFile = "\(VacuoleDaemonConstants.dataDir)/routes.json"

    private struct PersistEntry: Codable {
        var dest: String
        var v6: Bool
    }

    private init() {}

    // MARK: - Lifecycle

    /// Tunnel start: bind the interface, set protected addresses, collect directly connected subnets, start the expiry timer
    func start(interface: String, protectedIPs: [String]) {
        queue.sync {
            self.interfaceName = interface
            self.protectedIPs = Set(protectedIPs)
            self.localSubnets = collectLocalSubnets()
            // If the previous run exited abnormally, clean up from the persisted list first to avoid stacking onto this one
            cleanPersistedLocked()
            startTimerLocked()
            LogStore.shared.info("route", "Route controller ready: interface=\(interface) protected=\(protectedIPs.count) localSubnets=\(localSubnets.count)")
        }
    }

    /// Tunnel stop: remove all routes installed by this controller
    func stop() {
        queue.sync {
            removeAllLocked()
            timer?.cancel()
            timer = nil
            interfaceName = nil
            protectedIPs = []
            localSubnets = []
            LogStore.shared.info("route", "Route controller stopped, all routes reclaimed")
        }
    }

    /// Update protected addresses (e.g. after the DNS subsystem captures physical DNS)
    func setProtectedIPs(_ ips: [String]) {
        queue.sync { self.protectedIPs = Set(ips) }
    }

    // MARK: - Route expiry config

    /// Set the expiry for DNS-hit routes (seconds). Clamped to 60–43200 seconds (max 12 hours).
    /// Immediately re-times existing hit routes (source == "dns"), and restarts the timer if running to adopt a new scan interval.
    func setRouteTTL(_ seconds: TimeInterval) {
        let clamped = max(60, min(43200, seconds))
        queue.sync {
            routeTTL = clamped
            let newExpires = Date().addingTimeInterval(clamped)
            for (dest, var e) in entries {
                guard e.source == "dns", e.expires != nil else { continue }
                e.expires = newExpires
                entries[dest] = e
            }
            if timer != nil { startTimerLocked() }
            LogStore.shared.info("route", "Route TTL updated to \(Int(clamped))s")
        }
    }

    /// Current route expiry (seconds)
    var currentRouteTTL: TimeInterval {
        queue.sync { routeTTL }
    }

    /// Startup fallback: clean up routes left from the previous run (independent of start; callable while no tunnel is running)
    func resetStaleState() {
        queue.sync { cleanPersistedLocked() }
    }

    // MARK: - Public operations

    /// A target hit by DNS resolution: aggregate to /24 (or /64), install it, and refresh the TTL.
    /// `origin` is the queried domain, recorded so the UI can show why the route exists.
    @discardableResult
    func addResolved(_ ip: String, origin: String? = nil) -> (Bool, String?) {
        queue.sync {
            guard interfaceName != nil else { return (false, L("daemon.route.tunnelNotRunning")) }
            guard let parsed = parseIP(ip) else { return (false, L("daemon.route.invalidIP", ip)) }
            // Silently skip protected addresses
            if protectedIPs.contains(ip) { return (false, nil) }

            let plen = parsed.v6 ? ipv6PrefixLength : ipv4PrefixLength
            let netBytes = mask(parsed.bytes, plen: plen)

            // LAN protection: skip if the prefix overlaps a directly connected local subnet
            let net = Subnet(bytes: netBytes, plen: plen, v6: parsed.v6)
            if localSubnets.contains(where: { overlaps(net, $0) }) {
                LogStore.shared.info("route", "Skipping prefix overlapping a directly connected subnet (target \(ip))")
                return (false, nil)
            }

            var dest = cidr(netBytes, v6: parsed.v6, plen: plen)
            // If the prefix contains a protected address → degrade to a host route for that target
            if prefixContainsProtected(netBytes: netBytes, plen: plen, v6: parsed.v6) {
                let hostPlen = parsed.v6 ? 128 : 32
                dest = cidr(parsed.bytes, v6: parsed.v6, plen: hostPlen)
            }
            let expires = Date().addingTimeInterval(routeTTL)
            return addRouteLocked(dest: dest, v6: parsed.v6, expires: expires, source: "dns", origin: origin)
        }
    }

    /// Exact host route (tunnel upstream DNS, etc.): /32 or /128, permanent
    @discardableResult
    func addHost(_ ip: String, source: String = "upstream") -> (Bool, String?) {
        queue.sync {
            guard interfaceName != nil else { return (false, L("daemon.route.tunnelNotRunning")) }
            guard let parsed = parseIP(ip) else { return (false, L("daemon.route.invalidIP", ip)) }

            // Never point the physical DNS (protected) or a directly connected LAN address at the tunnel:
            // non-matched lookups are forwarded to the physical DNS, and tunneling it would black-hole them.
            if protectedIPs.contains(ip) {
                LogStore.shared.warn("route", "Upstream DNS \(ip) is a protected address; leaving it outside the tunnel")
                return (false, nil)
            }
            let hostPlen = parsed.v6 ? 128 : 32
            let host = Subnet(bytes: parsed.bytes, plen: hostPlen, v6: parsed.v6)
            if localSubnets.contains(where: { overlaps(host, $0) }) {
                LogStore.shared.warn("route", "Upstream DNS \(ip) is on a directly connected subnet; leaving it outside the tunnel")
                return (false, nil)
            }

            let dest = cidr(parsed.bytes, v6: parsed.v6, plen: hostPlen)
            return addRouteLocked(dest: dest, v6: parsed.v6, expires: nil, source: source)
        }
    }

    /// Remove a host route
    func removeHost(_ ip: String) {
        queue.sync {
            guard let parsed = parseIP(ip) else { return }
            let plen = parsed.v6 ? 128 : 32
            let dest = cidr(parsed.bytes, v6: parsed.v6, plen: plen)
            if entries[dest] != nil {
                removeRouteLocked(dest: dest, v6: parsed.v6)
                persistLocked()
            }
        }
    }

    /// Static CIDR (user list): installed as-is, permanent
    @discardableResult
    func addStatic(_ cidrString: String) -> (Bool, String?) {
        queue.sync {
            guard interfaceName != nil else { return (false, L("daemon.route.tunnelNotRunning")) }
            guard let (dest, v6) = normalizeCIDR(cidrString) else { return (false, L("daemon.route.invalidCIDR", cidrString)) }
            return addRouteLocked(dest: dest, v6: v6, expires: nil, source: "static")
        }
    }

    /// Replace the entire static route list (called when a domain set is activated/updated)
    @discardableResult
    func replaceStatic(_ cidrList: [String]) -> (Bool, String?) {
        queue.sync {
            // Remove all existing static entries (keep dns / upstream)
            let staleStatic = entries.filter { $0.value.source == "static" }
            for (dest, e) in staleStatic {
                removeRouteLocked(dest: dest, v6: e.v6)
            }
            guard interfaceName != nil else {
                persistLocked()
                return (false, L("daemon.route.tunnelNotRunning"))
            }
            var lastError: String?
            for cidr in cidrList {
                guard let (dest, v6) = normalizeCIDR(cidr) else {
                    lastError = L("daemon.route.invalidCIDR", cidr)
                    continue
                }
                let r = addRouteLocked(dest: dest, v6: v6, expires: nil, source: "static")
                if !r.0 { lastError = r.1 }
            }
            return (lastError == nil, lastError)
        }
    }

    @discardableResult
    func removeStatic(_ cidrString: String) -> (Bool, String?) {
        queue.sync {
            guard let (dest, v6) = normalizeCIDR(cidrString) else { return (false, L("daemon.route.invalidCIDR", cidrString)) }
            if entries[dest] != nil {
                removeRouteLocked(dest: dest, v6: v6)
            }
            persistLocked()
            return (true, nil)
        }
    }

    // MARK: - Queries

    /// DNS-hit (aggregated) routes with their origin domains and expiry
    func listResolvedRoutes() -> [ResolvedRouteInfo] {
        queue.sync {
            entries.filter { $0.value.source == "dns" }
                .map { dest, entry in
                    ResolvedRouteInfo(dest: dest,
                                      origins: entry.origins
                                          .map { RouteOrigin(domain: $0.key, addedAt: $0.value) }
                                          .sorted { $0.addedAt < $1.addedAt },
                                      expiresAt: entry.expires)
                }
                .sorted { $0.dest < $1.dest }
        }
    }

    /// Static route entries
    func listStaticRoutes() -> [String] {
        queue.sync { entries.filter { $0.value.source == "static" }.keys.sorted() }
    }

    /// Whether split routing is active (tunnel interface bound)
    var routingActive: Bool {
        queue.sync { interfaceName != nil }
    }

    // MARK: - Route install/remove (must be called on the queue)

    private func addRouteLocked(dest: String, v6: Bool, expires: Date?, source: String, origin: String? = nil) -> (Bool, String?) {
        guard let iface = interfaceName else { return (false, L("daemon.route.tunnelNotRunning")) }

        // Already exists: refresh the expiry and remember the extra origin
        if var e = entries[dest] {
            e.expires = expires
            if let origin { recordOrigin(origin, in: &e) }
            entries[dest] = e
            persistLocked()
            return (true, nil)
        }

        var args = ["add"]
        if v6 { args.append("-inet6") }
        args.append(contentsOf: ["-net", dest, "-interface", iface])

        let result = run("/sbin/route", args)
        var failureMessage: String?
        switch result {
        case .success:
            break
        case .failure(let err):
            // Route with the same destination already exists: treat as success
            if !err.message.contains("File exists") { failureMessage = err.message }
        }
        if let msg = failureMessage {
            LogStore.shared.error("route", "Failed to install route \(dest): \(msg)")
            return (false, msg)
        }
        var entry = Entry(v6: v6, expires: expires, source: source)
        if let origin { recordOrigin(origin, in: &entry) }
        entries[dest] = entry
        persistLocked()
        LogStore.shared.info("route", "Installed route \(dest) → \(iface) [\(source)]")
        return (true, nil)
    }

    /// Remember which domain pulled this route in. Only the newest origins are kept, so a busy
    /// /24 reused by many host names cannot grow the entry without bound.
    private func recordOrigin(_ domain: String, in entry: inout Entry) {
        let key = domain.lowercased()
        guard entry.origins[key] == nil else { return }
        if entry.origins.count >= 16, let oldest = entry.origins.min(by: { $0.value < $1.value })?.key {
            entry.origins.removeValue(forKey: oldest)
        }
        entry.origins[key] = Date()
    }

    private func removeRouteLocked(dest: String, v6: Bool) {
        var args = ["delete"]
        if v6 { args.append("-inet6") }
        args.append(contentsOf: ["-net", dest])
        // Ignore delete failures: the route may already have been removed by the kernel when the interface disappeared
        _ = run("/sbin/route", args)
        entries.removeValue(forKey: dest)
    }

    private func removeAllLocked() {
        for (dest, e) in entries {
            var args = ["delete"]
            if e.v6 { args.append("-inet6") }
            args.append(contentsOf: ["-net", dest])
            _ = run("/sbin/route", args)
        }
        entries.removeAll()
        persistLocked()
    }

    // MARK: - Expiry reclamation

    private func startTimerLocked() {
        timer?.cancel()
        let interval = max(5.0, min(30.0, routeTTL / 4))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.reapExpired() }
        t.resume()
        timer = t
    }

    /// Reclaim expired routes (runs on the queue)
    private func reapExpired() {
        let now = Date()
        let expired = entries.filter { $0.value.expires != nil && now > $0.value.expires! }
        for (dest, e) in expired {
            removeRouteLocked(dest: dest, v6: e.v6)
            LogStore.shared.info("route", "Reclaimed expired route \(dest)")
        }
        if !expired.isEmpty { persistLocked() }
    }

    // MARK: - Persistence / startup fallback

    private func persistLocked() {
        let dir = VacuoleDaemonConstants.dataDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let arr = entries.map { PersistEntry(dest: $0.key, v6: $0.value.v6) }
        if let data = try? JSONEncoder().encode(arr) {
            try? data.write(to: URL(fileURLWithPath: storeFile))
        }
    }

    /// Read the persisted list and delete entries one by one (used for startup fallback and pre-start cleanup)
    private func cleanPersistedLocked() {
        defer { try? FileManager.default.removeItem(atPath: storeFile) }
        guard let data = FileManager.default.contents(atPath: storeFile),
              let arr = try? JSONDecoder().decode([PersistEntry].self, from: data),
              !arr.isEmpty else { return }
        for e in arr {
            var args = ["delete"]
            if e.v6 { args.append("-inet6") }
            args.append(contentsOf: ["-net", e.dest])
            _ = run("/sbin/route", args)
        }
        LogStore.shared.info("route", "Startup fallback: cleaned up \(arr.count) stale routes")
    }

    // MARK: - IP / prefix utilities

    private func parseIP(_ ip: String) -> (bytes: [UInt8], v6: Bool)? {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            return (withUnsafeBytes(of: v4) { Array($0) }, false)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            return (withUnsafeBytes(of: v6) { Array($0) }, true)
        }
        return nil
    }

    /// Zero out low bits by prefix length
    private func mask(_ bytes: [UInt8], plen: Int) -> [UInt8] {
        var b = bytes
        guard b.count * 8 >= plen else { return b }
        let full = plen / 8
        let rem = plen % 8
        if rem > 0 {
            let m: UInt8 = 0xFF << (8 - rem)
            if full < b.count { b[full] = b[full] & m }
            for i in (full + 1)..<b.count { b[i] = 0 }
        } else {
            for i in full..<b.count { b[i] = 0 }
        }
        return b
    }

    private func cidr(_ bytes: [UInt8], v6: Bool, plen: Int) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        if v6 {
            var a = in6_addr()
            withUnsafeMutableBytes(of: &a) { dst in
                bytes.withUnsafeBytes { src in dst.copyBytes(from: src) }
            }
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
        } else {
            var a = in_addr()
            withUnsafeMutableBytes(of: &a) { dst in
                bytes.withUnsafeBytes { src in dst.copyBytes(from: src) }
            }
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        }
        return "\(String(cString: buf))/\(plen)"
    }

    /// Normalize CIDR (treated as a host route when there is no slash)
    private func normalizeCIDR(_ s: String) -> (String, Bool)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/")
            guard parts.count == 2,
                  let parsed = parseIP(String(parts[0])),
                  let plen = Int(parts[1]),
                  plen >= 0, plen <= (parsed.v6 ? 128 : 32) else { return nil }
            return (cidr(mask(parsed.bytes, plen: plen), v6: parsed.v6, plen: plen), parsed.v6)
        }
        guard let parsed = parseIP(trimmed) else { return nil }
        let plen = parsed.v6 ? 128 : 32
        return (cidr(parsed.bytes, v6: parsed.v6, plen: plen), parsed.v6)
    }

    /// Whether two prefixes overlap (one contains the other's start address)
    private func overlaps(_ a: Subnet, _ b: Subnet) -> Bool {
        guard a.v6 == b.v6 else { return false }
        let minBits = min(a.plen, b.plen)
        let full = minBits / 8
        let rem = minBits % 8
        for i in 0..<full where a.bytes[i] != b.bytes[i] { return false }
        if rem > 0, full < a.bytes.count, full < b.bytes.count {
            let m: UInt8 = 0xFF << (8 - rem)
            if (a.bytes[full] & m) != (b.bytes[full] & m) { return false }
        }
        return true
    }

    private func prefixContainsProtected(netBytes: [UInt8], plen: Int, v6: Bool) -> Bool {
        for pip in protectedIPs {
            guard let pb = parseIP(pip), pb.v6 == v6 else { continue }
            if mask(pb.bytes, plen: plen) == netBytes { return true }
        }
        return false
    }

    // MARK: - Collect directly connected local subnets

    private func collectLocalSubnets() -> [Subnet] {
        var result: [Subnet] = []
        guard case .success(let out) = run("/sbin/ifconfig", []) else { return result }
        var currentName = ""
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains(": flags=") {
                currentName = String(line.split(separator: ":").first ?? "")
                continue
            }
            // Physical interfaces only (en*)
            guard currentName.hasPrefix("en"), line.hasPrefix("inet ") else { continue }
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 4, parts[0] == "inet", let parsed = parseIP(parts[1]) else { continue }
            var plen = 24
            if let mi = parts.firstIndex(of: "netmask"), mi + 1 < parts.count,
               let mval = parseMask(parts[mi + 1]) {
                plen = v4MaskToPrefix(mval)
            }
            result.append(Subnet(bytes: mask(parsed.bytes, plen: plen), plen: plen, v6: false))
        }
        return result
    }

    /// Parse an IPv4 mask in the "0xffffff00" form
    private func parseMask(_ s: String) -> UInt32? {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return UInt32(s.dropFirst(2), radix: 16)
        }
        // Dotted form
        guard let parsed = parseIP(s), parsed.bytes.count == 4 else { return nil }
        return parsed.bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func v4MaskToPrefix(_ mask: UInt32) -> Int {
        var count = 0
        var m = mask
        while m & 0x8000_0000 != 0 { count += 1; m <<= 1 }
        return count
    }

    // MARK: - Shell helpers

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Result<String, CmdError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // Detach stdin: without an explicit value the child can inherit a bad fd and posix_spawn fails with EBADF
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if proc.terminationStatus != 0 {
                return .failure(CmdError("\(path) \(args.joined(separator: " ")) exit=\(proc.terminationStatus) \(output)"))
            }
            return .success(output)
        } catch {
            return .failure(CmdError("\(path) \(error.localizedDescription)"))
        }
    }
}