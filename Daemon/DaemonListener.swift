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
import SystemConfiguration
import VacuoleShared

/// XPC listener delegate: accepts connections from the GUI.
/// Holds a single persistent DaemonService instance so tunnel state survives across connections.
final class DaemonListener: NSObject, NSXPCListenerDelegate {

    private let service = DaemonService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Effective uid of the peer process
        let uid = newConnection.effectiveUserIdentifier
        guard Self.isAuthorized(uid: uid) else {
            LogStore.shared.warn("xpc", "Rejected XPC connection from uid \(uid): only root and the console user may control the daemon")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: VacuoleDaemonProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    /// Configs and routing are system-wide (see README), so access is limited to root and the
    /// current console (locally logged-in GUI) user. This is what keeps other accounts — for
    /// example ssh logins — from reading private keys or changing the machine's routes and DNS.
    private static func isAuthorized(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        var consoleUID: uid_t = 0
        var consoleGID: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) != nil else {
            return false
        }
        // Nobody logged in at the GUI is reported as "loginwindow" with uid 0
        guard consoleUID != 0 else { return false }
        return uid == consoleUID
    }
}