# vacuole

A macOS menu bar client for WireGuard with **domain-based split routing**: only the
domains you choose are resolved and routed through the tunnel, while everything else keeps
using your normal network.

## Features

- **Menu bar control** — start/stop the tunnel and switch domain sets from the status bar.
- **Domain sets** — group domains (wildcards supported) into sets and activate one at a time.
- **Transparent DNS proxy** — captures the system's physical DNS, resolves matched domains
  through the tunnel, and forwards the rest to the physical DNS. Configurable upstream DNS.
- **Automatic split routing** — DNS-resolved IPs are aggregated (IPv4 `/24`, IPv6 `/64`) into
  kernel routes that expire by TTL; static CIDR routes can be added per domain set.
- **Self-healing** — stale routes and orphaned tunnel processes are cleaned up on daemon start,
  and the system DNS is restored on stop/exit.
- **Localized UI** — Simplified/Traditional Chinese and English, chosen automatically from the
  system language.

## Routing: why kernel routes and not PF

A pf-based approach was originally used for policy routing. It was dropped: macOS PF gives a poor UDP
experience — every new UDP flow silently loses its first datagram (a kernel-level issue that no
`pf.conf` setting fixes). vacuole instead installs plain host/prefix routes pointing at the tunnel
interface (`route add -net <prefix> -interface utunN`), which is transparent to all applications
and clean for both TCP and UDP.

To mitigate route bloating, Class C routes and route expiration are used.

## Architecture

- **GUI** — a non-privileged menu bar app (SwiftUI + AppKit `NSStatusItem`).
- **Daemon** — a root LaunchDaemon `vacuoled` that performs the privileged work (routes, tunnel,
  DNS). The two communicate over XPC.
- **Tunnel** — uses bundled `wireguard-go` + `wg` directly; `wg-quick` is not used.

## Requirements

- macOS 13 or later.
- `wireguard-go` and `wg` binaries (bundled in the app or available in `/opt/homebrew/bin`).

## Build & Install

```bash
./install.sh     # build (xcodegen + xcodebuild), install to /Applications, register the daemon
./uninstall.sh   # remove the app and unregister the daemon
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
