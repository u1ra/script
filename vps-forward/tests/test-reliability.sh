#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-helper.sh"

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VPF="$PROJECT_ROOT/vps-forward.sh"

"$VPF" add --name stable --listen-port 7000 --target-ip 192.0.2.70 --target-port 7001
config_before="$(sha256sum "$VPF_CONFIG_FILE")"
active_before="$(sha256sum "$VPF_MOCK_DIR/active.nft")"

if VPF_MOCK_FAIL_VERIFY=1 "$VPF" edit 1 --target-port 7999 >/dev/null 2>&1; then
    fail "验证失败返回非零"
else
    pass "验证失败返回非零"
fi
if [[ "$(sha256sum "$VPF_CONFIG_FILE")" == "$config_before" ]]; then
    pass "验证失败回滚配置"
else
    fail "验证失败回滚配置"
fi
if [[ "$(sha256sum "$VPF_MOCK_DIR/active.nft")" == "$active_before" ]]; then
    pass "验证失败回滚实际规则"
else
    fail "验证失败回滚实际规则"
fi

cp -- "$VPF_CONFIG_FILE" "$TEST_ROOT/good.tsv"
sed 's/192[.]0[.]2[.]70/not-an-ip/' "$VPF_CONFIG_FILE" >"$TEST_ROOT/corrupt.tsv"
if "$VPF" import --input "$TEST_ROOT/corrupt.tsv" --yes >/dev/null 2>&1; then
    fail "拒绝损坏配置导入"
else
    pass "拒绝损坏配置导入"
fi

(
    exec 8>"$VPF_LOCK_FILE"
    flock 8
    touch "$TEST_ROOT/lock-ready"
    sleep 2
) &
locker_pid=$!
while [[ ! -e "$TEST_ROOT/lock-ready" ]]; do sleep 0.05; done
if "$VPF" edit 1 --target-port 7002 >/dev/null 2>&1; then
    kill "$locker_pid" 2>/dev/null || true
    fail "文件锁拒绝并发修改"
else
    pass "文件锁拒绝并发修改"
fi
wait "$locker_pid"

export_path="$TEST_ROOT/export.tsv"
"$VPF" export --output "$export_path"
assert_contains "导出包含 schema" "$export_path" '# vps-forward-config-v1'

"$VPF" edit 1 --target-port 7002
"$VPF" import --input "$export_path" --yes
assert_contains "导入恢复原端口" "$VPF_CONFIG_FILE" $'\t192.0.2.70\t7001\t'

before_backups="$(find "$VPF_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' | sort)"
"$VPF" backup
backup_path="$(comm -13 <(printf '%s\n' "$before_backups" | sed '/^$/d') <(find "$VPF_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' | sort) | tail -1)"
backup_name="${backup_path##*/}"
"$VPF" edit 1 --target-port 7003
"$VPF" restore "$backup_name" --yes
assert_contains "内部备份恢复" "$VPF_CONFIG_FILE" $'\t192.0.2.70\t7001\t'

# 每个主程序进程退出时应清理其 .vps-forward 临时文件。
if find "$VPF_CONFIG_DIR" -maxdepth 1 -type f -name '.vps-forward.*' | grep -q .; then
    fail "临时文件自动清理"
else
    pass "临时文件自动清理"
fi

# 首次 dry-run 不能创建配置目录、锁或配置文件。
fresh_root="$TEST_ROOT/fresh"
fresh_output="$(
    VPF_CONFIG_DIR="$fresh_root/etc/vps-forward" \
    VPF_CONFIG_FILE="$fresh_root/etc/vps-forward/config.tsv" \
    VPF_GENERATED_FILE="$fresh_root/etc/vps-forward/generated.nft" \
    VPF_BACKUP_DIR="$fresh_root/etc/vps-forward/backups" \
    VPF_LOCK_FILE="$fresh_root/etc/vps-forward/lock" \
    VPF_STATE_FILE="$fresh_root/etc/vps-forward/state" \
    VPF_LOG_FILE="$fresh_root/log" \
    VPF_MOCK_DIR="$fresh_root/mock" \
    VPF_SYSTEM_MODE=real \
    "$VPF" add --name first-preview --listen-port 8080 \
        --target-ip 192.0.2.80 --target-port 80 --dry-run
)"
if [[ ! -e "$fresh_root" && "$fresh_output" == *'DRY-RUN：未修改'* ]]; then
    pass "首次 dry-run 零系统写入"
else
    fail "首次 dry-run 零系统写入"
fi

# 同名外部表缺少 marker 时必须停止，且不能改写该表。
foreign_root="$TEST_ROOT/foreign"
mkdir -p "$foreign_root/mock"
printf 'table ip vps_forward_nat {\n    comment "foreign owner"\n}\n' >"$foreign_root/mock/active.nft"
foreign_before="$(sha256sum "$foreign_root/mock/active.nft")"
if VPF_CONFIG_DIR="$foreign_root/etc/vps-forward" \
    VPF_CONFIG_FILE="$foreign_root/etc/vps-forward/config.tsv" \
    VPF_GENERATED_FILE="$foreign_root/etc/vps-forward/generated.nft" \
    VPF_BACKUP_DIR="$foreign_root/etc/vps-forward/backups" \
    VPF_LOCK_FILE="$foreign_root/etc/vps-forward/lock" \
    VPF_STATE_FILE="$foreign_root/etc/vps-forward/state" \
    VPF_LOG_FILE="$foreign_root/log" \
    VPF_MOCK_DIR="$foreign_root/mock" \
    "$VPF" add --name collision --listen-port 8081 \
        --target-ip 192.0.2.81 --target-port 81 >/dev/null 2>&1; then
    fail "拒绝同名外部 nftables 表"
else
    pass "拒绝同名外部 nftables 表"
fi
if [[ "$(sha256sum "$foreign_root/mock/active.nft")" == "$foreign_before" ]]; then
    pass "外部 nftables 表保持不变"
else
    fail "外部 nftables 表保持不变"
fi

printf '1..%d\n' "$TESTS_RUN"
