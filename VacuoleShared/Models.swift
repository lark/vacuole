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

/// Tunnel running state.
public enum TunnelState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case error
}

/// Split-routing direction.
public enum RoutingMode: String, Codable, Sendable, CaseIterable {
    /// Direct by default; targets in the list go through the tunnel (forward).
    case directByDefault
    /// Tunnel by default; targets in the list go direct (reverse).
    case tunnelByDefault
}

/// An imported WireGuard config.
public struct WireGuardConfig: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var rawConfig: String

    public init(id: UUID = UUID(), name: String, rawConfig: String) {
        self.id = id
        self.name = name
        self.rawConfig = rawConfig
    }
}

/// Domain group.
public struct DomainGroup: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var domains: [String]

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, domains: [String] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.domains = domains
    }
}

/// Domain set: contains only domain groups and static routes; independent of any WireGuard config and freely combinable with any of them.
public struct DomainSet: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var groups: [DomainGroup]
    public var staticRoutes: [String]

    public init(id: UUID = UUID(),
                name: String,
                groups: [DomainGroup] = [],
                staticRoutes: [String] = []) {
        self.id = id
        self.name = name
        self.groups = groups
        self.staticRoutes = staticRoutes
    }
}

/// Transport envelope for the domain set list + active state.
public struct DomainSetListEnvelope: Codable, Sendable {
    public var sets: [DomainSet]
    public var activeSetID: UUID?

    public init(sets: [DomainSet], activeSetID: UUID?) {
        self.sets = sets
        self.activeSetID = activeSetID
    }
}

/// Runtime state snapshot of the daemon.
public struct DaemonStatus: Codable, Sendable {
    public var tunnelState: TunnelState
    public var activeConfigName: String?
    public var activeSetName: String?
    public var routingMode: RoutingMode
    public var capturedUpstreamDNS: [String]

    public init(tunnelState: TunnelState = .stopped,
                activeConfigName: String? = nil,
                activeSetName: String? = nil,
                routingMode: RoutingMode = .directByDefault,
                capturedUpstreamDNS: [String] = []) {
        self.tunnelState = tunnelState
        self.activeConfigName = activeConfigName
        self.activeSetName = activeSetName
        self.routingMode = routingMode
        self.capturedUpstreamDNS = capturedUpstreamDNS
    }
}

/// Daemon log entry.
public struct LogEntry: Codable, Sendable, Hashable, Identifiable {
    public var timestamp: Date
    public var level: String   // info / warn / error
    public var component: String
    public var message: String

    public var id: String { "\(timestamp.timeIntervalSince1970)|\(component)|\(message)" }

    public init(timestamp: Date, level: String, component: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.component = component
        self.message = message
    }
}