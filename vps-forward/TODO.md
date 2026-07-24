# vps-forward 实施与验收计划

> 状态：`[ ]` 待办，`[~]` 进行中，`[x]` 已完成。每个阶段完成后立即执行列出的测试，再更新状态。

## 0. 需求与架构分析

- [x] 明确范围：仅支持 IPv4、单端口、TCP/UDP/BOTH，不支持域名、IPv6、端口范围和代理协议。
- [x] 系统差异：
  - Ubuntu/Debian 使用 `apt-get`、systemd（若存在）；Alpine 使用 `apk`、OpenRC。
  - 不依赖发行版的 `/etc/nftables.conf`；使用独立生成文件和独立服务。
  - Alpine 的 `/bin/sh` 可运行 `install.sh` 引导器，由其安装 Bash 后再调用主程序。
  - sysctl 使用项目独立的 `/etc/sysctl.d/99-vps-forward.conf`，运行时同时用 `sysctl -w` 验证。
- [x] nftables 结构：
  - `table ip vps_forward_nat`：`prerouting` DNAT base chain 和 `postrouting` Masquerade base chain。
  - `table inet vps_forward_filter`：独立 `forward` base chain，只放行带 DNAT 状态及项目目标流量，policy 为 accept，不改系统其他链。
  - 两个表均带项目 comment；操作前验证所有权，绝不执行 `flush ruleset`。
  - 配置是唯一数据源；每次完整重建两个项目表，天然解决共享 Masquerade 的引用和残留问题。
- [x] 持久化方案：
  - systemd/OpenRC 独立服务在网络就绪后调用 `vps-forward apply --boot --yes`。
  - apply 生成仅删除并重建两个项目表的 nftables 原子事务，先 `nft --check`，失败不影响已有规则。
- [x] 配置方案：
  - 使用受限 UTF-8/ASCII 名称的 TSV v1，避免强依赖 jq。
  - 临时文件、校验、备份、文件锁、原子替换和失败回滚。
- [x] 安全边界：
  - root 检查、严格模式、无 `eval`、所有输入白名单校验、拒绝符号链接、限制权限。
  - UFW/firewalld/Docker/Fail2ban 仅检测提示；SSH 端口要求显式确认。

## 1. 核心数据与规则引擎

- [x] 实现版本化 TSV 配置、原子读写、权限和锁。
- [x] 实现 IPv4、端口、协议、名称、监听地址、Masquerade 参数校验。
- [x] 实现 TCP/UDP/BOTH 协议重叠、监听地址重叠和重复规则检测。
- [x] 实现两个独立 nftables 表的确定性生成器和 comment。
- [x] 实现精确、目标 IP、关闭三种 Masquerade；共享项去重。
- [x] 实现 `nft --check`、项目表所有权验证、原子事务、验证和回滚。
- [x] 测试：`bash -n`、校验、冲突、生成器、共享 Masquerade、dry-run 和回滚均通过。

## 2. 规则管理与诊断 CLI

- [x] CRUD：add/list/show/edit/delete/enable/disable。
- [x] apply/check/status/doctor/help/version，list/status 支持 JSON。
- [x] 端口占用、SSH 风险和现有防火墙冲突提示。
- [x] dry-run 显示候选配置、规则和系统操作且不写系统。
- [x] 测试：参数解析、增删改查、启停、损坏配置、锁、回滚和幂等。

## 3. 安装、持久化、备份与卸载

- [x] Ubuntu、Debian、Alpine 检测与 apt/apk 安装分支。
- [x] IPv4 转发临时与持久化配置。
- [x] systemd 与 OpenRC 独立服务，幂等安装且不覆盖非项目文件。
- [x] backup/restore/export/import，格式校验和失败回滚。
- [x] 保守卸载选项，不默认关闭转发或卸载 nftables。
- [x] 测试：mock 安装分支、备份恢复、导入导出、卸载、幂等。

## 4. 交互菜单与公开仓库文件

- [x] 完整 1～15 菜单、默认值、重试、取消、危险操作确认。
- [x] README.md、README_EN.md、示例、示例配置。
- [x] MIT LICENSE、CHANGELOG、SECURITY、CONTRIBUTING、Release 模板。
- [x] `.editorconfig`、`.gitignore`、GitHub Actions ShellCheck。
- [x] 核对文档命令与真实 CLI。

## 5. 最终质量门与验收

- [x] 所有 Shell 文件通过 `bash -n`（POSIX 引导器通过 `sh -n`）。
- [x] ShellCheck 0.9.0 无 error/warning/info。
- [x] 全部 97 项自动化断言通过。
- [x] 确认代码中不存在 `nft flush ruleset`；同名外部表测试确认拒绝且不改写。
- [x] 确认示例仅使用 RFC 5737 文档地址，无密码、密钥或 Token。
- [x] 按需求的 22 条验收标准逐项记录结果。

## 22 条验收记录

1. [x] Ubuntu 安装逻辑：apt 包和 systemd 分支已有 mock 测试。
2. [x] Debian 安装逻辑：apt 包和 systemd 分支已有 mock 测试。
3. [x] Alpine 安装逻辑：apk、Bash 引导和 OpenRC 分支已有语法/mock 测试。
4. [x] systemd/OpenRC 映射正确，服务文件为项目独立文件。
5. [x] 重复 install 保持配置散列不变。
6. [x] TCP 新增和 DNAT 生成通过。
7. [x] UDP 与同端口 TCP 的独立协议占用通过。
8. [x] BOTH 生成 TCP+UDP 且冲突检测通过。
9. [x] 精确 Masquerade 的 TCP/UDP 规则通过。
10. [x] 目标 IP Masquerade 生成和共享去重通过。
11. [x] 关闭 Masquerade 仍生成 DNAT/FORWARD 且无 SNAT。
12. [x] 修改后旧目标端口不再存在。
13. [x] 删除后配置、DNAT 和 Masquerade 均无残留。
14. [x] 删除一个共享引用后，共享 Masquerade 仍保留。
15. [x] 禁用后 TSV 保留且不生成实际转发。
16. [x] 模拟应用后验证失败时，配置和实际规则散列均恢复。
17. [x] 代码/生成器无 `flush ruleset`；外部同名表保持不变。
18. [x] UFW、firewalld、Docker、Fail2ban 代码路径只有检测，没有停用命令。
19. [x] systemd/OpenRC 均调用幂等 `apply`，不覆盖发行版主 nftables 配置。
20. [x] README 命令表与 `help` 的子命令和参数已核对。
21. [x] ShellCheck 0.9.0 全量通过。
22. [x] 97 项隔离自动化断言全部通过。

> 环境限制：开发容器没有 `nft`，也没有免密 sudo，因此没有在真实内核
> ruleset 或三种真实发行版 VM 上执行集成安装。测试使用隔离 mock 验证事务文本、
> 系统分支、回滚和文件操作；发布前仍应按 Release 模板完成三种系统的真实 VM 冒烟测试。

## 设计风险（将在 README 明示）

- nftables 的 `accept` 只对当前 base chain 作出结论；其他同 hook 的 base chain 仍可 drop，因此 UFW/firewalld/用户规则可能阻止项目流量。
- 不同 base chain 的同优先级顺序不应作为安全保证；本项目使用明确 priority，但不会修改其他规则的 priority。
- Docker 等软件可在服务启动后改变防火墙；doctor 可检测常见服务，但无法证明任意第三方规则一定兼容。
- 端口监听检测只是提示；UDP、绑定特定地址、容器网络和竞态使其不能作为可用性的证明。
- 无 Masquerade 时必须由目标端正确配置回程路由，否则会发生非对称路由。
