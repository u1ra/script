# 基本用法

以下地址来自 RFC 5737 文档网段，不能替代真实服务器地址。

## TCP+UDP，不同端口，精确 Masquerade

```bash
sudo vps-forward add \
  --name edge-8443 \
  --listen-port 8443 \
  --target-ip 192.0.2.10 \
  --target-port 20086 \
  --protocol both \
  --masquerade-mode precise
```

## 只监听一个本机 IPv4

```bash
sudo vps-forward add \
  --name dedicated-ip \
  --listen-ip 198.51.100.5 \
  --listen-port 443 \
  --target-ip 192.0.2.20 \
  --target-port 8443 \
  --protocol tcp
```

## 目标 IP Masquerade

```bash
sudo vps-forward edit 1 --masquerade-mode destination
```

## 预览和自动化

```bash
sudo vps-forward add \
  --name preview \
  --listen-port 5353 \
  --target-ip 203.0.113.53 \
  --target-port 53 \
  --protocol udp \
  --dry-run

vps-forward list --json
vps-forward status --json
```
