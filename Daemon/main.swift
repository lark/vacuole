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
import Dispatch
import VacuoleShared

// vacuoled: entry point of the root LaunchDaemon.
// Launched by launchd as root; hosts all privileged network operations (route / wireguard-go / DNS).
let listener = NSXPCListener(machServiceName: VacuoleDaemonConstants.machServiceName)
let delegate = DaemonListener()
listener.delegate = delegate

// Startup fallback 1: clean up routes possibly left by an abnormal exit
// (prevents stale routes pointing at a vanished utun from breaking connectivity).
RouteController.shared.resetStaleState()
// Startup fallback 2: kill leftover wireguard-go processes (their utun interface is
// removed by the kernel on exit), avoiding the stale state where "the app has not
// started a tunnel yet the tunnel interface still exists and targets remain reachable".
WireGuardController.shared.cleanupOrphaned()
// Startup fallback 3: a previous run (crash, forced quit, failed restore) may have left the system
// DNS pointed at 127.0.0.1 with no proxy listening. Put automatic DNS back so the machine is not
// left without working DNS.
SystemDNSManager.shared.restoreIfLeftBehind()

// Graceful-exit fallback: when launchd stops/restarts this daemon (e.g. `launchctl bootout`,
// `kickstart -k`) it sends SIGTERM. Restore system DNS and reclaim routes first, avoiding a
// dangling 127.0.0.1 pointing at a stopped proxy that breaks connectivity.
// Note: ignore SIGTERM's default action first, then hand the signal to DispatchSource.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    LogStore.shared.info("daemon", "Received SIGTERM, restoring system DNS and routes")
    _ = SystemDNSManager.shared.restore()
    RouteController.shared.stop()
    WireGuardController.shared.cleanupOrphaned()
    exit(0)
}
termSource.resume()

listener.resume()
RunLoop.main.run()