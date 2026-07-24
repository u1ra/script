# vps-forward

[English](README_EN.md) · nftables IPv4 四层端口转发管理器

![CI](https://github.com/u1ra/script/actions/workflows/shellcheck.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue)

`vps-forward` 是面向新装 VPS 的 Bash 工具，用独立 nftables 表管理"线路 VPS → 落地 VPS"的 TCP、UDP 或 TCP+UDP 单端口转发。它以本地配置为唯一数据源，每次通过原子 nftables 事务重建自己的规则，不清空 ruleset，也不修改 Docker、UFW、firewalld、Fail2ban 或用户的表。

> [!CAUTION]
> 修改防火墙可能让 VPS 断连。操作前请保留当前 SSH 会话，并确认 VPS 控制台或其他应急登录方式可用。本项目按现状提供；作者不对错误配置导致的断连、数据损失或服务中断负责。

## 功能

- TCP、UDP、BOTH；监听全部地址或指定本机 IPv4
- 精确（默认）、目标 IP、关闭三种 Masquerade 模式
- 交互菜单（`vpf`）与适合自动化的 CLI，支持 JSON 输出
- 原子应用：`flock` 锁、候选文件、`nft --check`、自动备份、失败回滚
- 独立 systemd / OpenRC 持久化服务，不依赖 `/etc/nftables.conf`
- doctor 只读诊断 UFW、firewalld、Docker、Fail2ban、iptables-nft 冲突
- 备份、恢复、导入、导出及保守卸载

支持系统：Ubuntu、Debian（`apt` + systemd）、Alpine Linux（`apk` + OpenRC）。主程序要求 Bash；Alpine 没有 Bash 时可用 POSIX `sh` 运行 `install.sh` 引导安装。

当前版本只支持 IPv4 单端口。域名、IPv6、端口范围、负载均衡、透明代理、PROXY Protocol 和一对多转发不在 v0.1 范围内。

## 安装

推荐克隆、审查、再执行：

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
less install.sh vps-forward.sh lib/vps-forward-core.sh
sudo ./install.sh && sudo vpf
```

一键安装（仓库公开后可用，会直接执行网络内容，只适合了解风险的临时环境）：

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | sudo bash' && sudo vpf
```

安装器会安装 nftables、iproute2 和 util-linux，将程序装到 `/usr/local`，写入项目 sysctl 文件，创建独立持久化服务，并提供两个命令：`vpf`（打开管理菜单）和 `vps-forward`（菜单 + CLI 子命令）。重复安装会保留配置；版本不一致时可选择升级、重装、卸载或取消，自动化环境可用 `--upgrade` / `--reinstall` / `--uninstall-existing` / `--yes`。

生产环境建议下载固定 Release 并用随附的 `.sha256` 文件校验后再安装；远程引导器也支持 `VPF_INSTALL_VERSION` 和 `VPF_SHA256` 环境变量。

## 快速开始

将线路 VPS 的 TCP+UDP `8443` 转发到落地 VPS（示例使用文档保留地址 `192.0.2.10`，请替换为你的实际 IPv4）：

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

关闭 Masquerade（落地 VPS 必须有正确回程路由，否则非对称路由会使转发失败）：

```bash
sudo vps-forward add \
  --name routed-return \
  --listen-port 9443 \
  --target-ip 198.51.100.20 \
  --target-port 443 \
  --protocol tcp \
  --no-masquerade
```

## 交互菜单

运行 `sudo vpf` 打开菜单。顶部汇总版本、系统、服务、IPv4 转发、配置和规则数量，功能按"规则管理""系统与诊断""数据与维护"分组，覆盖 CLI 的全部能力。设置 `NO_COLOR=1` 或 `VPF_COLOR=never` 关闭颜色，`VPF_COLOR=always` 强制开启。

## 命令行

| 命令 | 作用 |
|---|---|
| `install` | 安装依赖、程序、sysctl 和持久化服务 |
| `add [参数]` | 新增并原子应用规则 |
| `list [--json]` | 列出规则 |
| `show ID [--json]` | 查看一条规则 |
| `edit ID [参数]` | 修改并完整重建项目表 |
| `delete ID --yes` | 删除规则 |
| `enable ID` / `disable ID` | 启用/禁用，禁用后配置仍保留 |
| `apply [--dry-run]` | 重新生成、检查并应用 |
| `check` | 校验配置和 nftables 候选事务 |
| `status [--json]` | 显示系统和项目状态 |
| `doctor [--json]` | 只读检查常见冲突 |
| `rules` | 查看两个项目实际表 |
| `backup` / `restore NAME --yes` | 备份 / 恢复内部备份 |
| `export --output /abs/file` | 导出 TSV 配置 |
| `import --input /abs/file --yes` | 校验、备份、导入并应用 |
| `uninstall --yes [选项]` | 保守卸载 |
| `help` / `version` | 帮助 / 版本 |

规则参数：

| 参数 | 值与默认值 |
|---|---|
| `--name` | 1～64 个字母、数字、空格、`.`、`_`、`-`；默认 `forward-ID` |
| `--listen-ip` | IPv4 或 `any`；默认 `any` |
| `--listen-port` | 1～65535，新增必填 |
| `--target-ip` | IPv4，新增必填 |
| `--target-port` | 1～65535，新增必填 |
| `--protocol` | `tcp`、`udp`、`both`；默认 `both` |
| `--masquerade-mode` | `precise`（默认）或 `destination` |
| `--no-masquerade` | 关闭 Masquerade，不能与上一项同时使用 |
| `--enabled` / `--disabled` | 新增时默认启用 |
| `--dry-run` | 在 `/tmp` 显示候选配置、生成规则和事务，不写系统 |
| `--yes` | 确认 SSH 端口风险或危险操作 |
| `--quiet` | 减少非错误输出 |

TCP 和 UDP 分别占用协议空间：已有 TCP `8443` 时可新增 UDP `8443`；BOTH 与同地址/端口上的任一 TCP 或 UDP 规则冲突。`any` 与所有具体监听地址重叠。

## 工作原理

### 独立的 nftables 表

配置 `/etc/vps-forward/config.tsv` 是唯一数据源。启用的每条规则生成 DNAT 和对应 FORWARD 放行，Masquerade 按模式生成：

```text
table ip vps_forward_nat
├── prerouting   (type nat, hook prerouting, priority dstnat): DNAT
└── postrouting  (type nat, hook postrouting, priority srcnat): Masquerade

table inet vps_forward_filter
└── forward      (type filter, hook forward, priority -5): 仅项目 DNAT 流量的放行
```

所有生成规则带 `vps-forward id=... name=...` comment，并用 `ct status dnat` 缩小影响范围。项目绝不执行 `flush ruleset`；如果同名表存在却没有项目所有权标记，操作立即停止。

### 原子应用

每次修改都在 `flock` 独占锁下完成：生成候选配置和完整项目表 → 验证同名表所有权 → `nft --check` → 自动备份 → 单事务应用并验证 → 失败则恢复之前的项目 ruleset。不会出现只有 DNAT 没有 FORWARD 的中间提交。自动备份默认保留最近 20 份。

### 三种 Masquerade

1. `precise`（默认）：按 DNAT 状态、目标 IP、目标端口和协议匹配，影响最小，推荐。
2. `destination`：按 DNAT 状态和目标 IP 匹配，同一目标 IP 的多条规则共享一条生成规则。
3. `none`（`--no-masquerade`）：保留客户端源 IP，但必须自行配置回程路由。

### 与其他防火墙共存

nftables 中同一个 hook 可有多个 base chain，其中一个的 `accept` 不保证流量最终被全局接受。项目只重建带标记的两个表，不改变其他 chain 的 policy 或 priority，因此 UFW、firewalld、Docker 的规则仍可能 drop 转发流量。`doctor` 能报告常见冲突，但无法理解任意第三方规则的完整意图；Docker 在项目服务启动后重建防火墙时可再次 `apply`。

## 文件位置

| 路径 | 内容 |
|---|---|
| `/usr/local/sbin/vps-forward` | 主程序 |
| `/usr/local/lib/vps-forward/` | 核心库 |
| `/etc/vps-forward/config.tsv` | 唯一配置源，0600 |
| `/etc/vps-forward/generated.nft` | 最近生成的项目规则 |
| `/etc/vps-forward/backups/` | 内部备份 |
| `/etc/vps-forward/lock` | 并发锁 |
| `/etc/vps-forward/state` | 最近应用/备份状态 |
| `/var/log/vps-forward.log` | 操作结果日志 |
| `/etc/sysctl.d/99-vps-forward.conf` | IPv4 转发持久化 |

持久化服务在 `network-online` 和发行版 nftables 服务之后调用 `apply`，每次完整重建项目表，幂等且不覆盖发行版主配置文件。

## 备份与卸载

```bash
sudo vps-forward backup
sudo vps-forward restore backup-20260101T000000Z-1234-5678 --yes
sudo vps-forward export --output /root/vps-forward-config.tsv
sudo vps-forward import --input /root/vps-forward-config.tsv --yes
```

内部备份含配置、生成规则、manifest 以及存在时的服务和 sysctl 文件；恢复/导入先校验、备份当前状态、执行 nft 检查。

卸载默认保留配置、备份、nftables 软件包、sysctl 文件和 IPv4 转发状态：

```bash
sudo vps-forward uninstall --yes --keep-config   # 默认行为
sudo vps-forward uninstall --yes --rules-only    # 只移除项目规则，保留程序和服务
sudo vps-forward uninstall --yes --purge         # 同时删除配置和备份
# 可选叠加：--remove-sysctl --remove-package
```

即使删除 sysctl 文件，也不会主动写入 `net.ipv4.ip_forward=0`，避免影响容器、VPN 或其他转发服务。

## 故障排查

1. 运行 `sudo vps-forward doctor` 和 `sudo vps-forward check`。
2. 确认 `/proc/sys/net/ipv4/ip_forward` 为 `1`。
3. 用 `sudo vps-forward rules` 检查 DNAT、FORWARD、Masquerade。
4. 检查监听端口是否与 SSH/其他服务重叠：`ss -lntup`。
5. 检查 UFW/firewalld/其他 nftables base chain 是否 drop，以及云厂商安全组和上游 ACL。
6. 无 Masquerade 时检查落地 VPS 回程路由。
7. 检查 `/var/log/vps-forward.log` 和 systemd/OpenRC 日志。
8. 使用 `sudo vps-forward apply --dry-run` 审计候选事务。

端口占用检测只是提示。UDP 没有监听记录不代表路径可用，容器、绑定特定 IP 和检测后的竞态也可能影响结果。

## 常见问题

**为什么不修改系统 `forward` 链？** 为了不改变系统全局 policy 或覆盖 Docker/UFW。项目创建自己的 base chain，并接受其他链仍有最终否决权。

**为什么默认 Masquerade？** 多数落地 VPS 不知道客户端网段应经线路 VPS 返回。Masquerade 让回包自然回到线路 VPS；精确模式的影响最小。

**能保留客户端真实 IP 吗？** 可用 `--no-masquerade`，但必须在落地端配置回程路由。DNAT 本身不会创建该路由。

**支持 IPv6/端口范围吗？** v0.1 不支持。配置 schema 和生成器已分层，未来可在不使用 nft handle 的前提下扩展。

## 开发与测试

```bash
bash -n vps-forward.sh lib/vps-forward-core.sh tests/*.sh
sh -n install.sh
shellcheck vps-forward.sh install.sh uninstall.sh lib/*.sh tests/*.sh
bash tests/run-tests.sh
```

测试在隔离临时目录中 mock nftables，不会修改开发机防火墙。参见 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md)、[CHANGELOG.md](CHANGELOG.md) 和 [TODO.md](TODO.md)。

## License

[MIT](LICENSE)
