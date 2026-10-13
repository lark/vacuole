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

/// Client for the WireGuard cross-platform UAPI (`set=1`), spoken over the engine's control socket.
///
/// Needed for amneziawg-go: the stock `wg` tool talks to `/var/run/wireguard` and rejects the
/// AmneziaWG obfuscation keys, while amneziawg-go listens on `/var/run/amneziawg`. So a tunnel
/// running on amneziawg-go has to be configured here rather than through `wg setconf`.
/// Protocol reference: https://www.wireguard.com/xplatform/#configuration-protocol
enum WireGuardUAPI {

    struct UAPIError: Error {
        let message: String
    }

    /// Directory names to probe for an engine's control socket, in order of preference.
    /// amneziawg-go uses /var/run/amneziawg; the stock engine uses /var/run/wireguard.
    static let socketDirectories = ["/var/run/amneziawg", "/var/run/wireguard"]

    /// The control socket of a live interface, if the engine has created it.
    ///
    /// A killed engine leaves its socket file behind, and a later instance reusing the same
    /// interface name rebinds that path itself. So check connectivity rather than mere existence,
    /// otherwise a stale file would be mistaken for the live socket and the connection refused.
    static func socketPath(interface: String) -> String? {
        for dir in socketDirectories {
            let path = "\(dir)/\(interface).sock"
            if FileManager.default.fileExists(atPath: path), hasLiveListener(path) {
                return path
            }
        }
        return nil
    }

    /// A leftover socket file has no listener behind it and refuses connections.
    private static func hasLiveListener(_ path: String) -> Bool {
        guard let addr = unixAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return connected == 0
    }

    /// Apply a parsed config to the interface listening on `socketPath`.
    static func apply(_ parsed: ParsedWireGuardConfig, socketPath: String) throws {
        try send(request(for: parsed), socketPath: socketPath)
    }

    /// Build the `set=1` operation: device-level keys first, then one block per peer.
    /// Hostname endpoints are resolved here, which `wg setconf` would otherwise have done for us.
    static func request(for parsed: ParsedWireGuardConfig) -> String {
        var lines = ["set=1"]

        if let key = parsed.privateKey, let hex = hexKey(key) {
            lines.append("private_key=\(hex)")
        }
        if let port = parsed.listenPort {
            lines.append("listen_port=\(port)")
        }
        // AmneziaWG obfuscation parameters are device-level; passed through under their UAPI names
        for name in parsed.amneziaParams.keys.sorted() {
            lines.append("\(name)=\(parsed.amneziaParams[name] ?? "")")
        }

        lines.append("replace_peers=true")
        for peer in parsed.peers {
            guard let publicKey = hexKey(peer.publicKey) else { continue }
            lines.append("public_key=\(publicKey)")
            if let psk = peer.presharedKey, let pskHex = hexKey(psk) {
                lines.append("preshared_key=\(pskHex)")
            }
            if let endpoint = peer.endpoint, !endpoint.isEmpty {
                lines.append("endpoint=\(numericEndpoint(endpoint) ?? endpoint)")
            }
            if let keepalive = peer.persistentKeepalive {
                lines.append("persistent_keepalive_interval=\(keepalive)")
            }
            lines.append("replace_allowed_ips=true")
            for ip in peer.allowedIPs {
                lines.append("allowed_ip=\(ip)")
            }
        }

        // The operation is terminated by a blank line, so the stream has to end with "\n\n".
        // Ending right after the last key ("...\n" only) leaves the engine's line scanner waiting
        // for more input: it never answers and the tunnel stays in the "starting" state forever.
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Configs carry keys as base64; the UAPI expects lowercase hex.
    private static func hexKey(_ value: String) -> String? {
        var base64 = value
        if base64.count % 4 != 0 {
            base64 += String(repeating: "=", count: 4 - base64.count % 4)
        }
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// The UAPI expects a numeric `IP:port` endpoint, while a config may name a host
    /// (`wg setconf` resolves those itself). Returns nil when the host cannot be resolved.
    private static func numericEndpoint(_ endpoint: String) -> String? {
        guard let (host, port) = splitHostPort(endpoint) else { return nil }
        if isNumericAddress(host) { return endpoint }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        guard let address = first.pointee.ai_addr else { return nil }

        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, first.pointee.ai_addrlen,
                          &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let resolved = String(cString: text)
        return address.pointee.sa_family == sa_family_t(AF_INET6) ? "[\(resolved)]:\(port)" : "\(resolved):\(port)"
    }

    /// Split `host:port` and the bracketed IPv6 form `[v6]:port`.
    private static func splitHostPort(_ endpoint: String) -> (host: String, port: String)? {
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else { return nil }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let rest = endpoint[endpoint.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            return (host, String(rest.dropFirst()))
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let host = String(endpoint[..<colon])
        let port = String(endpoint[endpoint.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty else { return nil }
        return (host, port)
    }

    private static func isNumericAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }

    /// A `sockaddr_un` for a socket path, or nil when the path does not fit the field.
    private static func unixAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        return addr
    }

    /// Send one UAPI operation and throw unless the engine answers `errno=0`.
    private static func send(_ request: String, socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UAPIError(message: "socket() failed (errno \(errno))")
        }
        defer { close(fd) }

        // Bound both directions: a local engine answers at once, and an unbounded blocking read
        // would otherwise pin the tunnel in the "starting" state forever.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)

        guard var addr = unixAddress(socketPath) else {
            throw UAPIError(message: "Socket path too long: \(socketPath)")
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else {
            throw UAPIError(message: "Cannot connect to \(socketPath) (errno \(errno))")
        }

        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            guard written > 0 else {
                throw UAPIError(message: "Cannot write to \(socketPath) (errno \(errno))")
            }
            sent += written
        }

        // The reply ends with an `errno=` line
        var reply: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let received = read(fd, &buffer, buffer.count)
            if received < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK {
                    throw UAPIError(message: "Timed out waiting for \(socketPath) to answer")
                }
                throw UAPIError(message: "Cannot read from \(socketPath) (errno \(code))")
            }
            if received == 0 { break }
            reply.append(contentsOf: buffer[0..<received])
            if let text = String(bytes: reply, encoding: .utf8), text.contains("errno=") { break }
        }

        let code = String(bytes: reply, encoding: .utf8)?
            .split(separator: "\n")
            .first { $0.hasPrefix("errno=") }
            .flatMap { Int($0.dropFirst("errno=".count)) }
        guard code == 0 else {
            throw UAPIError(message: "Engine rejected the configuration (errno \(code.map(String.init) ?? "none") \(socketPath))")
        }
    }
}
