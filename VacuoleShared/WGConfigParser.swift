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
        public var endpoint: String?
        public var allowedIPs: [String] = []
        public init() {}
    }

    public var addresses: [String] = []
    public var dnsServers: [String] = []
    public var mtu: Int?
    public var peers: [Peer] = []

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
            case "address":
                result.addresses.append(contentsOf: splitList(value))
            case "dns":
                result.dnsServers.append(contentsOf: splitList(value))
            case "mtu":
                result.mtu = Int(value)
            case "publickey":
                currentPeer?.publicKey = value
            case "endpoint":
                currentPeer?.endpoint = value
            case "allowedips":
                currentPeer?.allowedIPs.append(contentsOf: splitList(value))
            default:
                break
            }
        }

        if let peer = currentPeer { result.peers.append(peer) }
        return result
    }

    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}