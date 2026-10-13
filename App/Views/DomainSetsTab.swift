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

/// Which pane the right-hand side shows.
private enum DomainDetailTab: String, Hashable {
    case edit
    case search
}

/// Domain Sets Tab: set management (left) + edit / search panes (right)
/// Features: add/remove sets and groups, domain editing, file import/export, global search, activation
struct DomainSetsTab: View {
    @ObservedObject private var client = DaemonClient.shared

    /// Name of the auto-created fallback set, which is not renameable.
    static let defaultSetName = "default"

    // Set-level state
    @State private var selectedSetID: UUID?
    @State private var newSetName: String = ""
    /// Id of the set whose name is being renamed inline (nil when not renaming)
    @State private var editingSetID: UUID?
    @State private var editingSetDraft = ""
    @FocusState private var setRenameFocused: Bool

    // Right pane state
    @State private var detailTab: DomainDetailTab = .edit
    @State private var newGroupName: String = ""
    @State private var searchText: String = ""

    // File import
    @State private var pendingImportContent: String?
    @State private var pendingImportGroupID: UUID?

    var body: some View {
        HSplitView {
            // ── Left: domain set list ──
            VStack(alignment: .leading, spacing: 10) {
                Text(L("ui.domainSets.setsTitle"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                List(selection: $selectedSetID) {
                    ForEach(client.domainSets) { set in
                        HStack(spacing: 6) {
                            if editingSetID == set.id {
                                TextField("", text: $editingSetDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($setRenameFocused)
                                    .onSubmit { commitSetRename(set.id) }
                                    .onExitCommand { editingSetID = nil }
                            } else {
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
                                Spacer(minLength: 0)
                                // The auto-created "default" set keeps its name
                                if set.name != Self.defaultSetName {
                                    Button {
                                        beginSetRename(set)
                                    } label: {
                                        Image(systemName: "pencil")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L("ui.domainSets.rename"))
                                }
                                // Delete lives on the row instead of a toolbar button, so it always
                                // targets the set the user is pointing at
                                Button {
                                    client.deleteDomainSet(id: set.id)
                                    if selectedSetID == set.id { selectedSetID = nil }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help(L("ui.domainSets.deleteSet"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                        .tag(set.id)
                    }
                }
                .listStyle(.inset)

                HStack {
                    TextField(L("ui.domainSets.newSetNamePlaceholder"), text: $newSetName)
                        .textFieldStyle(.roundedBorder)
                    // Plain text button: an icon here would sit next to the row's own icons and
                    // look inconsistent (and symbols of different ink heights break the row height)
                    Button(L("ui.action.add")) {
                        let name = newSetName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let set = DomainSet(name: name)
                        client.saveDomainSet(set)
                        selectedSetID = set.id
                        newSetName = ""
                    }
                    .disabled(newSetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(SettingsUI.panePadding)
            .frame(minWidth: SettingsUI.leftMinWidth,
                   idealWidth: SettingsUI.leftIdealWidth,
                   maxWidth: SettingsUI.leftMaxWidth)

            // ── Right: edit / search ──
            if let idx = client.domainSets.firstIndex(where: { $0.id == selectedSetID }) {
                DomainSetDetailView(
                    set: Binding(
                        get: { client.domainSets[idx] },
                        set: { client.saveDomainSet($0) }
                    ),
                    isActive: client.domainSets[idx].id == client.activeSetID,
                    allSets: client.domainSets,
                    tab: $detailTab,
                    searchText: $searchText,
                    newGroupName: $newGroupName,
                    onActivate: { client.activateDomainSet(id: client.domainSets[idx].id) },
                    onImportFile: { groupID in importFromFile(into: groupID) },
                    onExportFile: { exportSelectedSet() },
                    onRemoveDomain: removeDomain(setID:groupID:domain:)
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
        .onAppear {
            client.refreshDomainSets()
            selectFallbackSetIfNeeded()
        }
        // The sets arrive asynchronously over XPC, so the fallback selection also has to run once
        // the list is populated (on the first appearance it can still be empty)
        .onChange(of: client.domainSets) { _ in selectFallbackSetIfNeeded() }
        .sheet(isPresented: Binding(
            get: { pendingImportContent != nil },
            set: { if !$0 { pendingImportContent = nil } }
        )) {
            if let content = pendingImportContent {
                ImportDomainsSheet(
                    groups: selectedSetGroups,
                    parsed: DomainFileParser.parse(content),
                    preselectedGroupID: pendingImportGroupID,
                    onConfirm: { plan in
                        applyImport(plan)
                        pendingImportContent = nil
                    },
                    onCancel: { pendingImportContent = nil }
                )
            }
        }
    }

    private var selectedSetGroups: [(UUID, String)] {
        guard let set = client.domainSets.first(where: { $0.id == selectedSetID }) else { return [] }
        return set.groups.map { ($0.id, $0.name) }
    }

    private func totalDomainCount(_ set: DomainSet) -> Int {
        set.groups.reduce(0) { $0 + $1.domains.count }
    }

    /// Entering the pane with nothing selected preselects the `default` set (or the first one),
    /// so the user does not have to click first to see any content.
    private func selectFallbackSetIfNeeded() {
        guard selectedSetID == nil else { return }
        let sets = client.domainSets
        guard !sets.isEmpty else { return }
        selectedSetID = (sets.first { $0.name == Self.defaultSetName } ?? sets[0]).id
    }

    // MARK: - Set rename

    /// Start inline rename: select the row, seed the draft and focus the field.
    private func beginSetRename(_ set: DomainSet) {
        selectedSetID = set.id
        editingSetDraft = set.name
        editingSetID = set.id
        DispatchQueue.main.async { setRenameFocused = true }
    }

    private func commitSetRename(_ id: UUID) {
        guard editingSetID == id else { return }
        let newName = editingSetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingSetID = nil
        guard !newName.isEmpty,
              let idx = client.domainSets.firstIndex(where: { $0.id == id }),
              client.domainSets[idx].name != newName else { return }
        var set = client.domainSets[idx]
        set.name = newName
        client.saveDomainSet(set)
    }

    // MARK: - File import / export

    /// `groupID` preselects a group in the import sheet (the per-group import button passes its own).
    private func importFromFile(into groupID: UUID?) {
        do {
            guard let file = try FileDialogs.openTextFile(title: L("ui.domainSets.importTitle")) else { return }
            pendingImportGroupID = groupID
            pendingImportContent = file.text
        } catch {
            client.reportError("\(L("ui.error.importFailed")): \(error.localizedDescription)")
        }
    }

    private func exportSelectedSet() {
        guard let set = client.domainSets.first(where: { $0.id == selectedSetID }) else { return }
        guard set.groups.contains(where: { !$0.domains.isEmpty }) else {
            client.reportError(L("ui.domainSets.exportEmpty"))
            return
        }
        let fileName = set.name.replacingOccurrences(of: "/", with: "-") + ".txt"
        do {
            try FileDialogs.saveTextFile(title: L("ui.domainSets.exportToFile"),
                                         suggestedName: fileName,
                                         content: Self.exportText(for: set))
        } catch {
            client.reportError("\(L("ui.error.exportFailed")): \(error.localizedDescription)")
        }
    }

    /// One domain per line with groups as `#` comments, so the file can be re-imported as-is.
    private static func exportText(for set: DomainSet) -> String {
        var lines = ["# vacuole domain set: \(set.name)"]
        for group in set.groups {
            guard !group.domains.isEmpty else { continue }
            lines.append("")
            lines.append("# \(group.name)\(group.enabled ? "" : " (disabled)")")
            lines.append(contentsOf: group.domains.sorted())
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Editing

    /// Apply the plan chosen in the import sheet: either recreate the file's `#` groups, or drop
    /// everything into a single group.
    private func applyImport(_ plan: ImportPlan) {
        guard let idx = client.domainSets.firstIndex(where: { $0.id == selectedSetID }) else { return }
        var set = client.domainSets[idx]

        switch plan {
        case .grouped(let parsed):
            for section in parsed.sections where !section.domains.isEmpty {
                let name = section.groupName ?? L("ui.action.import")
                let gi = groupIndex(named: name, in: &set, createEnabled: !section.groupDisabled)
                merge(section.domains, into: &set.groups[gi].domains)
            }
        case .single(let groupID, let newGroupName, let domains):
            let gi: Int
            if let gid = groupID, let existing = set.groups.firstIndex(where: { $0.id == gid }) {
                gi = existing
            } else {
                let name = (newGroupName ?? "").trimmingCharacters(in: .whitespaces)
                set.groups.append(DomainGroup(name: name.isEmpty ? L("ui.action.import") : name))
                gi = set.groups.count - 1
            }
            merge(domains, into: &set.groups[gi].domains)
        }
        client.saveDomainSet(set)
    }

    /// Index of the group with this name; a new group is appended when it does not exist yet
    private func groupIndex(named name: String, in set: inout DomainSet, createEnabled: Bool) -> Int {
        if let existing = set.groups.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            return existing
        }
        set.groups.append(DomainGroup(name: name, enabled: createEnabled))
        return set.groups.count - 1
    }

    private func merge(_ domains: [String], into target: inout [String]) {
        for domain in domains where !target.contains(domain) {
            target.append(domain)
        }
    }

    /// Remove a domain found through the global search, which may live in any set.
    private func removeDomain(setID: UUID, groupID: UUID, domain: String) {
        guard let si = client.domainSets.firstIndex(where: { $0.id == setID }) else { return }
        var set = client.domainSets[si]
        guard let gi = set.groups.firstIndex(where: { $0.id == groupID }) else { return }
        set.groups[gi].domains.removeAll { $0 == domain }
        client.saveDomainSet(set)
    }
}

// MARK: - Set details

private struct DomainSetDetailView: View {
    @Binding var set: DomainSet
    let isActive: Bool
    let allSets: [DomainSet]
    @Binding var tab: DomainDetailTab
    @Binding var searchText: String
    @Binding var newGroupName: String
    let onActivate: () -> Void
    let onImportFile: (UUID?) -> Void
    let onExportFile: () -> Void
    let onRemoveDomain: (UUID, UUID, String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Top: set name + pane selector + activate button
            HStack {
                TextField(L("ui.domainSets.setNamePlaceholder"), text: Binding(
                    get: { set.name },
                    set: { set.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    // The auto-created "default" set keeps its name
                    .disabled(set.name == DomainSetsTab.defaultSetName)
                    .help(set.name == DomainSetsTab.defaultSetName ? L("ui.domainSets.defaultLocked") : "")

                Picker("", selection: $tab) {
                    Text(L("ui.domainSets.tabEdit")).tag(DomainDetailTab.edit)
                    Text(L("ui.domainSets.tabSearch")).tag(DomainDetailTab.search)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

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

            switch tab {
            case .edit:
                editor
            case .search:
                DomainSearchView(sets: allSets, query: $searchText, onRemove: onRemoveDomain)
            }
        }
        .padding(SettingsUI.panePadding)
        .frame(minWidth: 520)
    }

    private var editor: some View {
        // The group box holds a scrolling content area, so it must be the only flexible child here.
        // A trailing Spacer would share the leftover height with it and leave the box hovering above
        // the pane's bottom instead of ending at the usual 14pt margin.
        VStack(spacing: 12) {
            GroupBox {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($set.groups) { $group in
                            GroupRowView(
                                group: $group,
                                onDelete: {
                                    set.groups.removeAll { $0.id == group.id }
                                },
                                onImportFile: { onImportFile(group.id) }
                            )
                            Divider()
                        }

                        // New group
                        HStack {
                            TextField(L("ui.domainSets.newGroupNamePlaceholder"), text: $newGroupName)
                                .textFieldStyle(.roundedBorder)
                            Button(L("ui.action.add")) {
                                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                set.groups.append(DomainGroup(name: name))
                                newGroupName = ""
                            }
                            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.top, 4)
                    }
                    .padding(8)
                }
            } label: {
                HStack {
                    Text(L("ui.domainSets.groups"))
                    Spacer()
                    Button {
                        onImportFile(nil)
                    } label: {
                        SettingsActionLabel(title: L("ui.domainSets.importFromFile"),
                                            systemImage: "square.and.arrow.down")
                    }
                    .settingsActionButton()
                    Button {
                        onExportFile()
                    } label: {
                        SettingsActionLabel(title: L("ui.domainSets.exportToFile"),
                                            systemImage: "square.and.arrow.up")
                    }
                    .settingsActionButton()
                }
            }
        }
    }
}

// MARK: - Global domain search

private struct DomainSearchView: View {
    let sets: [DomainSet]
    @Binding var query: String
    let onRemove: (UUID, UUID, String) -> Void

    private struct Match: Identifiable {
        let id: String
        let domain: String
        let setName: String
        let groupName: String
        let setID: UUID
        let groupID: UUID
        /// True when the row is listed because the group name matched, not the domain itself
        let viaGroup: Bool
    }

    /// Domains matching the keyword, plus every domain of a group whose name matches.
    /// A domain reached through its group is listed once and flagged, never twice.
    private var matches: [Match] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var found: [Match] = []
        for set in sets {
            for group in set.groups {
                let groupMatched = group.name.lowercased().contains(q)
                for domain in group.domains where groupMatched || domain.contains(q) {
                    found.append(Match(id: "\(set.id)|\(group.id)|\(domain)",
                                       domain: domain,
                                       setName: set.name,
                                       groupName: group.name,
                                       setID: set.id,
                                       groupID: group.id,
                                       viaGroup: groupMatched))
                }
            }
        }
        return found.sorted { $0.domain < $1.domain }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("ui.domainSets.searchPlaceholder"), text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Spacer()
                Text(L("ui.domainSets.searchAllHint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if matches.isEmpty {
                Spacer()
                Text(L("ui.domainSets.noMatch"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("ui.domainSets.searchResultCount", matches.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if matches.contains(where: { $0.viaGroup }) {
                        Text(L("ui.domainSets.searchGroupHint"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                List(matches) { match in
                    HStack(spacing: 8) {
                        Text(match.domain)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(match.setName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        // The group name carries its own background so group-name matches stand out
                        Text(match.groupName)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(match.viaGroup ? Color.accentColor.opacity(0.22)
                                                       : Color.gray.opacity(0.12))
                            .clipShape(Capsule())
                        Button {
                            onRemove(match.setID, match.groupID, match.domain)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Single group row

private struct GroupRowView: View {
    @Binding var group: DomainGroup
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

            // Domain list (first 20 shown; the Search pane covers the rest)
            let shown = shownDomains
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.self) { domain in
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
                    if group.domains.count > shown.count {
                        Text(L("ui.domainSets.moreHidden", group.domains.count - shown.count))
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

    private var shownDomains: [String] {
        Array(group.domains.sorted().prefix(20))
    }

    private func addDomain() {
        guard let d = DomainFileParser.normalizedDomain(newDomain) else { return }
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
    let groups: [(UUID, String)]
    let onConfirm: (ImportPlan) -> Void
    let onCancel: () -> Void

    /// How a file that carries `#` group markers is applied
    private enum Mode: String, Hashable {
        case grouped
        case single
    }

    private let parsed: DomainFileParser.Result

    @State private var mode: Mode
    @State private var selectedGroupID: UUID?
    @State private var newGroupName: String = ""

    init(groups: [(UUID, String)],
         parsed: DomainFileParser.Result,
         preselectedGroupID: UUID?,
         onConfirm: @escaping (ImportPlan) -> Void,
         onCancel: @escaping () -> Void) {
        self.groups = groups
        self.parsed = parsed
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // A file carrying `#` group markers defaults to importing those groups as they are
        _mode = State(initialValue: parsed.hasGroups ? .grouped : .single)
        _selectedGroupID = State(initialValue: preselectedGroupID)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(L("ui.domainSets.importTitle")).font(.headline)
            Text(L("ui.domainSets.parsedCount", parsed.domains.count))
                .font(.callout)
                .foregroundStyle(.secondary)
            if parsed.invalidLines > 0 {
                Text(L("ui.domainSets.importFiltered", parsed.invalidLines))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if parsed.hasGroups {
                Picker("", selection: $mode) {
                    Text(L("ui.domainSets.importModeGrouped", parsed.groupNames.count)).tag(Mode.grouped)
                    Text(L("ui.domainSets.importModeSingle")).tag(Mode.single)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !parsed.hasGroups || mode == .single {
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
            }

            ScrollView {
                Text(previewText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)

            HStack {
                Button(L("ui.action.cancel")) { onCancel() }
                Spacer()
                Button(L("ui.action.import")) {
                    if parsed.hasGroups, mode == .grouped {
                        onConfirm(.grouped(parsed))
                    } else {
                        onConfirm(.single(groupID: selectedGroupID,
                                          newGroupName: selectedGroupID == nil ? newGroupName : nil,
                                          domains: parsed.domains))
                    }
                }
                .disabled(parsed.domains.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
    }

    /// Preview of what will be imported, capped so an oversized file cannot stall the sheet
    private var previewText: String {
        let lines = parsed.previewText.split(separator: "\n", omittingEmptySubsequences: false)
        let limit = 400
        guard lines.count > limit else { return parsed.previewText }
        return lines.prefix(limit).joined(separator: "\n")
            + "\n" + L("ui.domainSets.importPreviewMore", lines.count - limit)
    }
}

// MARK: - Import plan

/// What the import sheet decided to do with the parsed file.
private enum ImportPlan {
    /// Recreate the `#` groups found in the file, merging into groups that already exist
    case grouped(DomainFileParser.Result)
    /// Put every parsed domain into a single group
    case single(groupID: UUID?, newGroupName: String?, domains: [String])
}

// MARK: - Domain list file parsing

/// Parses domain list files: one domain per line, optional `#` group markers, hosts-format lines.
private enum DomainFileParser {

    struct Section {
        let groupName: String?
        let groupDisabled: Bool
        let domains: [String]
    }

    struct Result {
        let sections: [Section]
        let invalidLines: Int

        var domains: [String] { sections.flatMap { $0.domains } }
        var groupNames: [String] { sections.compactMap { $0.groupName } }
        var hasGroups: Bool { !groupNames.isEmpty }

        /// Everything that will be imported, in file order
        var previewText: String {
            var lines: [String] = []
            for section in sections where !section.domains.isEmpty {
                if let name = section.groupName {
                    if !lines.isEmpty { lines.append("") }
                    lines.append("# \(name)\(section.groupDisabled ? " (disabled)" : "")")
                }
                lines.append(contentsOf: section.domains)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Characters allowed in a domain entry. Anything else — spaces, slashes, control characters
    /// and the like — makes the line invalid, so a malformed or hostile file cannot push arbitrary
    /// text into the routing and DNS layers.
    private static let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-.*_")

    static func parse(_ text: String) -> Result {
        var sections: [Section] = []
        var currentName: String?
        var currentDisabled = false
        var currentDomains: [String] = []
        var seen = Set<String>()
        var invalidLines = 0

        func flush() {
            guard !currentDomains.isEmpty else { return }
            sections.append(Section(groupName: currentName,
                                    groupDisabled: currentDisabled,
                                    domains: currentDomains))
            currentDomains = []
        }

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let comment = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                // Skip empty comments and the header our own export writes
                if comment.isEmpty || comment.lowercased().hasPrefix("vacuole domain set:") { continue }
                var name = comment
                var disabled = false
                if name.lowercased().hasSuffix("(disabled)") {
                    disabled = true
                    name = String(name.dropLast("(disabled)".count)).trimmingCharacters(in: .whitespaces)
                }
                flush()
                currentName = name.isEmpty ? nil : name
                currentDisabled = disabled
                continue
            }

            // Hosts format ("1.2.3.4 domain") keeps the second field, otherwise the whole line
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let candidate = parts.count >= 2 ? String(parts[1]) : String(parts.first ?? "")
            guard let domain = normalizedDomain(candidate) else {
                invalidLines += 1
                continue
            }
            if seen.insert(domain).inserted {
                currentDomains.append(domain)
            }
        }
        flush()
        return Result(sections: sections, invalidLines: invalidLines)
    }

    /// Normalize one entry, or return nil when it is not a plausible domain
    static func normalizedDomain(_ candidate: String) -> String? {
        var domain = candidate.trimmingCharacters(in: .whitespaces).lowercased()
        if domain.hasSuffix(".") { domain = String(domain.dropLast()) }
        guard !domain.isEmpty, domain.count <= 253 else { return nil }
        guard domain.allSatisfy({ allowedCharacters.contains($0) }) else { return nil }
        guard domain.contains("."), !domain.hasPrefix("."), !domain.contains("..") else { return nil }
        guard domain.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return nil }
        return domain + "."
    }
}