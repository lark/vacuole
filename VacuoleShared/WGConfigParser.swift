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

/// Key fields of a WireGuard config (parsed here; consumed by the daemon).
public struct ParsedWireGuardConfig: Sendable {
    public struct Peer: Sendable {
        public var publicKey: String = ""
        public var presharedKey: String?
        public var endpoint: String?
        public var persistentKeepalive: Int?
        public var allowedIPs: [String] = []
        public init() {}
    }

    public var privateKey: String?
    public var listenPort: Int?
    public var addresses: [String] = []
    public var dnsServers: [String] = []
    public var mtu: Int?
    public var peers: [Peer] = []

    /// AmneziaWG obfuscation parameters found in the config, keyed by their UAPI names
    /// (e.g. `jc`, `s1`, `header_protection_key`). Empty for a plain WireGuard config.
    public var amneziaParams: [String: String] = [:]

    /// Whether this config needs the AmneziaWG engine.
    public var isAmnezia: Bool { !amneziaParams.isEmpty }

    public init() {}
}

public enum WGConfigParser {
    /// Parse wg-quick style .conf text.
    public static func parse(_ text: String) -> ParsedWireGuardConfig {
        var result = ParsedWireGuardConfig()
        var currentPeer: ParsedWireGuardConfig.Peer?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let eq = line.firstIndex(of: "=") else {
                switch line.lowercased() {
                case "[peer]":
                    if let peer = currentPeer { result.peers.append(peer) }
                    currentPeer = ParsedWireGuardConfig.Peer()
                default:
                    break
                }
                continue
            }

            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "privatekey":
                result.privateKey = value
            case "listenport":
                result.listenPort = Int(value)
            case "address":
                result.addresses.append(contentsOf: splitList(value))
            case "dns":
                result.dnsServers.append(contentsOf: splitList(value))
            case "mtu":
                result.mtu = Int(value)
            case "publickey":
                currentPeer?.publicKey = value
            case "presharedkey":
                currentPeer?.presharedKey = value
            case "endpoint":
                currentPeer?.endpoint = value
            case "persistentkeepalive":
                currentPeer?.persistentKeepalive = Int(value)
            case "allowedips":
                currentPeer?.allowedIPs.append(contentsOf: splitList(value))
            default:
                // AmneziaWG obfuscation parameters (Jc/Jmin/Jmax, S1-S4, H1-H4, I1-I5, ...)
                if let uapiName = Self.amneziaUAPINames[Self.normalizedKey(key)] {
                    result.amneziaParams[uapiName] = value
                }
            }
        }

        if let peer = currentPeer { result.peers.append(peer) }
        return result
    }

    /// AmneziaWG config keys → the names amneziawg-go's UAPI expects.
    private static let amneziaUAPINames: [String: String] = [
        "jc": "jc", "jmin": "jmin", "jmax": "jmax",
        "s1": "s1", "s2": "s2", "s3": "s3", "s4": "s4",
        "h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4",
        "i1": "i1", "i2": "i2", "i3": "i3", "i4": "i4", "i5": "i5",
        "headerprotectionkey": "header_protection_key",
        "contentpaddingaddition": "content_padding_addition",
        "rekeyaftertime": "rekey_after_time",
        "rekeytimeout": "rekey_timeout",
        "rejectaftertime": "reject_after_time",
        "keepalivetimeout": "keepalive_timeout",
        "maxhandshakeattempts": "max_handshake_attempts",
        "randomtrailers": "random_trailers",
        "disablecookies": "disable_cookies",
    ]

    /// Case and separator insensitive key lookup, so `Header_Protection_Key` and
    /// `HeaderProtectionKey` both resolve.
    private static func normalizedKey(_ key: String) -> String {
        key.filter { $0.isLetter || $0.isNumber }
    }

    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}