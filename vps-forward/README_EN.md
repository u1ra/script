# vps-forward

[中文](README.md) · nftables IPv4 L4 port-forwarding manager

![CI](https://github.com/u1ra/script/actions/workflows/shellcheck.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue)

`vps-forward` is a Bash tool for freshly provisioned VPSes that manages TCP, UDP, or TCP+UDP single-port forwarding from a relay VPS to a destination VPS using its own dedicated nftables tables. A local config file is the single source of truth; every change rebuilds the project's rules through an atomic nftables transaction. It never flushes the global ruleset and never touches tables owned by Docker, UFW, firewalld, Fail2ban, or the user.

> [!CAUTION]
> Firewall changes can disconnect a VPS. Keep the current SSH session open and make sure console access or another emergency login is available before making changes. The software is provided as-is; the authors are not liable for disconnections, data loss, or outages caused by misconfiguration.

## Features

- TCP, UDP, or BOTH; listen on all addresses or a specific local IPv4
- Three Masquerade modes: precise (default), destination-only, or disabled
- Interactive menu (`vpf`) and an automation-friendly CLI with JSON output
- Atomic apply: `flock` locking, candidate files, `nft --check`, automatic backups, rollback on failure
- Independent systemd / OpenRC persistence services, no reliance on `/etc/nftables.conf`
- Read-only `doctor` diagnostics for UFW, firewalld, Docker, Fail2ban, and iptables-nft conflicts
- Backup, restore, import, export, and a conservative uninstaller

Supported systems: Ubuntu and Debian (`apt` + systemd), Alpine Linux (`apk` + OpenRC). The main program requires Bash; on Alpine without Bash, the POSIX `sh` installer bootstraps it.

Only single IPv4 ports are supported in v0.1. Hostnames, IPv6, port ranges, load balancing, transparent proxying, PROXY Protocol, and one-to-many forwarding are out of scope.

## Install

The recommended path is to clone, inspect, then run:

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
less install.sh vps-forward.sh lib/vps-forward-core.sh
sudo ./install.sh && sudo vpf
```

One-liner install (available once the repository is public; it executes network content directly and is only suitable for throwaway environments where you accept that risk):

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | sudo bash' && sudo vpf
```

The installer installs nftables, iproute2, and util-linux, places the program under `/usr/local`, writes a project sysctl file, creates the independent persistence service, and provides two commands: `vpf` (opens the management menu) and `vps-forward` (menu + CLI subcommands). Reinstalling keeps the configuration; when versions differ you can choose upgrade, reinstall, uninstall, or cancel — `--upgrade`, `--reinstall`, `--uninstall-existing`, and `--yes` are available for automation.

For production, download a pinned Release, verify it with the accompanying `.sha256` file, then install. The remote bootstrapper also honors the `VPF_INSTALL_VERSION` and `VPF_SHA256` environment variables.

## Quick start

Forward TCP+UDP `8443` on the relay VPS to the destination VPS (the example uses the documentation-reserved address `192.0.2.10`; replace it with your real IPv4):

```bash
sudo vps-forward add \
  --name edge-to-origin \
  --listen-port 8443 \
  --target-ip 192.0.2.10 \
  --target-port 20086 \
  --protocol both

sudo vps-forward list
sudo vps-forward status
sudo vps-forward doctor
```

Disable Masquerade (the destination VPS must have a correct return route, otherwise asymmetric routing breaks forwarding):

```bash
sudo vps-forward add \
  --name routed-return \
  --listen-port 9443 \
  --target-ip 198.51.100.20 \
  --target-port 443 \
  --protocol tcp \
  --no-masquerade
```

## Interactive menu

Run `sudo vpf` to open the menu. The header summarizes version, system, service state, IPv4 forwarding, configuration, and rule counts. Actions are grouped into rule management, system & diagnostics, and data & maintenance, covering everything the CLI can do. Set `NO_COLOR=1` or `VPF_COLOR=never` to disable colors, or `VPF_COLOR=always` to force them on.

## CLI

| Command | Purpose |
|---|---|
| `install` | Install dependencies, program, sysctl, and persistence service |
| `add [options]` | Add a rule and apply atomically |
| `list [--json]` | List rules |
| `show ID [--json]` | Show one rule |
| `edit ID [options]` | Modify and fully rebuild the project tables |
| `delete ID --yes` | Delete a rule |
| `enable ID` / `disable ID` | Enable/disable; disabled rules stay in the config |
| `apply [--dry-run]` | Regenerate, check, and apply |
| `check` | Validate config and the candidate nftables transaction |
| `status [--json]` | Show system and project status |
| `doctor [--json]` | Read-only checks for common conflicts |
| `rules` | Show the two live project tables |
| `backup` / `restore NAME --yes` | Back up / restore an internal backup |
| `export --output /abs/file` | Export the TSV config |
| `import --input /abs/file --yes` | Validate, back up, import, and apply |
| `uninstall --yes [options]` | Conservative uninstall |
| `help` / `version` | Help / version |

Rule options:

| Option | Values and defaults |
|---|---|
| `--name` | 1–64 letters, digits, spaces, `.`, `_`, `-`; default `forward-ID` |
| `--listen-ip` | IPv4 or `any`; default `any` |
| `--listen-port` | 1–65535, required for add |
| `--target-ip` | IPv4, required for add |
| `--target-port` | 1–65535, required for add |
| `--protocol` | `tcp`, `udp`, `both`; default `both` |
| `--masquerade-mode` | `precise` (default) or `destination` |
| `--no-masquerade` | Disable Masquerade; mutually exclusive with the previous option |
| `--enabled` / `--disabled` | New rules are enabled by default |
| `--dry-run` | Show candidate config, generated rules, and transaction in `/tmp` without touching the system |
| `--yes` | Confirm SSH-port risk or dangerous operations |
| `--quiet` | Reduce non-error output |

TCP and UDP occupy separate protocol spaces: UDP `8443` can coexist with TCP `8443`; BOTH conflicts with any TCP or UDP rule on the same address/port. `any` overlaps with every specific listen address.

## How it works

### Dedicated nftables tables

The config `/etc/vps-forward/config.tsv` is the single source of truth. Every enabled rule generates a DNAT plus a matching FORWARD accept; Masquerade rules are generated per mode:

```text
table ip vps_forward_nat
├── prerouting   (type nat, hook prerouting, priority dstnat): DNAT
└── postrouting  (type nat, hook postrouting, priority srcnat): Masquerade

table inet vps_forward_filter
└── forward      (type filter, hook forward, priority -5): accepts only project DNAT traffic
```

All generated rules carry a `vps-forward id=... name=...` comment and use `ct status dnat` to narrow their scope. The project never runs `flush ruleset`; if a same-named table exists without the project ownership marker, the operation stops immediately.

### Atomic apply

Every change runs under an exclusive `flock`: generate candidate config and complete project tables → verify ownership of existing same-named tables → `nft --check` → automatic backup → apply in a single transaction and verify → on failure, restore the previous project ruleset. There is no intermediate commit with a DNAT but no FORWARD. Automatic backups keep the last 20 by default.

### Three Masquerade modes

1. `precise` (default): matches DNAT status, destination IP, destination port, and protocol. Minimal impact; recommended.
2. `destination`: matches DNAT status and destination IP. Rules sharing a target IP share one generated rule.
3. `none` (`--no-masquerade`): preserves the client source IP, but you must configure the return route yourself.

### Coexisting with other firewalls

In nftables, one hook can host multiple base chains, and an `accept` in one does not guarantee global acceptance. The project only rebuilds its two marked tables and never changes other chains' policy or priority, so UFW, firewalld, or Docker rules can still drop forwarded traffic. `doctor` reports common conflicts but cannot prove arbitrary third-party policy is compatible; if Docker rebuilds its firewall after the project service starts, run `apply` again.

## Files

| Path | Content |
|---|---|
| `/usr/local/sbin/vps-forward` | Main program |
| `/usr/local/lib/vps-forward/` | Core library |
| `/etc/vps-forward/config.tsv` | Single source of truth, mode 0600 |
| `/etc/vps-forward/generated.nft` | Last generated project rules |
| `/etc/vps-forward/backups/` | Internal backups |
| `/etc/vps-forward/lock` | Concurrency lock |
| `/etc/vps-forward/state` | Last apply/backup state |
| `/var/log/vps-forward.log` | Operation log |
| `/etc/sysctl.d/99-vps-forward.conf` | Persistent IPv4 forwarding |

The persistence service calls `apply` after `network-online` and the distribution's nftables service. It fully rebuilds the project tables every time — idempotent, and it never overwrites the distribution's main config file.

## Backup and uninstall

```bash
sudo vps-forward backup
sudo vps-forward restore backup-20260101T000000Z-1234-5678 --yes
sudo vps-forward export --output /root/vps-forward-config.tsv
sudo vps-forward import --input /root/vps-forward-config.tsv --yes
```

Internal backups include the config, generated rules, a manifest, and the service and sysctl files when present. Restore/import validates first, backs up the current state, and runs the nft check.

Uninstall keeps the configuration, backups, the nftables package, the sysctl file, and the IPv4 forwarding state by default:

```bash
sudo vps-forward uninstall --yes --keep-config   # default behavior
sudo vps-forward uninstall --yes --rules-only    # remove only project rules, keep program and service
sudo vps-forward uninstall --yes --purge         # also delete config and backups
# optional extras: --remove-sysctl --remove-package
```

Even when removing the sysctl file, the uninstaller never writes `net.ipv4.ip_forward=0`, to avoid breaking containers, VPNs, or other forwarding services.

## Troubleshooting

1. Run `sudo vps-forward doctor` and `sudo vps-forward check`.
2. Confirm `/proc/sys/net/ipv4/ip_forward` is `1`.
3. Inspect DNAT, FORWARD, and Masquerade with `sudo vps-forward rules`.
4. Check whether the listen port overlaps SSH or other services: `ss -lntup`.
5. Check whether UFW/firewalld/other nftables base chains drop the traffic, plus cloud security groups and upstream ACLs.
6. Without Masquerade, verify the destination VPS return route.
7. Check `/var/log/vps-forward.log` and systemd/OpenRC logs.
8. Audit the candidate transaction with `sudo vps-forward apply --dry-run`.

Port-occupancy detection is only a hint. No UDP listener record does not prove the path is usable; containers, IP-specific binds, and post-check races can all affect the result.

## FAQ

**Why not modify the system `forward` chain?** To avoid changing the global policy or overriding Docker/UFW. The project creates its own base chain and accepts that other chains retain the final veto.

**Why is Masquerade the default?** Most destination VPSes don't know client subnets should return via the relay. Masquerade makes replies naturally return through the relay; the precise mode has the smallest impact.

**Can I preserve the real client IP?** Yes, with `--no-masquerade`, but you must configure the return route on the destination side. DNAT itself does not create that route.

**IPv6 or port ranges?** Not in v0.1. The config schema and generator are already layered, so these can be added later without relying on nft handles.

## Development

```bash
bash -n vps-forward.sh lib/vps-forward-core.sh tests/*.sh
sh -n install.sh
shellcheck vps-forward.sh install.sh uninstall.sh lib/*.sh tests/*.sh
bash tests/run-tests.sh
```

Tests mock nftables in isolated temporary directories and never touch the development machine's firewall. See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [CHANGELOG.md](CHANGELOG.md), and [TODO.md](TODO.md).

## License

[MIT](LICENSE)
