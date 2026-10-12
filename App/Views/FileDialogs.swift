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
import UniformTypeIdentifiers

/// Native open/save panels.
///
/// SwiftUI's `fileImporter` caches its content-type filter between presentations and cannot select
/// `.conf` files, and the app is not sandboxed so security-scoped access never applies. Talking to
/// AppKit directly and reading the file ourselves is both simpler and predictable.
enum FileDialogs {

    /// A file chosen by the user, together with its UTF-8 text content.
    struct PickedFile {
        let url: URL
        let text: String
    }

    /// Ask the user for a file and return its content.
    /// Returns nil when the user cancels, throws when the file cannot be read as text.
    static func openTextFile(title: String) throws -> PickedFile? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // An empty type list allows any file: WireGuard configs and domain lists come with every
        // kind of name and extension, including none at all.
        panel.allowedContentTypes = []
        // The app runs as an accessory (LSUIElement), so make sure the panel comes to the front
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return PickedFile(url: url, text: try String(contentsOf: url, encoding: .utf8))
    }

    /// Ask where to save and write `content` there.
    /// Returns normally when the user cancels, throws when the file cannot be written.
    static func saveTextFile(title: String, suggestedName: String, content: String) throws {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        // The app runs as an accessory (LSUIElement), so make sure the panel comes to the front
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}