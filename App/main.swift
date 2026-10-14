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
import VacuoleShared

// App entry point (Swift top-level code; only main.swift is treated as the executable entry).
// Menu bar app: no Dock icon, no main window; LSUIElement=true already ensures this, set explicitly here too.

// macOS 26 (Tahoe) injects an icon of its own choosing into menu items it recognises, which left our
// otherwise icon-free status menu with a stray gear next to "Open Settings". Registering the
// (undocumented) system switch in our own defaults domain opts out for this app only — no
// system-wide preference is touched, and an explicit user setting still takes precedence.
UserDefaults.standard.register(defaults: ["NSMenuEnableActionImages": false])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()