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

import SwiftUI
import VacuoleShared

/// Domain Sets Tab: set management (left) + group & domain management (right)
/// Features: search, add/remove, bulk file import, group enable toggles, activate set
struct DomainSetsTab: View {
    @ObservedObject private var client = DaemonClient.shared

    // Set-level state
    @State private var selectedSetID: UUID?
    @State private var newSetName: String = ""

    // Group/domain-level state
    @State private var newGroupName: String = ""
    @State private var newDomain: String = ""
    @State private var searchText: String = ""

    // File import
    @State private var showFileImporter = false
    @State private var pendingImportContent: String?

    var body: some View {
        HSplitView {
            // ── Left: domain set list ──
            VStack(alignment: .leading, spacing: 10) {
                Text(L("ui.domainSets.setsTitle"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                List(selection: $selectedSetID) {
                    ForEach(client.domainSets) { set in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(set.name).font(.body)
                                    if set.id == client.activeSetID {
                                        Text(L("ui.domainSets.activated"))
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.green.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(L("ui.domainSets.groupDomainCount", set.groups.count, totalDomainCount(set)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(set.id)
                    }
                }
                .listStyle(.inset)

                HStack {
                    TextField(L("ui.domainSets.newSetNamePlaceholder"), text: $newSetName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let name = newSetName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let set = DomainSet(name: name)
                        client.saveDomainSet(set)
                        selectedSetID = set.id
                        newSetName = ""
                    } label: {
                        Image(systemName: "plus")
                    }
                    .settingsActionButton()
                    .disabled(newSetName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        if let id = selectedSetID {
                            client.deleteDomainSet(id: id)
                            selectedSetID = nil
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .settingsActionButton()
                    .disabled(selectedSetID == nil)
                }
            }
            .padding(SettingsUI.panePadding)
            .frame(minWidth: SettingsUI.leftMinWidth,
                   idealWidth: SettingsUI.leftIdealWidth,
                   maxWidth: SettingsUI.leftMaxWidth)

            // ── Right: groups and domains ──
            if let idx = client.domainSets.firstIndex(where: { $0.id == selectedSetID }) {
                DomainSetDetailView(
                    set: Binding(
                        get: { client.domainSets[idx] },
                        set: { client.saveDomainSet($0) }
                    ),
                    isActive: client.domainSets[idx].id == client.activeSetID,
                    searchText: $searchText,
                    newGroupName: $newGroupName,
                    newDomain: $newDomain,
                    onActivate: { client.activateDomainSet(id: client.domainSets[idx].id) },
                    onImportFile: { showFileImporter = true }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(L("ui.domainSets.noSetSelected")).font(.title2)
                    Text(L("ui.domainSets.selectSetHint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(SettingsUI.panePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { client.refreshDomainSets() }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText, .text]) { result in
            switch result {
            case .success(let url):
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        pendingImportContent = content
                    }
                }
            case .failure(let error):
                client.reportError(error.localizedDescription)
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingImportContent != nil },
            set: { if !$0 { pendingImportContent = nil } }
        )) {
            if let content = pendingImportContent {
                ImportDomainsSheet(
                    rawText: content,
                    groups: selectedSetGroups,
                    onConfirm: { groupID, newGroupName, domains in
                        applyImport(groupID: groupID, newGroupName: newGroupName, domains: domains)
                        pendingImportContent = nil
                    }
                )
            }
        }
    }

    private var selectedSetGroups: [(UUID, String)] {
        guard let set = client.domainSets.first(where: { $0.id == selectedSetID }) else { return [] }
        return set.groups.map { ($0.id, $0.name) }
    }

    /// Apply bulk import: create a new group when groupID is nil and newGroupName is non-empty
    private func applyImport(groupID: UUID?, newGroupName: String?, domains: [String]) {
        guard let idx = client.domainSets.firstIndex(where: { $0.id == selectedSetID }) else { return }
        var set = client.domainSets[idx]

        let targetGroupID: UUID
        if let gid = groupID, set.groups.contains(where: { $0.id == gid }) {
            targetGroupID = gid
        } else {
            let name = newGroupName?.trimmingCharacters(in: .whitespaces) ?? ""
            let group = DomainGroup(name: name.isEmpty ? L("ui.action.import") : name)
            set.groups.append(group)
            targetGroupID = group.id
        }

        guard let gi = set.groups.firstIndex(where: { $0.id == targetGroupID }) else { return }
        var merged = set.groups[gi].domains
        for d in domains where !merged.contains(d) {
            merged.append(d)
        }
        set.groups[gi].domains = merged
        client.saveDomainSet(set)
    }

    private func totalDomainCount(_ set: DomainSet) -> Int {
        set.groups.reduce(0) { $0 + $1.domains.count }
    }
}

// MARK: - Set details

private struct DomainSetDetailView: View {
    @Binding var set: DomainSet
    let isActive: Bool
    @Binding var searchText: String
    @Binding var newGroupName: String
    @Binding var newDomain: String
    let onActivate: () -> Void
    let onImportFile: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Top: set name + search + activate button
            HStack {
                TextField(L("ui.domainSets.setNamePlaceholder"), text: Binding(
                    get: { set.name },
                    set: { set.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L("ui.domainSets.searchPlaceholder"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: 200)

                Spacer()

                if isActive {
                    Label(L("ui.domainSets.currentlyActive"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button(L("ui.domainSets.activate"), action: onActivate)
                        .buttonStyle(.borderedProminent)
                }
            }

            // Group management
            GroupBox(L("ui.domainSets.groups")) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($set.groups) { $group in
                            GroupRowView(
                                group: $group,
                                searchText: searchText,
                                onDelete: {
                                    set.groups.removeAll { $0.id == group.id }
                                },
                                onImportFile: onImportFile
                            )
                            Divider()
                        }

                        // New group
                        HStack {
                            TextField(L("ui.domainSets.newGroupNamePlaceholder"), text: $newGroupName)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                set.groups.append(DomainGroup(name: name))
                                newGroupName = ""
                            } label: {
                                Image(systemName: "plus")
                            }
                            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.top, 4)
                    }
                    .padding(8)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(SettingsUI.panePadding)
        .frame(minWidth: 520)
    }
}

// MARK: - Single group row

private struct GroupRowView: View {
    @Binding var group: DomainGroup
    let searchText: String
    let onDelete: () -> Void
    let onImportFile: () -> Void
    @State private var newDomain: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(group.name, isOn: $group.enabled)
                    .toggleStyle(.switch)
                Spacer()
                Text(L("ui.domainSets.domainCount", group.domains.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    onImportFile()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.borderless)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }

            // Add domain
            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField(L("ui.domainSets.domainPlaceholder"), text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addDomain() }
                Button(L("ui.action.add")) { addDomain() }
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Domain list (filtered by search; truncated to 20 when longer)
            let filtered = filteredDomains
            if !filtered.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.self) { domain in
                        HStack {
                            Text(domain)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button {
                                removeDomain(domain)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                    }
                    if group.domains.count > filtered.count {
                        Text(L("ui.domainSets.moreHidden", group.domains.count - filtered.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                }
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(6)
    }

    private var filteredDomains: [String] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let all = group.domains.sorted()
        guard !q.isEmpty else { return Array(all.prefix(20)) }
        return all.filter { $0.contains(q) }
    }

    private func addDomain() {
        var d = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !d.isEmpty else { return }
        if !d.hasSuffix(".") { d += "." }
        guard !group.domains.contains(d) else {
            newDomain = ""
            return
        }
        group.domains.append(d)
        newDomain = ""
    }

    private func removeDomain(_ domain: String) {
        group.domains.removeAll { $0 == domain }
    }
}

// MARK: - Bulk import sheet

private struct ImportDomainsSheet: View {
    let rawText: String
    let groups: [(UUID, String)]
    /// groupID = nil means create a new group (use newGroupName)
    let onConfirm: (UUID?, String?, [String]) -> Void

    @State private var selectedGroupID: UUID?
    @State private var newGroupName: String = ""

    private var parsed: [String] {
        Self.parseDomains(rawText)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(L("ui.domainSets.importTitle")).font(.headline)
            Text(L("ui.domainSets.parsedCount", parsed.count))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Picker(L("ui.domainSets.importToGroup"), selection: $selectedGroupID) {
                    Text(L("ui.domainSets.newGroupOption")).tag(UUID?.none)
                    ForEach(groups, id: \.0) { id, name in
                        Text(name).tag(UUID?.some(id))
                    }
                }
                if selectedGroupID == nil {
                    TextField(L("ui.domainSets.groupNamePlaceholder"), text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
            }

            ScrollView {
                Text(parsed.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)

            HStack {
                Button(L("ui.action.cancel")) { onConfirm(nil, nil, []) }
                Spacer()
                Button(L("ui.action.import")) {
                    onConfirm(selectedGroupID, selectedGroupID == nil ? newGroupName : nil, parsed)
                }
                .disabled(parsed.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
    }

    /// Parse domain list: supports one domain per line, hosts format (IP domain), # comments
    static func parseDomains(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let candidate = parts.count >= 2 ? String(parts[1]) : String(parts.first ?? "")
            var d = candidate.lowercased()
            if d.hasSuffix(".") { d = String(d.dropLast()) }
            guard !d.isEmpty, d.contains(".") else { continue }
            d += "."
            if !seen.contains(d) {
                seen.insert(d)
                result.append(d)
            }
        }
        return result
    }
}