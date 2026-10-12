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

import Foundation
import VacuoleShared

/// In-daemon log storage: a thread-safe ring buffer, pulled by the GUI over XPC.
final class LogStore {

    static let shared = LogStore()

    private var entries: [LogEntry] = []
    private let capacity = 1000
    private let lock = NSLock()

    private init() {}

    func log(_ level: String, _ component: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(LogEntry(timestamp: Date(), level: level, component: component, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        // Also mirror to NSLog for Console.app
        NSLog("[\(component)] \(message)")
    }

    func info(_ component: String, _ message: String)  { log("info", component, message) }
    func warn(_ component: String, _ message: String)  { log("warn", component, message) }
    func error(_ component: String, _ message: String) { log("error", component, message) }

    /// Return the most recent limit entries (oldest first)
    func recent(limit: Int = 300) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(limit))
    }

    func encoded(limit: Int = 300) -> Data? {
        try? JSONEncoder().encode(recent(limit: limit))
    }
}