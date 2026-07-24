# script

个人自用 Shell 脚本仓库。每个工具放在独立子目录中，并包含自己的文档、测试和许可证。

## 脚本列表

| 目录 | 用途 | 状态 |
|---|---|---|
| [`vps-forward/`](vps-forward/) | 使用 nftables 安装、配置和管理 IPv4 TCP/UDP 四层端口转发（Ubuntu / Debian / Alpine） | v0.1.3 |

## 使用说明

每个脚本的安装和使用方式见对应子目录的 README。不建议在未审查代码的情况下直接以 root 执行脚本：

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
less README.md install.sh vps-forward.sh
```

各脚本的测试和许可证以其子目录内文件为准。
