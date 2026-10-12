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

/// Static Routes Tab: add/remove static CIDRs + read-only view of DNS-hit aggregated routes
struct StaticRoutesTab: View {
    @ObservedObject private var client = DaemonClient.shared
    @State private var newCIDR: String = ""
    @State private var cidrError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Split routing status
            HStack {
                Image(systemName: client.routingActive ? "checkmark.shield.fill" : "xmark.shield")
                    .foregroundStyle(client.routingActive ? .green : .secondary)
                Text(client.routingActive ? L("ui.routes.splittingActive") : L("ui.routes.splittingInactive"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("ui.action.refresh")) { client.refreshRoutes() }
            }

            // Static CIDR management
            GroupBox(L("ui.routes.staticTitle")) {
                VStack(spacing: 8) {
                    HStack {
                        TextField(L("ui.routes.cidrPlaceholder"), text: $newCIDR)
                            .textFieldStyle(.roundedBorder)
                        Button(L("ui.action.add")) {
                            let trimmed = newCIDR.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            if isValidCIDR(trimmed) {
                                client.addStaticRoute(trimmed)
                                newCIDR = ""
                                cidrError = nil
                            } else {
                                cidrError = L("ui.routes.invalidCIDR")
                            }
                        }
                        .disabled(newCIDR.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let err = cidrError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    List {
                        ForEach(client.staticRoutes, id: \.self) { cidr in
                            HStack {
                                Image(systemName: "arrow.triangle.branch")
                                    .foregroundStyle(.blue)
                                Text(cidr).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) {
                                    client.removeStaticRoute(cidr)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 100)
                }
                .padding(8)
            }

            // Read-only view of issued aggregated routes
            GroupBox(L("ui.routes.issuedTitle")) {
                VStack(spacing: 8) {
                    if client.resolvedRoutes.isEmpty {
                        Text(L("ui.routes.issuedEmpty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        List {
                            ForEach(client.resolvedRoutes, id: \.self) { route in
                                HStack {
                                    Image(systemName: "globe")
                                        .foregroundStyle(.purple)
                                    Text(route).font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 100)
                    }
                }
                .padding(8)
            }

            Spacer(minLength: 0)
        }
        .padding(SettingsUI.panePadding)
        .onAppear { client.refreshRoutes() }
    }

    private func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 128 else {
            return false
        }
        return true
    }
}