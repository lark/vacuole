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

/// Static Routes Tab: manual static CIDRs (left) + DNS-issued aggregated routes (right).
/// Both panes scroll independently; hovering an issued route reveals which domains
/// pulled it in and when.
struct StaticRoutesTab: View {
    @ObservedObject private var client = DaemonClient.shared

    // Left pane
    @State private var newCIDR: String = ""
    @State private var cidrError: String?

    // Right pane
    @State private var routeQuery: String = ""
    /// Route whose origin popover is on screen (shown while the pointer is over its row)
    @State private var hoveredRoute: ResolvedRouteInfo?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

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
                Button {
                    client.refreshRoutes()
                } label: {
                    SettingsActionLabel(title: L("ui.action.refresh"), systemImage: "arrow.clockwise")
                }
                .settingsActionButton()
            }

            HSplitView {
                staticPane
                issuedPane
            }
        }
        .padding(SettingsUI.panePadding)
        .onAppear { client.refreshRoutes() }
    }

    // MARK: - Left: manual static CIDRs

    private var staticPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("ui.routes.staticTitle"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(client.staticRoutes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField(L("ui.routes.cidrPlaceholder"), text: $newCIDR)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCIDR() }
                Button(L("ui.action.add")) { addCIDR() }
                    .disabled(newCIDR.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let err = cidrError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            if client.staticRoutes.isEmpty {
                Text(L("ui.routes.staticEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .frame(maxHeight: .infinity)
        }
        // Keep the list and counters clear of the split divider
        .padding(.trailing, SettingsUI.panePadding)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
    }

    // MARK: - Right: issued routes

    private var issuedPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("ui.routes.issuedTitle"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !client.resolvedRoutes.isEmpty {
                    Text(L("ui.routes.searchCount", filteredRoutes.count, client.resolvedRoutes.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("ui.routes.searchPlaceholder"), text: $routeQuery)
                    .textFieldStyle(.roundedBorder)
            }

            if client.resolvedRoutes.isEmpty {
                Text(L("ui.routes.issuedEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if filteredRoutes.isEmpty {
                Text(L("ui.routes.noMatch"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                List(filteredRoutes) { route in
                    routeRow(route)
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }

            Text(L("ui.routes.hoverHint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, SettingsUI.panePadding)
        .frame(minWidth: 360)
    }

    private var filteredRoutes: [ResolvedRouteInfo] {
        let q = routeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return client.resolvedRoutes }
        // Match the prefix itself, or any domain that pulled a route in
        return client.resolvedRoutes.filter { route in
            route.dest.lowercased().contains(q)
                || route.origins.contains { $0.domain.lowercased().contains(q) }
        }
    }

    private func routeRow(_ route: ResolvedRouteInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.purple)
            // The origin domain is intentionally not shown inline: it is often long enough to wrap the row.
            // Hovering for a few seconds reveals every origin domain with its timestamp instead.
            Text(route.dest)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let expires = route.expiresAt {
                Text(Self.timeFormatter.string(from: expires))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredRoute = route
            } else if hoveredRoute?.dest == route.dest {
                hoveredRoute = nil
            }
        }
        .popover(isPresented: originPopoverBinding(for: route), arrowEdge: .trailing) {
            originDetail(route)
        }
    }

    /// The origin panel shown while hovering: which domains added the route, and when
    private func originDetail(_ route: ResolvedRouteInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(route.dest)
                .font(.system(.body, design: .monospaced))
            Divider()
            Text(L("ui.routes.originsTitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if route.origins.isEmpty {
                Text(L("ui.routes.originUnknown"))
                    .font(.caption)
            } else {
                ForEach(route.origins, id: \.domain) { origin in
                    HStack(spacing: 12) {
                        Text(origin.domain)
                            .font(.system(.caption, design: .monospaced))
                        Spacer(minLength: 0)
                        Text(Self.timeFormatter.string(from: origin.addedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let expires = route.expiresAt {
                Divider()
                Text(L("ui.routes.expiresAt", Self.timeFormatter.string(from: expires)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minWidth: 240)
    }

    private func originPopoverBinding(for route: ResolvedRouteInfo) -> Binding<Bool> {
        Binding(
            get: { hoveredRoute?.dest == route.dest },
            set: { shown in
                if !shown, hoveredRoute?.dest == route.dest { hoveredRoute = nil }
            }
        )
    }

    // MARK: - Actions

    private func addCIDR() {
        let trimmed = newCIDR.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard isValidCIDR(trimmed) else {
            cidrError = L("ui.routes.invalidCIDR")
            return
        }
        client.addStaticRoute(trimmed)
        newCIDR = ""
        cidrError = nil
    }

    private func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 128 else {
            return false
        }
        return true
    }
}