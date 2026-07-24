# vps-forward

[中文](README.md) · nftables IPv4 port-forwarding manager

![CI](https://github.com/u1ra/script/actions/workflows/shellcheck.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue)

`vps-forward` sets up port forwarding on a VPS: traffic arriving at a TCP/UDP port on the **relay VPS** (the machine running this tool) is forwarded to a given port on the **destination VPS** (the machine actually running the service). Typical uses: optimizing the entry route, hiding the backend address, or funneling several services through one entry point.

It is written in Bash. All rules live in two dedicated nftables tables owned by the tool and are managed from a single config file. Every change is applied as one complete transaction with automatic rollback on failure; the tool never flushes the system firewall and never touches tables owned by Docker, UFW, firewalld, or Fail2ban.

> [!CAUTION]
> Firewall changes can disconnect a VPS. Keep the current SSH session open and make sure console access or another emergency login is available before making changes. The software is provided as-is; the authors are not liable for disconnections, data loss, or outages caused by misconfiguration.

## How it works at a glance

```text
client ──► relay VPS (this tool) ──────► destination VPS
           listens on port 8443        forwards to 192.0.2.10:20086
```

- Clients only ever connect to the relay VPS; the destination VPS address stays invisible to them.
- Masquerade is on by default: the source address of forwarded packets is rewritten to the relay's own address, so replies from the destination naturally return via the relay with zero configuration on the destination side. The trade-off is that the destination sees the relay's IP as the client. To preserve real client IPs, use `--no-masquerade` — but then you must configure the return route on the destination yourself.

## Features

- Forward TCP, UDP, or both; listen on all addresses or one specific local IPv4
- Three source-address modes: precise Masquerade (default, recommended), per-destination-IP Masquerade, or off
- Two interfaces: an interactive menu (`vpf`) and a CLI with JSON output for scripting
- Self-healing changes: automatic backup before each change, `nft --check` preflight, automatic rollback on failure
- Rules restored on boot: dedicated systemd / OpenRC service, no reliance on the distribution's `/etc/nftables.conf`
- `doctor` command: read-only diagnostics for common conflicts with UFW, firewalld, Docker, Fail2ban, and iptables-nft
- Full backup, restore, import, export, and a conservative uninstaller

## Supported systems

- Ubuntu / Debian (`apt` + systemd)
- Alpine Linux (`apk` + OpenRC)

The main program requires Bash; Alpine has no Bash by default, so `install.sh` is a POSIX sh script that bootstraps it.

v0.1 forwards single IPv4 ports only. Hostnames, IPv6, port ranges, load balancing, transparent proxying, PROXY Protocol, and one-to-many forwarding are not supported.

## Install

Recommended: clone, read the scripts, then run (they need root and modify the firewall — worth a look first):

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
less install.sh vps-forward.sh lib/vps-forward-core.sh
sudo ./install.sh && sudo vpf
```

One-liner install (only if you understand the risks of `curl | bash`):

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | sudo bash' && sudo vpf
```

What the installer does: installs the nftables, iproute2, and util-linux dependencies; places the program under `/usr/local`; writes the sysctl config that enables IPv4 forwarding; creates the boot-time persistence service. Afterwards two commands are available:

- `vpf`: opens the interactive management menu
- `vps-forward`: the same program with all CLI subcommands

Reinstalling keeps your configuration. When versions differ you can choose upgrade, reinstall, uninstall, or cancel — `--upgrade`, `--reinstall`, `--uninstall-existing`, and `--yes` are available for automation.

For production, download a pinned Release, verify it against the accompanying `.sha256` file, then install. The remote bootstrap script also honors the `VPF_INSTALL_VERSION` and `VPF_SHA256` environment variables.

## Quick start

Forward TCP+UDP port 8443 on the relay VPS to the destination VPS. The example IP `192.0.2.10` is a documentation-reserved address — replace it with your real IPv4:

```bash
sudo vps-forward add \
  --name edge-to-origin \
  --listen-port 8443 \
  --target-ip 192.0.2.10 \
  --target-port 20086 \
  --protocol both
```

Then verify:

```bash
sudo vps-forward list     # show rules
sudo vps-forward status   # overall status
sudo vps-forward doctor   # health check: common firewall conflicts
```

To preserve real client IPs (Masquerade off):

```bash
sudo vps-forward add \
  --name routed-return \
  --listen-port 9443 \
  --target-ip 198.51.100.20 \
  --target-port 443 \
  --protocol tcp \
  --no-masquerade
```

Note: with Masquerade off, replies from the destination VPS must route back through the relay VPS. Otherwise replies take a different path (asymmetric routing) and forwarding breaks.

## Interactive menu

Run `sudo vpf`. The header summarizes version, system, service state, the IPv4 forwarding switch, and rule/config counts. Actions are grouped into rule management, system & diagnostics, and data & maintenance — everything the CLI can do.

Colors: set `NO_COLOR=1` or `VPF_COLOR=never` to disable, `VPF_COLOR=always` to force on.

## Command reference

| Command | Purpose |
|---|---|
| `install` | Install dependencies, program, sysctl config, and persistence service |
| `add [options]` | Add a rule and apply it immediately |
| `list [--json]` | List all rules |
| `show ID [--json]` | Show one rule |
| `edit ID [options]` | Modify a rule and re-apply |
| `delete ID --yes` | Delete a rule |
| `enable ID` / `disable ID` | Enable/disable; disabled rules stay in the config |
| `apply [--dry-run]` | Regenerate and apply rules from the current config |
| `check` | Validate the config and the nftables transaction that would be applied |
| `status [--json]` | Show system and project status |
| `doctor [--json]` | Read-only checks for common firewall conflicts |
| `rules` | Show the project's two live nftables tables |
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
| `--dry-run` | Only generate candidate config and rules in `/tmp` for review; does not touch the system |
| `--yes` | Confirm SSH-port risk or dangerous operations |
| `--quiet` | Reduce non-error output |

Port-conflict rules: the same port number can be used once for TCP and once for UDP (UDP 8443 is fine alongside TCP 8443); `both` conflicts with any TCP or UDP rule on the same address/port; a listen address of `any` conflicts with every specific IP.

## How it works

### Dedicated nftables tables

`/etc/vps-forward/config.tsv` is the single source of truth. Each enabled rule generates two things: a DNAT (rewrites the packet's destination) and a FORWARD accept; Masquerade rules depend on the selected mode. Everything lives in two tables owned by the project:

```text
table ip vps_forward_nat
├── prerouting   (type nat, hook prerouting, priority dstnat): DNAT
└── postrouting  (type nat, hook postrouting, priority srcnat): Masquerade

table inet vps_forward_filter
└── forward      (type filter, hook forward, priority -5): accepts only this tool's DNAT traffic
```

Every generated rule carries a `vps-forward id=... name=...` comment for identification and uses `ct status dnat` to limit matching to traffic this tool actually forwards. The project never runs `flush ruleset`; if a same-named table exists without the project's ownership marker, the operation stops with an error instead of overwriting it.

### Atomic apply: never a half-applied state

Every change follows the same pipeline: take an exclusive `flock` to prevent concurrency → generate candidate config and complete rules → verify ownership of same-named tables → preflight with `nft --check` → back up the current state → apply as a single nftables transaction → on failure, restore the previous rules.

Either everything takes effect or nothing does — never "DNAT added but the accept rule missing". Automatic backups keep the last 20 by default.

### Three Masquerade modes

Masquerade rewrites the source address of forwarded packets to the relay's own address, so destination replies naturally return to the relay. The three modes differ only in how broadly they match:

1. `precise` (default, recommended): matches DNAT status + destination IP + destination port + protocol. Affects only this tool's forwarded traffic — minimal impact.
2. `destination`: matches DNAT status + destination IP. Rules pointing at the same destination IP share one generated rule — fewer rules, broader effect.
3. `none` (`--no-masquerade`): no source rewriting, so the destination sees real client IPs — but you must configure the return route yourself.

### Coexisting with other firewalls

nftables allows multiple base chains on the same hook: an `accept` in this tool's chain does not stop another chain from dropping the packet. The tool only rebuilds its two marked tables and never changes other chains' policy or priority — so UFW, firewalld, or Docker rules can still block forwarded traffic. `doctor` catches common conflicts but cannot prove arbitrary third-party policy is compatible; if Docker rebuilds its firewall after the project service started, run `apply` again.

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
| `/etc/sysctl.d/99-vps-forward.conf` | Persistent IPv4 forwarding config |

The persistence service runs `apply` after `network-online` and the distribution's nftables service. It fully rebuilds the project's two tables every time — idempotent, and it never overwrites the distribution's main config file.

## Backup and uninstall

```bash
sudo vps-forward backup
sudo vps-forward restore backup-20260101T000000Z-1234-5678 --yes
sudo vps-forward export --output /root/vps-forward-config.tsv
sudo vps-forward import --input /root/vps-forward-config.tsv --yes
```

Internal backups contain the config, generated rules, a manifest, and the service and sysctl files when present. Restore and import validate first, back up the current state, and pass the nft check before applying.

Uninstall is conservative by default — it keeps the configuration, backups, the nftables package, the sysctl file, and the IPv4 forwarding switch:

```bash
sudo vps-forward uninstall --yes --keep-config   # default behavior
sudo vps-forward uninstall --yes --rules-only    # remove only project rules, keep program and service
sudo vps-forward uninstall --yes --purge         # also delete config and backups
# optional extras: --remove-sysctl --remove-package
```

Even when the sysctl file is removed, the uninstaller never writes `net.ipv4.ip_forward=0` — containers, VPNs, or other forwarding services may still depend on it.

## Troubleshooting

1. Start with `sudo vps-forward doctor` and `sudo vps-forward check`.
2. Confirm `/proc/sys/net/ipv4/ip_forward` is `1`.
3. Use `sudo vps-forward rules` to verify the DNAT, FORWARD accept, and Masquerade rules were all generated.
4. Check whether the listen port collides with SSH or other services: `ss -lntup`.
5. Check whether UFW / firewalld / other nftables base chains drop the forwarded traffic, plus cloud security groups and upstream ACLs.
6. With Masquerade off, verify the destination VPS return route.
7. Read `/var/log/vps-forward.log` and the systemd / OpenRC logs.
8. Review the transaction that would be applied with `sudo vps-forward apply --dry-run`.

Note: port-occupancy detection is only a hint. No UDP "listener" record does not prove the path is usable; containers, IP-specific binds, and races between check and apply can all skew the result.

## FAQ

**Why not just modify the system `forward` chain?** To avoid changing the global policy or overriding Docker/UFW rules. The project creates its own base chain and accepts that other chains keep the final veto.

**Why is Masquerade on by default?** Most destination VPSes don't know that client subnets should return via the relay. Masquerade makes replies naturally come back through the relay with zero destination-side setup; the precise mode has the smallest impact.

**Can I preserve real client IPs?** Yes, with `--no-masquerade` — but you must configure the return route on the destination. DNAT itself does not create that route.

**IPv6 or port ranges?** Not in v0.1. The config format and rule generator are layered, so these can be added later without breaking changes.

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
