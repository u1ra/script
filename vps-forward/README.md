# vps-forward

[English](README_EN.md) · 基于 nftables 的 IPv4 端口转发管理器

![CI](https://github.com/u1ra/script/actions/workflows/shellcheck.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue)

`vps-forward` 帮你在 VPS 上做端口转发：把发到**中转 VPS**（运行本工具的机器）某个端口的 TCP/UDP 流量，转发到**目标 VPS**（真正提供服务的机器）的指定端口。常用于优化入口线路、隐藏后端地址、统一多个服务的入口等场景。

它用 Bash 写成，规则全部放在自己独立的两张 nftables 表里，由一个配置文件统一管理。每次修改都作为完整事务应用，失败自动回滚；绝不清空系统防火墙，也不碰 Docker、UFW、firewalld、Fail2ban 的规则。

> [!CAUTION]
> 改防火墙可能让 VPS 断连。操作前请保留当前 SSH 会话，并确认 VPS 控制台等应急登录方式可用。本项目按现状提供，作者不对错误配置导致的断连、数据损失或服务中断负责。

## 工作方式一览

```text
客户端 ──► 中转 VPS（本工具）────► 目标 VPS
         监听 8443 端口          转发到 192.0.2.10:20086
```

- 客户端只连接中转 VPS，目标 VPS 的地址对客户端不可见。
- 默认开启 Masquerade（把转发包的源地址改成中转 VPS 自己的地址），目标 VPS 的回包会自然经中转 VPS 返回，目标端不需要任何额外配置；代价是目标端看到的来源 IP 是中转 VPS。需要保留真实客户端 IP 时可用 `--no-masquerade`，但要在目标端自行配置回程路由。

## 功能

- 支持 TCP、UDP 或两者同时转发；可监听全部地址，也可只监听指定的本机 IPv4
- 三种源地址处理模式：精确 Masquerade（默认，推荐）、按目标 IP Masquerade、关闭
- 两种使用方式：交互菜单（`vpf`）和命令行（支持 JSON 输出，方便脚本集成）
- 改坏了自动恢复：修改前自动备份、应用前用 `nft --check` 预检、失败自动回滚
- 开机自动恢复规则：自带独立的 systemd / OpenRC 服务，不依赖发行版的 `/etc/nftables.conf`
- `doctor` 命令只读诊断与 UFW、firewalld、Docker、Fail2ban、iptables-nft 的常见冲突
- 完整的备份、恢复、导入、导出，以及保守的卸载

## 支持系统

- Ubuntu / Debian（`apt` + systemd）
- Alpine Linux（`apk` + OpenRC）

主程序需要 Bash；Alpine 默认没有 Bash，`install.sh` 是 POSIX sh 脚本，会先引导安装。

当前版本只支持 IPv4 单端口转发。域名、IPv6、端口范围、负载均衡、透明代理、PROXY Protocol、一对多转发暂不支持。

## 安装

推荐先克隆、审查脚本、再执行（需要 root 权限且会改防火墙，值得先读一遍）：

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
less install.sh vps-forward.sh lib/vps-forward-core.sh
sudo ./install.sh && sudo vpf
```

一行安装（了解 `curl | bash` 的风险后再用）：

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | sudo bash' && sudo vpf
```

安装器会做的事：安装 nftables、iproute2、util-linux 依赖；把程序装到 `/usr/local`；写入开启 IPv4 转发的 sysctl 配置；创建开机自启的持久化服务。安装后有两个命令可用：

- `vpf`：打开交互管理菜单
- `vps-forward`：同一个程序，提供全部 CLI 子命令

重复安装会保留已有配置；检测到版本不一致时可选择升级、重装、卸载或取消，自动化场景可用 `--upgrade` / `--reinstall` / `--uninstall-existing` / `--yes`。

生产环境建议下载固定版本的 Release，用随附的 `.sha256` 文件校验后再安装；远程安装脚本也支持 `VPF_INSTALL_VERSION` 和 `VPF_SHA256` 环境变量。

## 快速上手

把中转 VPS 的 8443 端口（TCP+UDP）转发到目标 VPS。示例中的 `192.0.2.10` 是文档保留地址，请替换成你的真实 IPv4：

```bash
sudo vps-forward add \
  --name edge-to-origin \
  --listen-port 8443 \
  --target-ip 192.0.2.10 \
  --target-port 20086 \
  --protocol both
```

然后验证：

```bash
sudo vps-forward list     # 查看规则
sudo vps-forward status   # 查看整体状态
sudo vps-forward doctor   # 体检：检查常见防火墙冲突
```

如果想保留客户端真实 IP（关闭 Masquerade）：

```bash
sudo vps-forward add \
  --name routed-return \
  --listen-port 9443 \
  --target-ip 198.51.100.20 \
  --target-port 443 \
  --protocol tcp \
  --no-masquerade
```

注意：关闭 Masquerade 后，目标 VPS 的回包必须经由中转 VPS 返回（正确的回程路由），否则回包走了别的路，转发不通。

## 交互菜单

执行 `sudo vpf` 打开菜单。顶部汇总版本、系统、服务状态、IPv4 转发开关、规则和配置数量；功能按"规则管理""系统与诊断""数据与维护"分组，与 CLI 能力一一对应。

颜色控制：`NO_COLOR=1` 或 `VPF_COLOR=never` 关闭颜色，`VPF_COLOR=always` 强制开启。

## 命令参考

| 命令 | 作用 |
|---|---|
| `install` | 安装依赖、程序、sysctl 配置和持久化服务 |
| `add [参数]` | 新增规则并立即生效 |
| `list [--json]` | 列出全部规则 |
| `show ID [--json]` | 查看一条规则 |
| `edit ID [参数]` | 修改规则并重新应用 |
| `delete ID --yes` | 删除规则 |
| `enable ID` / `disable ID` | 启用 / 禁用规则，禁用后配置仍保留 |
| `apply [--dry-run]` | 按当前配置重新生成并应用规则 |
| `check` | 校验配置文件和将要应用的 nftables 事务 |
| `status [--json]` | 显示系统和项目状态 |
| `doctor [--json]` | 只读检查常见防火墙冲突 |
| `rules` | 查看项目实际生效的两张 nftables 表 |
| `backup` / `restore NAME --yes` | 备份 / 恢复内部备份 |
| `export --output /abs/file` | 导出 TSV 配置 |
| `import --input /abs/file --yes` | 校验、备份、导入并应用 |
| `uninstall --yes [选项]` | 保守卸载 |
| `help` / `version` | 帮助 / 版本 |

规则参数：

| 参数 | 取值与默认值 |
|---|---|
| `--name` | 1～64 个字母、数字、空格、`.`、`_`、`-`；默认 `forward-ID` |
| `--listen-ip` | IPv4 或 `any`；默认 `any` |
| `--listen-port` | 1～65535，新增必填 |
| `--target-ip` | IPv4，新增必填 |
| `--target-port` | 1～65535，新增必填 |
| `--protocol` | `tcp`、`udp`、`both`；默认 `both` |
| `--masquerade-mode` | `precise`（默认）或 `destination` |
| `--no-masquerade` | 关闭 Masquerade，与上一项互斥 |
| `--enabled` / `--disabled` | 新增时默认启用 |
| `--dry-run` | 只在 `/tmp` 生成候选配置和规则供审查，不改系统 |
| `--yes` | 确认 SSH 端口风险或危险操作 |
| `--quiet` | 减少非错误输出 |

端口冲突规则：同一端口号的 TCP 和 UDP 互不冲突（已有 TCP 8443 时仍可加 UDP 8443）；`both` 与同地址同端口的任何 TCP 或 UDP 规则冲突；监听地址 `any` 与所有具体 IP 冲突。

## 工作原理

### 独立的 nftables 表

`/etc/vps-forward/config.tsv` 是唯一配置来源。每条启用的规则生成两部分：一条 DNAT（改写包的目标地址）和一条 FORWARD 放行；Masquerade 按所选模式生成。所有规则集中在项目自己的两张表里：

```text
table ip vps_forward_nat
├── prerouting   (type nat, hook prerouting, priority dstnat): DNAT
└── postrouting  (type nat, hook postrouting, priority srcnat): Masquerade

table inet vps_forward_filter
└── forward      (type filter, hook forward, priority -5): 只放行本工具 DNAT 产生的流量
```

每条生成的规则都带 `vps-forward id=... name=...` 注释便于识别，并用 `ct status dnat` 把匹配范围限制在本工具转发产生的流量上。项目从不执行 `flush ruleset`；如果发现同名表但不是本工具创建的（缺少所有权标记），会立即停手报错，绝不覆盖。

### 原子应用：不会改出一半的状态

每次修改的完整流程：加 `flock` 独占锁防并发 → 生成候选配置和完整规则 → 检查同名表归属 → `nft --check` 预演 → 自动备份当前状态 → 作为单个 nftables 事务整体应用 → 失败则恢复之前的规则。

要么全部生效，要么完全不变，不会出现"DNAT 加了但放行没加"的半成品。自动备份默认保留最近 20 份。

### 三种 Masquerade 模式

Masquerade 会把转发出去的包的源地址改成中转 VPS 自己的地址，这样目标 VPS 的回包自然回到中转 VPS。三种模式的区别只在匹配范围：

1. `precise`（默认，推荐）：按 DNAT 状态 + 目标 IP + 目标端口 + 协议精确匹配，只影响本工具产生的转发流量，影响最小。
2. `destination`：按 DNAT 状态 + 目标 IP 匹配，指向同一目标 IP 的多条规则共用一条生成规则，规则更少但影响面更大。
3. `none`（`--no-masquerade`）：不改源地址，目标端能看到真实客户端 IP，但必须自己配好回程路由。

### 与其他防火墙共存

nftables 允许同一个挂接点（hook）上存在多条 base chain：本工具的链 accept 了，其他链仍然可以 drop。本工具只重建自己带标记的两张表，不动其他链的 policy 和 priority——所以 UFW、firewalld、Docker 的规则仍可能拦截转发流量。`doctor` 能查出常见冲突，但无法穷举任意第三方规则的意图；如果 Docker 在本工具服务启动之后重建了防火墙，再执行一次 `apply` 即可。

## 文件位置

| 路径 | 内容 |
|---|---|
| `/usr/local/sbin/vps-forward` | 主程序 |
| `/usr/local/lib/vps-forward/` | 核心库 |
| `/etc/vps-forward/config.tsv` | 唯一配置源，权限 0600 |
| `/etc/vps-forward/generated.nft` | 最近一次生成的项目规则 |
| `/etc/vps-forward/backups/` | 内部备份 |
| `/etc/vps-forward/lock` | 并发锁 |
| `/etc/vps-forward/state` | 最近一次应用 / 备份的状态 |
| `/var/log/vps-forward.log` | 操作日志 |
| `/etc/sysctl.d/99-vps-forward.conf` | IPv4 转发持久化配置 |

持久化服务在 `network-online` 和发行版 nftables 服务之后运行 `apply`，每次完整重建项目的两张表，幂等，且不覆盖发行版主配置文件。

## 备份与卸载

```bash
sudo vps-forward backup
sudo vps-forward restore backup-20260101T000000Z-1234-5678 --yes
sudo vps-forward export --output /root/vps-forward-config.tsv
sudo vps-forward import --input /root/vps-forward-config.tsv --yes
```

内部备份包含配置、生成的规则、manifest，以及存在时的服务文件和 sysctl 文件；恢复和导入都会先校验、备份当前状态，并通过 nft 检查后才应用。

卸载默认是保守的——保留配置、备份、nftables 软件包、sysctl 文件和 IPv4 转发开关：

```bash
sudo vps-forward uninstall --yes --keep-config   # 默认行为
sudo vps-forward uninstall --yes --rules-only    # 只移除项目规则，保留程序和服务
sudo vps-forward uninstall --yes --purge         # 同时删除配置和备份
# 可选叠加：--remove-sysctl --remove-package
```

即使选择删除 sysctl 文件，卸载也不会把 `net.ipv4.ip_forward` 写回 0——容器、VPN 或其他转发服务可能还在依赖它。

## 故障排查

1. 先跑 `sudo vps-forward doctor` 和 `sudo vps-forward check`。
2. 确认 `/proc/sys/net/ipv4/ip_forward` 的值为 `1`。
3. 用 `sudo vps-forward rules` 检查 DNAT、FORWARD 放行和 Masquerade 是否都生成了。
4. 检查监听端口是否与 SSH 或其他服务冲突：`ss -lntup`。
5. 检查 UFW / firewalld / 其他 nftables base chain 是否 drop 了转发流量，以及云厂商安全组和上游 ACL。
6. 关闭 Masquerade 时，检查目标 VPS 的回程路由。
7. 查看 `/var/log/vps-forward.log` 和 systemd / OpenRC 日志。
8. 用 `sudo vps-forward apply --dry-run` 审查将要应用的事务。

注意：端口占用检测仅供参考。UDP 没有"监听"记录不代表路径可用；容器、绑定特定 IP、检测与生效之间的竞态都可能影响判断。

## 常见问题

**为什么不直接改系统 `forward` 链？** 为了不改变全局 policy，也不覆盖 Docker / UFW 的规则。项目创建自己的 base chain，并接受其他链保有最终否决权。

**为什么默认开 Masquerade？** 多数目标 VPS 不知道该把客户端网段的回包发给中转 VPS。Masquerade 让回包自然回到中转 VPS，目标端零配置；精确模式的影响最小。

**能保留客户端真实 IP 吗？** 可以，用 `--no-masquerade`，但必须在目标端配置回程路由——DNAT 本身不会创建这条路由。

**支持 IPv6 / 端口范围吗？** v0.1 不支持。配置格式和规则生成器是分层设计的，未来可以平滑扩展。

## 开发与测试

```bash
bash -n vps-forward.sh lib/vps-forward-core.sh tests/*.sh
sh -n install.sh
shellcheck vps-forward.sh install.sh uninstall.sh lib/*.sh tests/*.sh
bash tests/run-tests.sh
```

测试在隔离的临时目录中 mock nftables，不会修改开发机的防火墙。参见 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md)、[CHANGELOG.md](CHANGELOG.md) 和 [TODO.md](TODO.md)。

## License

[MIT](LICENSE)
