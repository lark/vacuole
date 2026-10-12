# vacuole

A macOS menu bar client for WireGuard with **domain-based split routing**: only the
domains you choose are resolved and routed through the tunnel, while everything else keeps
using your normal network.

## Features

- **Menu bar control** — start/stop the tunnel and switch domain sets from the status bar.
- **Domain sets** — group domains into sets and activate one at a time. A bare entry
  (`example.com`) covers the domain and all of its subdomains; `*.example.com` covers subdomains only.
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

## Multi-user behavior

vacuole is designed for a **single-user Mac**:

- **Configurations are not isolated per user.** They live in `/var/db/vacuole` (root-owned, mode 0600)
  and are shared by every account, **including the WireGuard private keys**. Any user who can drive
  the GUI sees the same configs, domain sets and upstream DNS.
- **The tunnel is machine-wide.** It is installed as kernel routes plus a system DNS takeover, so once
  it is up every user and process — including ssh logins — is affected. There is no per-user tunnel.
- **Only root and the current console (GUI) user may talk to the daemon.** Connections from other
  accounts are rejected, which keeps ssh logins from reading private keys or changing routes/DNS.
- **Quitting the GUI tears the tunnel down.** The daemon outlives the GUI, so on quit the tunnel, its
  routes and the DNS takeover are stopped to avoid leaving the machine captured with no way to undo it.

If you need per-user isolation, run vacuole on a machine where every account is trusted, or use a
separate tunnel manager per user.

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
