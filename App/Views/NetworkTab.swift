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

/// Network / DNS Tab: DNS proxy control + upstream DNS source (tunnel-provided or custom)
/// + captured physical DNS + route expiry config
struct NetworkTab: View {
    @ObservedObject private var client = DaemonClient.shared
    @State private var ttlInput: String = ""
    @State private var newUpstream: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dnsProxyBox
            upstreamBox
            routeExpiryBox
            Spacer(minLength: 0)
        }
        .padding(SettingsUI.panePadding)
        .onAppear {
            client.refreshDNSStatus()
            ttlInput = String(Int(client.routeTTL))
        }
        .onChange(of: client.routeTTL) { newValue in
            ttlInput = String(Int(newValue))
        }
    }

    // MARK: - DNS proxy status

    private var dnsProxyBox: some View {
        GroupBox(L("ui.network.dnsProxy")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: dnsStatusIcon)
                        .foregroundStyle(dnsStatusColor)
                    Text(dnsStatusText)
                        .font(.headline)
                    Spacer()
                    if client.dnsRunning {
                        Button(role: .destructive) {
                            client.stopDNS()
                        } label: {
                            Label(L("ui.network.stopDNS"), systemImage: "stop.fill")
                        }
                        .settingsActionButton()
                    } else {
                        Button {
                            client.startDNS()
                        } label: {
                            Label(L("ui.network.startDNS"), systemImage: "play.fill")
                        }
                        .settingsActionButton()
                    }
                    Button(L("ui.action.refresh")) { client.refreshDNSStatus() }
                        .settingsActionButton()
                }

                Toggle(L("ui.network.autoStartDNS"), isOn: Binding(
                    get: { client.autoStartDNS },
                    set: { client.setAutoStartDNS($0) }))
                    .toggleStyle(.switch)

                Text(L("ui.network.dnsNotice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }

    // MARK: - Upstream DNS source

    private var upstreamBox: some View {
        GroupBox(L("ui.network.upstreamTitle")) {
            VStack(alignment: .leading, spacing: 10) {
                // Linked with the tunnel: use the DNS declared by the active config, or a custom list
                Picker("", selection: Binding(
                    get: { client.upstreamMode },
                    set: { client.setUpstreamMode($0) })) {
                    Text(L("ui.network.modeTunnel")).tag("tunnel")
                    Text(L("ui.network.modeCustom")).tag("custom")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(alignment: .top, spacing: 12) {
                    // Left: captured physical DNS (read-only)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("ui.network.capturedTitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if client.capturedDNS.isEmpty {
                            Text(L("ui.network.notCaptured"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(client.capturedDNS, id: \.self) { dns in
                                Text(dns).font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    // Right: the upstream selected above
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("ui.network.customTitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if client.upstreamMode == "tunnel" {
                            tunnelProvidedList
                        } else {
                            customUpstreamList
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(L("ui.network.effective", client.effectiveUpstream.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }

    /// Read-only view of the DNS declared by the active WireGuard config
    @ViewBuilder
    private var tunnelProvidedList: some View {
        if client.tunnelProvidedDNS.isEmpty {
            Text(L("ui.network.tunnelNone"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(client.tunnelProvidedDNS, id: \.self) { server in
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text(server).font(.system(.body, design: .monospaced))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Editable custom upstream list
    private var customUpstreamList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if client.customUpstream.isEmpty {
                Text(L("ui.network.notConfigured"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(client.customUpstream, id: \.self) { server in
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        Text(server).font(.system(.body, design: .monospaced))
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            var list = client.customUpstream
                            list.removeAll { $0 == server }
                            if list.isEmpty {
                                client.reportError(L("ui.network.needUpstream"))
                            } else {
                                client.setUpstreamDNS(list)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(L("ui.network.upstreamPlaceholder"), text: $newUpstream)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addUpstream() }
                Button(L("ui.action.add")) { addUpstream() }
                    .disabled(newUpstream.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Route expiry

    private var routeExpiryBox: some View {
        GroupBox(L("ui.network.ttlTitle")) {
            VStack(spacing: 8) {
                HStack {
                    Text(L("ui.network.routeLifetime"))
                        .font(.callout)
                    Spacer()
                    TextField("", text: $ttlInput, prompt: Text(L("ui.network.seconds")))
                        .frame(width: 90)
                        .onSubmit { applyTTL() }
                    Text(L("ui.network.seconds"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L("ui.action.apply")) { applyTTL() }
                        .disabled(ttlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(L("ui.network.ttlRange"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }

    // MARK: - DNS status (running + whether taken over, merged into one line)

    private var dnsStatusText: String {
        guard client.dnsRunning else { return L("ui.status.stopped") }
        return client.dnsActivated ? L("ui.network.dnsTakenOver") : L("ui.status.running")
    }

    private var dnsStatusIcon: String {
        client.dnsRunning ? "checkmark.circle.fill" : "xmark.circle"
    }

    private var dnsStatusColor: Color {
        client.dnsRunning ? .green : .secondary
    }

    private func applyTTL() {
        let trimmed = ttlInput.trimmingCharacters(in: .whitespaces)
        guard let v = Double(trimmed) else {
            client.reportError(L("ui.network.ttlNotNumber"))
            return
        }
        client.setRouteTTL(v)
    }

    private func addUpstream() {
        let trimmed = newUpstream.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = client.customUpstream
        guard !list.contains(trimmed) else {
            newUpstream = ""
            return
        }
        list.append(trimmed)
        client.setUpstreamDNS(list)
        newUpstream = ""
    }
}