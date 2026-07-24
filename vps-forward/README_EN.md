# vps-forward

`vps-forward` is a Bash-based nftables IPv4 L4 port-forwarding manager for Ubuntu, Debian, and Alpine Linux. It manages only its own marked tables, never flushes the global ruleset, and treats a versioned TSV file as the source of truth.

> [!CAUTION]
> Firewall changes can disconnect a VPS. Keep the current SSH session open and ensure console access is available. The software is provided as-is; the authors are not liable for outages or loss caused by incorrect configuration.

## Highlights

- TCP, UDP, or both; one IPv4 port per rule
- optional listen IPv4; any local IPv4 by default
- precise (default), destination-only, or disabled Masquerade
- matching DNAT and FORWARD rules
- interactive menu and non-interactive CLI
- atomic candidate generation, `nft --check`, backups, locking, and rollback
- JSON output for `list` and `status`
- independent systemd/OpenRC persistence
- read-only conflict diagnostics for UFW, firewalld, Docker, Fail2ban, and iptables-nft

IPv6, hostnames, port ranges, load balancing, transparent proxying, and PROXY Protocol are not supported in v0.1.

## Install

The recommended path is to clone and inspect the source:

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
less install.sh vps-forward.sh lib/vps-forward-core.sh
sudo ./install.sh
```

Install with Bash and immediately open the interactive menu:

```bash
sudo bash install.sh && sudo vpf
```

For production, use a fixed Release, verify its published SHA256, inspect it, and then run `install.sh`. The convenience command below executes changing network content directly and should only be used if you accept that risk:

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | sudo bash' && sudo vpf
```

On Alpine, the POSIX installer bootstraps Bash before launching the main program.

The installer creates `vpf` as a shortcut that opens the interactive management menu. On repeated installation, equal versions are repaired idempotently. A different version offers upgrade, reinstall, uninstall, or cancel; `--upgrade`, `--reinstall`, `--uninstall-existing`, and `--yes` are available for automation.

## Quick start

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

`192.0.2.0/24` is reserved for documentation. Replace it with the destination VPS address.

Disable source NAT only when the destination has a correct return route:

```bash
sudo vps-forward add --name routed \
  --listen-port 9443 --target-ip 198.51.100.20 --target-port 443 \
  --protocol tcp --no-masquerade
```

## Commands

```text
install
add --listen-port PORT --target-ip IPv4 --target-port PORT [options]
list [--json]
show ID [--json]
edit ID [options]
delete ID --yes
enable ID
disable ID
apply [--dry-run]
check
status [--json]
doctor [--json]
rules
backup
restore BACKUP_NAME --yes
export --output /absolute/file
import --input /absolute/file --yes
uninstall --yes [--rules-only|--keep-config|--purge]
help
version
```

Rule options are `--name`, `--listen-ip IPv4|any`, `--listen-port`, `--target-ip`, `--target-port`, `--protocol tcp|udp|both`, `--masquerade-mode precise|destination`, `--no-masquerade`, `--enabled`, `--disabled`, `--dry-run`, `--yes`, and `--quiet`.

## nftables layout

```text
table ip vps_forward_nat
  prerouting  -> DNAT
  postrouting -> scoped Masquerade

table inet vps_forward_filter
  forward     -> accepts only matching DNAT traffic
```

Every table has the `vps-forward managed table v1` ownership marker. Every managed forwarding rule has an ID/name comment. Existing same-name tables without the marker stop the operation.

Changes are compiled into a transaction that deletes and recreates only those two tables. The transaction is syntax-checked and applied atomically. No code path runs `nft flush ruleset`.

An `accept` verdict in one nftables base chain does not prevent another base chain on the same hook from dropping the packet. Existing UFW, firewalld, Docker, or user policy may therefore block a forwarding rule. `doctor` reports common conflicts but cannot prove arbitrary third-party policy is compatible.

Precise Masquerade matches DNAT status, destination IP, destination port, and protocol and is the safest default. Destination mode matches all project DNAT traffic to the destination IP and is shared by rules with the same target. Disabling Masquerade preserves the client source but requires symmetric return routing.

## Files and persistence

- `/etc/vps-forward/config.tsv`: source of truth
- `/etc/vps-forward/generated.nft`: generated project tables
- `/etc/vps-forward/backups/`: validated backups
- `/etc/vps-forward/state`: last apply/backup
- `/var/log/vps-forward.log`: operation log
- `/etc/sysctl.d/99-vps-forward.conf`: persistent IPv4 forwarding

The independent systemd/OpenRC service calls `vps-forward apply` after networking. It does not replace the distribution's nftables configuration file.

## Backup and uninstall

```bash
sudo vps-forward backup
sudo vps-forward restore backup-YYYYMMDDTHHMMSSZ-PID-RANDOM --yes
sudo vps-forward export --output /root/config.tsv
sudo vps-forward import --input /root/config.tsv --yes
sudo vps-forward uninstall --yes --keep-config
```

Uninstall keeps the configuration, sysctl, IPv4 forwarding state, and nftables package by default. `--purge`, `--remove-sysctl`, and `--remove-package` are explicit opt-ins. Removing the sysctl file never writes `ip_forward=0`.

See the Chinese [README](README.md) for the complete operational and troubleshooting guide.

## Development

```bash
shellcheck vps-forward.sh install.sh uninstall.sh lib/*.sh tests/*.sh
bash tests/run-tests.sh
```

## License

MIT. See [LICENSE](LICENSE).
