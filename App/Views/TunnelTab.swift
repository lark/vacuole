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

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VacuoleShared

/// Tunnel / Config Tab: WG config import (drag / paste / file picker), list, start/stop
struct TunnelTab: View {
    @ObservedObject private var client = DaemonClient.shared
    @State private var selectedConfig: String?
    @State private var showImportSheet = false
    @State private var importingName: String = ""
    @State private var importingContent: String = ""
    /// Whether the private key in the config preview is revealed
    @State private var revealKey = false
    /// Name of the config currently being renamed inline (nil when not renaming)
    @State private var editingName: String?
    @State private var editingDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HSplitView {
            leftPane
            rightPane
        }
        .onChange(of: selectedConfig) { _ in revealKey = false }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(
                name: $importingName,
                content: $importingContent,
                onImport: {
                    client.importConfig(name: importingName, rawConfig: importingContent)
                    importingName = ""
                    importingContent = ""
                    showImportSheet = false
                },
                onCancel: {
                    importingName = ""
                    importingContent = ""
                    showImportSheet = false
                }
            )
        }
    }

    // MARK: - Left pane: config list

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("ui.tunnel.configsTitle"))
                .font(.headline)
                .foregroundStyle(.secondary)

            List(client.configs, selection: $selectedConfig) { item in
                HStack(spacing: 6) {
                    if editingName == item.name {
                        TextField("", text: $editingDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFocused)
                            .onSubmit { commitRename(from: item.name) }
                            .onExitCommand { editingName = nil }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.body)
                            if item.name == client.activeConfigName {
                                Text(L("ui.status.running"))
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            beginRename(item.name)
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(L("ui.tunnel.rename"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tag(item.name)
            }
            .listStyle(.inset)

            HStack(spacing: 8) {
                Button {
                    showImportSheet = true
                } label: {
                    actionLabel(L("ui.action.import"), "plus.circle")
                }
                .settingsActionButton()

                Button {
                    openConfigFromFile()
                } label: {
                    actionLabel(L("ui.tunnel.importFromFile"), "doc.badge.plus")
                }
                .settingsActionButton()

                Spacer(minLength: 0)

                Button {
                    if let name = selectedConfig {
                        client.deleteConfig(name: name)
                        selectedConfig = nil
                    }
                } label: {
                    actionLabel(L("ui.action.delete"), "trash")
                }
                .settingsActionButton()
                .disabled(selectedConfig == nil)
            }
        }
        .padding(SettingsUI.panePadding)
        .frame(minWidth: SettingsUI.leftMinWidth,
               idealWidth: SettingsUI.leftIdealWidth,
               maxWidth: SettingsUI.leftMaxWidth)
    }

    // MARK: - Right pane: preview + tunnel control

    private var rightPane: some View {
        VStack(spacing: 12) {
            if let name = selectedConfig,
               let config = client.configs.first(where: { $0.name == name }) {
                GroupBox {
                    ScrollView {
                        Text(maskedConfig(config.rawConfig))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                } label: {
                    HStack(spacing: 6) {
                        Text(L("ui.tunnel.configContent"))
                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(revealKey ? L("ui.tunnel.hideKey") : L("ui.tunnel.revealKey"))
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 10) {
                    if client.tunnelState == .running && client.activeConfigName == name {
                        Button(role: .destructive) {
                            client.stopTunnel()
                        } label: {
                            actionLabel(L("ui.tunnel.stop"), "stop.fill")
                        }
                        .settingsActionButton()
                    } else {
                        Button {
                            client.startTunnel(configName: name)
                        } label: {
                            actionLabel(L("ui.tunnel.start"), "play.fill")
                        }
                        .settingsActionButton()
                        .disabled(client.tunnelState == .starting || client.tunnelState == .stopping)
                    }

                    Spacer(minLength: 0)
                    TunnelStateBadge(state: client.tunnelState)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(L("ui.tunnel.noConfigSelected")).font(.title2)
                    Text(L("ui.tunnel.selectConfigHint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(SettingsUI.panePadding)
        .frame(maxWidth: .infinity)
    }

    /// Mask the `PrivateKey` value unless the user explicitly reveals it.
    private func maskedConfig(_ raw: String) -> String {
        guard !revealKey else { return raw }
        return raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed.hasPrefix("privatekey"), let eq = line.firstIndex(of: "=") else {
                return String(line)
            }
            return String(line[...eq]) + " ••••••••••••••••"
        }
        .joined(separator: "\n")
    }

    /// Label with a fixed icon box so every action button has the same height.
    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
    }

    /// Start inline rename: select the row, seed the draft and focus the field.
    private func beginRename(_ name: String) {
        selectedConfig = name
        editingDraft = name
        editingName = name
        DispatchQueue.main.async { renameFocused = true }
    }

    /// Commit the inline rename. The daemon owns the files and the menu bar is rebuilt from its
    /// config list / active config, so refreshing the client keeps everything in sync.
    private func commitRename(from oldName: String) {
        guard editingName == oldName else { return }
        let newName = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingName = nil
        guard !newName.isEmpty, newName != oldName else { return }
        client.renameConfig(from: oldName, to: newName) { ok in
            if ok, selectedConfig == oldName { selectedConfig = newName }
        }
    }

    /// Import a config from a file chosen by the user.
    private func openConfigFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // WireGuard configs may have any name: accept .conf, plain text and other files.
        panel.allowedContentTypes = [UTType(filenameExtension: "conf"), .plainText, .data].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            importingName = url.deletingPathExtension().lastPathComponent
            importingContent = content
            showImportSheet = true
        } catch {
            client.reportError(error.localizedDescription)
        }
    }
}

// MARK: - Import sheet

private struct ImportSheet: View {
    @Binding var name: String
    @Binding var content: String
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(L("ui.tunnel.importTitle")).font(.headline)
            TextField(L("ui.tunnel.configNamePlaceholder"), text: $name).textFieldStyle(.roundedBorder)
            TextEditor(text: $content)
                .font(.system(.caption, design: .monospaced))
                .border(Color.gray.opacity(0.3))
                .frame(minHeight: 200)
            HStack {
                Button(L("ui.action.cancel"), action: onCancel)
                Spacer()
                Button(L("ui.action.import")) { onImport() }
                    .disabled(name.isEmpty || content.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }
}

// MARK: - Status badge

private struct TunnelStateBadge: View {
    let state: TunnelState
    var body: some View {
        switch state {
        case .running:
            Label(L("ui.status.running"), systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
        case .starting:
            Label(L("ui.status.starting"), systemImage: "circle.dotted").foregroundStyle(.orange).font(.caption)
        case .stopping:
            Label(L("ui.status.stopping"), systemImage: "circle.dotted").foregroundStyle(.orange).font(.caption)
        case .stopped:
            Label(L("ui.status.stopped"), systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        case .error:
            Label(L("ui.status.error"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
        }
    }
}