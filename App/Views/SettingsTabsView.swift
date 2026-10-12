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

/// Consolidated settings window: custom segmented tabs + content area.
///
/// Deliberately does **not** use SwiftUI's `TabView`: on macOS 26 `TabView` draws the tab bar into
/// the window's toolbar/title bar area, overlapping the workspace below (especially noticeable with
/// small windows). Instead we use an explicit vertical layout of "segmented picker + content
/// switch", with the tab bar and content area clearly separated by a `Divider` — controllable and
/// overlap-free.
struct SettingsTabsView: View {

    private enum Tab: String, CaseIterable, Identifiable {
        case tunnel, domainSets, staticRoutes, network, logs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tunnel:       return L("ui.tab.tunnel")
            case .domainSets:   return L("ui.tab.domainSets")
            case .staticRoutes: return L("ui.tab.staticRoutes")
            case .network:      return L("ui.tab.network")
            case .logs:         return L("ui.tab.logs")
            }
        }
    }

    @State private var selection: Tab = .tunnel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch selection {
                case .tunnel:       TunnelTab()
                case .domainSets:   DomainSetsTab()
                case .staticRoutes: StaticRoutesTab()
                case .network:      NetworkTab()
                case .logs:         LogsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

/// Shared metrics for settings panes, so every tab keeps the same outer margin,
/// left-column width and control sizing.
enum SettingsUI {
    /// Margin between a pane's content and the window frame / split divider.
    static let panePadding: CGFloat = 14
    static let leftMinWidth: CGFloat = 180
    static let leftIdealWidth: CGFloat = 220
    static let leftMaxWidth: CGFloat = 320
}

extension View {
    /// Uniform look for action buttons across settings panes (same height and style).
    func settingsActionButton() -> some View {
        self.buttonStyle(.bordered).controlSize(.regular)
    }
}

// TunnelTab is defined in App/Views/TunnelTab.swift
// DomainSetsTab is defined in App/Views/DomainSetsTab.swift
// StaticRoutesTab is defined in App/Views/StaticRoutesTab.swift
// NetworkTab is defined in App/Views/NetworkTab.swift
// LogsTab is defined in App/Views/LogsTab.swift