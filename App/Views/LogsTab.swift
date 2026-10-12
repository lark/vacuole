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

/// Status / Logs Tab: daemon log display
struct LogsTab: View {
    @ObservedObject private var client = DaemonClient.shared
    @State private var autoRefresh = false
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text(L("ui.logs.title", client.logs.count))
                    .font(.headline)
                Spacer()
                Toggle(L("ui.logs.autoRefresh"), isOn: $autoRefresh)
                    .toggleStyle(.switch)
                Button {
                    client.refreshLogs()
                } label: {
                    Label(L("ui.action.refresh"), systemImage: "arrow.clockwise")
                }
                .settingsActionButton()
            }
            .padding(SettingsUI.panePadding)

            Divider()

            if client.logs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(L("ui.logs.empty")).font(.title2)
                    Text(L("ui.logs.emptyHint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(client.logs) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(Self.timeFormatter.string(from: entry.timestamp))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: Self.icon(for: entry.level))
                                        .font(.caption2)
                                        .foregroundStyle(Self.color(for: entry.level))
                                    Text("[\(entry.component)]")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.blue)
                                    Text(entry.message)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Self.color(for: entry.level).opacity(0.06))
                                .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: client.logs.count) { _ in
                        // Auto-scroll to bottom
                        if let last = client.logs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear {
            client.refreshLogs()
            if autoRefresh { startTimer() }
        }
        .onDisappear { refreshTimer?.invalidate(); refreshTimer = nil }
        .onChange(of: autoRefresh) { on in
            if on { startTimer() } else { refreshTimer?.invalidate(); refreshTimer = nil }
        }
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in client.refreshLogs() }
        }
        refreshTimer = timer
    }

    private static func icon(for level: String) -> String {
        switch level {
        case "error": return "exclamationmark.triangle.fill"
        case "warn": return "exclamationmark.circle"
        default: return "info.circle"
        }
    }

    private static func color(for level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        default: return .green
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}