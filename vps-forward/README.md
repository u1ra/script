# vps-forward

[English](README_EN.md) · nftables IPv4 四层端口转发管理器

`vps-forward` 是面向新装 VPS 的 Bash 工具，用独立 nftables 表管理“线路 VPS → 落地 VPS”的 TCP、UDP 或 TCP+UDP 单端口转发。它以本地配置为唯一数据源，每次通过原子 nftables 事务重建自己的规则，不清空 ruleset，也不修改 Docker、UFW、firewalld、Fail2ban 或用户的表。

> [!CAUTION]
> 修改防火墙可能让 VPS 断连。操作前请保留当前 SSH 会话，并确认 VPS 控制台或其他应急登录方式可用。本项目按现状提供；作者不对错误配置导致的断连、数据损失或服务中断负责。

## 功能

- Ubuntu、Debian（`apt-get`）和 Alpine（`apk`）安装检测
- systemd 与 OpenRC 独立持久化服务，不依赖 `/etc/nftables.conf`
- IPv4 DNAT、对应 FORWARD 放行及可选 Masquerade
- TCP、UDP、BOTH；监听全部地址或指定本机 IPv4
- 精确、目标 IP、关闭三种 Masquerade 模式
- 交互菜单与适合自动化的 CLI
- CRUD、启用/禁用、dry-run、JSON 列表/状态、doctor
- 版本化 TSV 配置、锁、原子写入、自动备份、验证和失败回滚
- 备份、恢复、导入、导出及保守卸载
- 只管理 `vps_forward_nat` 和 `vps_forward_filter` 两个带所有权标记的表

当前版本只支持 IPv4 单端口。域名、IPv6、端口范围、负载均衡、透明代理、PROXY Protocol 和一对多转发不在 v0.1 范围内。

## 支持系统

| 系统 | 包管理器 | 服务管理 |
|---|---|---|
| Ubuntu | apt | systemd |
| Debian | apt | systemd |
| Alpine Linux | apk | OpenRC |

主程序要求 Bash。Alpine 没有 Bash 时，可先用 POSIX `sh` 运行 `install.sh`，引导器会安装 Bash。遇到其他系统或没有受支持服务管理器时，安装会明确停止。

## 安装

### 推荐：克隆、检查、再执行

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
git log --oneline --show-signature -1
less install.sh vps-forward.sh lib/vps-forward-core.sh
sudo ./install.sh
```

安装器会安装 nftables、iproute2 和 util-linux，将程序装到 `/usr/local`，写入项目 sysctl 文件，创建独立 systemd/OpenRC 服务，并应用空的项目 ruleset。重复安装会保留配置。

### 使用 Bash 一键安装并启动

在 `script/vps-forward` 源码目录中执行：

```bash
sudo bash install.sh && sudo vps-forward
```

第一条命令安装环境和持久化服务；安装成功后，第二条命令立即打开交互菜单。也可以不安装直接运行源码菜单：

```bash
sudo bash vps-forward.sh
```

但直接运行主程序时，仍需先在菜单中选择“初始化环境”，否则系统可能尚未安装 nftables 或启用 IPv4 转发。Alpine 尚未安装 Bash 时，请先运行 `sudo sh install.sh`。

### 固定版本与 SHA256

发布 Release 后，下载固定标签而不是 `main`，并使用该 Release 附带的校验文件：

```bash
VERSION=v0.1.0
curl -fLO "https://github.com/u1ra/script/releases/download/${VERSION}/vps-forward-${VERSION}.tar.gz"
curl -fLO "https://github.com/u1ra/script/releases/download/${VERSION}/vps-forward-${VERSION}.tar.gz.sha256"
sha256sum -c "vps-forward-${VERSION}.tar.gz.sha256"
tar -xzf "vps-forward-${VERSION}.tar.gz"
cd "vps-forward-${VERSION#v}"
less install.sh vps-forward.sh
sudo ./install.sh
```

可给远程引导器指定版本和期望散列：

```bash
sudo env VPF_INSTALL_VERSION=v0.1.0 VPF_SHA256='<release-sha256>' ./install.sh
```

### 使用 curl 一键安装并启动

GitHub 仓库公开后执行：

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | sudo bash' && sudo vps-forward
```

`bash -o pipefail` 可确保下载失败时整条安装流水线返回失败；安装成功后才会启动 `vps-forward` 菜单。不过，`curl | bash` 仍会直接执行网络内容，无法让你先审计，且默认分支内容可变化。它只适合了解风险的临时环境；生产环境应使用上面的固定版本、审查和 SHA256 流程。

全新 Alpine 尚未安装 Bash 时，可让 POSIX `sh` 运行引导器：

```sh
tmp_file="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh -o "$tmp_file" && sudo sh "$tmp_file" && rm -f "$tmp_file" && sudo vps-forward
```

## 快速开始

将线路 VPS 的 TCP+UDP `8443` 转发到文档保留地址 `192.0.2.10:20086`，使用默认的精确 Masquerade：

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

`192.0.2.0/24` 是文档示例网段。使用时替换为你的落地 VPS IPv4。

关闭 Masquerade：

```bash
sudo vps-forward add \
  --name routed-return \
  --listen-port 9443 \
  --target-ip 198.51.100.20 \
  --target-port 443 \
  --protocol tcp \
  --no-masquerade
```

关闭后，落地 VPS 及其上游必须知道如何把客户端流量经线路 VPS 返回；否则非对称路由会使 TCP/UDP 转发失败。

## 交互菜单

直接运行 `sudo vps-forward`。菜单包含初始化、新增、查看、修改、删除、启停、查看实际规则、检查、备份、恢复、导入、导出、重新应用和卸载。输入提示会显示默认值；`q` 可取消当前输入；删除、恢复、导入和卸载要求再次确认。无效菜单项会重新提示。

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
| `backup` | 建立带 manifest 的内部备份 |
| `restore NAME --yes` | 恢复内部备份 |
| `export --output /abs/file` | 导出 TSV 配置 |
| `import --input /abs/file --yes` | 校验、备份、导入并应用 |
| `uninstall --yes [选项]` | 保守卸载 |
| `help` / `version` | 帮助/版本 |

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
| `--dry-run` | 在 `/tmp` 显示候选配置、生成规则和事务，不写系统；缺少 nft/权限时会明确降级为结构检查 |
| `--yes` | 确认 SSH 端口风险或危险操作 |
| `--quiet` | 减少非错误输出 |

成功退出码为 0；参数、配置或系统错误返回非 0。CLI 不会为缺失的确认参数打开隐藏式交互。

修改、删除示例：

```bash
sudo vps-forward show 1
sudo vps-forward edit 1 --target-port 20087 --masquerade-mode destination
sudo vps-forward disable 1
sudo vps-forward enable 1
sudo vps-forward delete 1 --yes
```

TCP 和 UDP 分别占用协议空间：已有 TCP `8443` 时可新增 UDP `8443`；BOTH 与同地址/端口上的任一 TCP 或 UDP 规则冲突。`any` 与所有具体监听地址重叠。

## nftables 设计

配置 `/etc/vps-forward/config.tsv` 是唯一数据源。启用的每条规则生成 DNAT 和 FORWARD；Masquerade 按模式生成。项目不保存动态 handle。

```text
table ip vps_forward_nat
├── prerouting   (type nat, hook prerouting, priority dstnat): DNAT
└── postrouting  (type nat, hook postrouting, priority srcnat): Masquerade

table inet vps_forward_filter
└── forward      (type filter, hook forward, priority -5): 仅项目 DNAT 流量的放行
```

实际逻辑（保留地址示例）：

```nft
tcp dport 8443 dnat to 192.0.2.10:20086
udp dport 8443 dnat to 192.0.2.10:20086

ct status dnat ip daddr 192.0.2.10 tcp dport 20086 masquerade
ct status dnat ip daddr 192.0.2.10 udp dport 20086 masquerade

ct status dnat ct state established,related accept
ct status dnat ip daddr 192.0.2.10 tcp dport 20086 accept
ct status dnat ip daddr 192.0.2.10 udp dport 20086 accept
```

这是逻辑示例；真实规则位于上述独立表、带 `vps-forward id=... name=...` comment，并用 `ct status dnat` 缩小影响范围。

### 三种 Masquerade

1. `precise`：按 DNAT 状态、目标 IP、目标端口和协议匹配，默认且推荐；不会顺带改写发往目标其他端口的流量。
2. `destination`：按 DNAT 状态和目标 IP 匹配。同一目标 IP 的多个项目规则共享一条生成规则，配置完整重建保证删除一条引用时不会影响其余规则。逻辑为 `ct status dnat ip daddr 192.0.2.10 masquerade`。
3. `none`：不生成 SNAT/Masquerade。可保留客户端源 IP，但必须自行配置正确回程路由。

### 与其他防火墙共存

nftables 中，同一个 hook 可有多个 base chain。某个 base chain 的 `accept` 不保证流量最终被全局接受；后续其他 base chain 仍可 `drop`。本项目的 filter base chain 使用 priority `-5`，但不会改变其他 chain 的 policy 或 priority。

因此：

- 项目绝不执行 `flush ruleset`，只原子删除并重建带项目 marker 的两个表。
- 如果同名表存在却没有项目 marker，操作立即停止。
- UFW、firewalld、Docker、Fail2ban 和 iptables-nft 只被 `doctor` 检测，不会被关闭或改写。
- 其他 chain 若提前或随后 drop，转发仍可能失败。doctor 能报告常见服务、项目表和现有 ruleset，但无法理解任意第三方规则的完整意图。
- Docker 在项目服务启动后重建防火墙时可能改变结果；可再次 `apply`，并应结合实际启动顺序测试。

## 原子应用与恢复

每次修改：

1. 获取 `flock` 独占锁并校验 TSV；
2. 在同目录创建权限 0600 的候选文件；
3. 完整生成两个项目表；
4. 验证现存同名表所有权；
5. 构造只删除这两个项目表的 nftables 事务；
6. 运行 `nft --check --file`；
7. 自动备份当前配置；
8. 用 nftables 单事务应用并验证表存在；
9. 原子替换配置和生成文件；失败则恢复之前项目 ruleset。

不会出现单独增加 DNAT 而未增加 FORWARD 的中间提交。自动备份默认保留最近 20 份。

## 持久化与文件位置

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

systemd 使用独立 `vps-forward.service`，在 `network-online` 和发行版 nftables 服务之后调用 `apply`；OpenRC 使用独立 init script，依赖 `net` 并排在 nftables 之后。服务每次都完整重建项目表，因此重复加载幂等，且不会覆盖发行版主配置文件。

## 备份、恢复、导入和导出

```bash
sudo vps-forward backup
sudo vps-forward restore backup-20260101T000000Z-1234-5678 --yes
sudo vps-forward export --output /root/vps-forward-config.tsv
sudo vps-forward import --input /root/vps-forward-config.tsv --yes
```

内部备份含配置、生成规则、manifest，以及存在时的服务和 sysctl 文件。恢复/导入先校验 schema 和配置、备份当前状态、执行 nft 检查；失败会保留或恢复原状态。restore 只接受备份目录内的严格名称，导入拒绝符号链接。

## 卸载

默认保留配置、备份、nftables 软件包、sysctl 文件和当前 IPv4 转发状态：

```bash
sudo vps-forward uninstall --yes --keep-config
```

其他模式：

```bash
sudo vps-forward uninstall --yes --rules-only
sudo vps-forward uninstall --yes --purge
sudo vps-forward uninstall --yes --purge --remove-sysctl
sudo vps-forward uninstall --yes --purge --remove-sysctl --remove-package
```

即使删除 sysctl 文件，也不会主动写入 `net.ipv4.ip_forward=0`，避免影响容器、VPN 或其他转发服务。`--remove-package` 可能影响系统其他 nftables 用户，只应在确认后使用。

## 升级

```bash
git fetch --tags
git checkout v0.1.1
sudo ./install.sh
sudo vps-forward check
sudo vps-forward apply
```

升级前先 `backup`。安装器会保留已有 TSV；未来 schema 升级会在 CHANGELOG 说明迁移步骤，未知 schema 会被拒绝而不是猜测处理。

## 故障排查

1. 运行 `sudo vps-forward doctor` 和 `sudo vps-forward check`。
2. 确认 `/proc/sys/net/ipv4/ip_forward` 为 `1`。
3. 用 `sudo vps-forward rules` 检查 DNAT、FORWARD、Masquerade。
4. 检查监听端口是否与 SSH/其他服务重叠：`ss -lntup`。
5. 检查 UFW/firewalld/其他 nftables base chain 是否 drop。
6. 无 Masquerade 时检查落地 VPS 回程路由。
7. 检查 `/var/log/vps-forward.log` 和 systemd/OpenRC 日志。
8. 使用 `sudo vps-forward apply --dry-run` 审计候选事务。

端口占用检测只是提示。UDP 没有监听记录不代表路径可用，容器、绑定特定 IP 和检测后的竞态也可能影响结果。

## 常见问题

**为什么不修改系统 `forward` 链？**

为了不改变系统全局 policy 或覆盖 Docker/UFW。项目创建自己的 base chain，并接受其他链仍有最终否决权。

**为什么默认 Masquerade？**

多数落地 VPS 不知道客户端网段应经线路 VPS 返回。Masquerade 让回包自然回到线路 VPS；精确模式的影响最小。

**能保留客户端真实 IP 吗？**

可用 `--no-masquerade`，但必须在落地端配置回程路由。DNAT 本身不会创建该路由。

**为什么转发规则存在但仍不通？**

常见原因是其他 base chain drop、云厂商安全组、上游 ACL、IPv4 转发未开启、端口冲突或错误回程路由。

**支持 IPv6/端口范围吗？**

v0.1 不支持。配置 schema 和生成器已分层，未来可在不使用 nft handle 的前提下扩展。

## 开发与测试

```bash
bash -n vps-forward.sh lib/vps-forward-core.sh tests/*.sh
sh -n install.sh
shellcheck vps-forward.sh install.sh uninstall.sh lib/*.sh tests/*.sh
bash tests/run-tests.sh
```

测试在隔离临时目录中 mock nftables，不会修改开发机防火墙。参见 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 和 [TODO.md](TODO.md)。

## 仓库发布信息

- 推荐仓库名：`vps-forward`
- 简介：`Safe nftables IPv4 TCP/UDP port forwarding manager for Ubuntu, Debian and Alpine`
- Topics：`nftables`, `port-forwarding`, `vps`, `bash`, `linux`, `dnat`, `firewall`, `ubuntu`, `debian`, `alpine-linux`, `systemd`, `openrc`

## License

[MIT](LICENSE)
