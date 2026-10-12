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

/// Domain set manager (inside the root daemon).
///
/// Responsibilities:
/// 1. Domain set persistence (/var/db/vacuole/sets.json)
/// 2. Activating a domain set: push domains to DNSProxyServer and install static routes via RouteController
final class DomainSetManager {

    static let shared = DomainSetManager()

    private(set) var sets: [DomainSet] = []
    private(set) var activeSetID: UUID?

    /// All domains of the currently active domain set (flattened, including wildcards)
    private(set) var activeDomains: [String] = []

    private let storeFile = "\(VacuoleDaemonConstants.dataDir)/sets.json"

    private init() {
        load()
        ensureDefaultSet()
    }

    /// On first run (no domain set yet), auto-create an empty "default" set and activate it,
    /// avoiding a blank UI and letting users add domains right out of the box.
    private func ensureDefaultSet() {
        guard sets.isEmpty else { return }
        let set = DomainSet(name: "default")
        sets = [set]
        activeSetID = set.id
        save()
        syncDomainsToDNS()
        LogStore.shared.info("sets", "First run: created an empty default domain set \"default\"")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: storeFile) else { return }
        struct Store: Codable {
            var sets: [DomainSet] = []
            var activeSetID: UUID?
        }
        if let store = try? JSONDecoder().decode(Store.self, from: data) {
            sets = store.sets
            activeSetID = store.activeSetID
        }
    }

    private func save() {
        struct Store: Codable {
            var sets: [DomainSet]
            var activeSetID: UUID?
        }
        let store = Store(sets: sets, activeSetID: activeSetID)
        let dir = VacuoleDaemonConstants.dataDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: URL(fileURLWithPath: storeFile))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeFile)
        }
    }

    // MARK: - CRUD

    func upsertSet(_ set: DomainSet) -> (Bool, String?) {
        if let idx = sets.firstIndex(where: { $0.id == set.id }) {
            sets[idx] = set
        } else {
            sets.append(set)
        }
        save()

        // If currently active, sync domains and routes immediately
        if set.id == activeSetID {
            _ = applyActive(set)
        }
        return (true, nil)
    }

    func deleteSet(id: UUID) -> (Bool, String?) {
        guard let idx = sets.firstIndex(where: { $0.id == id }) else {
            return (false, L("daemon.domainSet.notFound"))
        }
        sets.remove(at: idx)
        if activeSetID == id {
            activeSetID = nil
            activeDomains = []
            syncDomainsToDNS()
            _ = RouteController.shared.replaceStatic([])
        }
        save()
        return (true, nil)
    }

    // MARK: - Activation

    /// Activate a domain set: push domains to DNS and install static routes via RouteController
    func activate(id: UUID) -> (Bool, String?) {
        guard let set = sets.first(where: { $0.id == id }) else {
            return (false, L("daemon.domainSet.notFound"))
        }
        activeSetID = id
        save()
        let result = applyActive(set)
        if result.0 {
            LogStore.shared.info("sets", "Activated domain set \"\(set.name)\": \(activeDomains.count) domains / \(set.staticRoutes.count) static routes")
        }
        return result
    }

    private func applyActive(_ set: DomainSet) -> (Bool, String?) {
        // 1. Flatten domains of all enabled groups
        var domains: [String] = []
        for group in set.groups where group.enabled {
            domains.append(contentsOf: group.domains)
        }
        activeDomains = domains

        // 2. Push to the DNS proxy
        syncDomainsToDNS()

        // 3. Static routes: replace all with tunnel-interface routes
        _ = RouteController.shared.replaceStatic(set.staticRoutes)

        return (true, nil)
    }

    /// After the tunnel (re)starts, re-apply the domains and static routes of the currently active domain set
    func reapplyActiveRoutes() {
        guard let id = activeSetID, let set = sets.first(where: { $0.id == id }) else { return }
        syncDomainsToDNS()
        _ = RouteController.shared.replaceStatic(set.staticRoutes)
    }

    private func syncDomainsToDNS() {
        DNSProxyServer.shared.updateManagedDomains(activeDomains)
    }
}