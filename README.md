# script

个人 Shell 脚本集合。每个工具放在独立子目录中，并包含自己的文档、测试和许可证。

## 脚本列表

| 目录 | 用途 | 状态 |
|---|---|---|
| [`vps-forward/`](vps-forward/) | 使用 nftables 安装、配置和管理 IPv4 TCP/UDP 四层端口转发 | v0.1.1 |

## 使用说明

进入对应子目录阅读 README，不建议在未审查代码的情况下直接以 root 执行脚本。

```bash
git clone https://github.com/u1ra/script.git
cd script/vps-forward
less README.md install.sh vps-forward.sh
```

### vps-forward 一键安装并启动

已克隆仓库时，在仓库根目录执行：

```bash
sudo bash vps-forward/install.sh && sudo vpf
```

仓库公开后，可使用 `curl` 远程安装，并在成功后打开交互菜单：

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | sudo bash' && sudo vpf
```

远程命令会直接执行默认分支代码。生产 VPS 建议先下载并检查 `install.sh`，具体安全安装方式见 [`vps-forward/README.md`](vps-forward/README.md)。

已经是 root 用户时无需 `sudo`：

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/u1ra/script/main/vps-forward/install.sh | bash' && vpf
```

各项目的测试和许可证以其子目录内文件为准。
