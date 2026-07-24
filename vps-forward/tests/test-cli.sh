#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-helper.sh"

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VPF="$PROJECT_ROOT/vps-forward.sh"

run_vpf() {
    "$VPF" "$@"
}

run_vpf add --name tcp-edge --listen-port 8443 --target-ip 192.0.2.10 --target-port 20086 --protocol tcp
assert_contains "新增 TCP 规则" "$VPF_CONFIG_FILE" $'\ttcp\t*\t8443\t192.0.2.10\t20086\tprecise\t'
assert_contains "TCP DNAT 已应用" "$VPF_MOCK_DIR/active.nft" 'tcp dport 8443 dnat to 192.0.2.10:20086'

run_vpf add --name udp-edge --listen-port 8443 --target-ip 192.0.2.11 --target-port 20087 --protocol udp --masquerade-mode destination
assert_contains "同端口可新增 UDP" "$VPF_CONFIG_FILE" $'\tudp\t*\t8443\t192.0.2.11\t20087\tdestination\t'

if run_vpf add --name bad-masq --listen-port 8500 --target-ip 192.0.2.50 \
    --target-port 8500 --no-masquerade --masquerade-mode precise >/dev/null 2>&1; then
    fail "拒绝冲突 Masquerade 参数"
else
    pass "拒绝冲突 Masquerade 参数"
fi
if run_vpf add --name bad-mode --listen-port 8501 --target-ip 192.0.2.51 \
    --target-port 8501 --masquerade-mode global >/dev/null 2>&1; then
    fail "拒绝未知 Masquerade 模式"
else
    pass "拒绝未知 Masquerade 模式"
fi

if run_vpf add --name conflict --listen-port 8443 --target-ip 192.0.2.12 --target-port 20088 --protocol both >/dev/null 2>&1; then
    fail "BOTH 与已有 TCP/UDP 冲突"
else
    pass "BOTH 与已有 TCP/UDP 冲突"
fi

json_output="$(run_vpf list --json)"
if [[ "$json_output" == \[*'"id":1'*'"id":2'*\] ]]; then
    pass "list JSON 输出"
else
    fail "list JSON 输出"
fi

run_vpf edit 1 --target-port 21000 --no-masquerade
assert_contains "修改目标端口" "$VPF_CONFIG_FILE" $'\t192.0.2.10\t21000\tnone\t'
assert_false "修改后无旧目标端口" grep -Fq '192.0.2.10:20086' "$VPF_MOCK_DIR/active.nft"

run_vpf disable 1
assert_contains "禁用状态保留配置" "$VPF_CONFIG_FILE" $'1\t0\ttcp'
assert_false "禁用规则不生成 DNAT" grep -Fq '192.0.2.10:21000' "$VPF_MOCK_DIR/active.nft"

run_vpf enable 1
assert_contains "重新启用规则" "$VPF_CONFIG_FILE" $'1\t1\ttcp'

before_sum="$(sha256sum "$VPF_CONFIG_FILE" "$VPF_MOCK_DIR/active.nft")"
dry_output="$(run_vpf add --name dry --listen-port 9000 --target-ip 192.0.2.90 --target-port 9000 --dry-run)"
after_sum="$(sha256sum "$VPF_CONFIG_FILE" "$VPF_MOCK_DIR/active.nft")"
if [[ "$before_sum" == "$after_sum" ]]; then
    pass "dry-run 不修改配置或实际规则"
else
    fail "dry-run 不修改配置或实际规则"
fi
if [[ "$dry_output" == *'DRY-RUN：未修改'* ]]; then
    pass "dry-run 显示操作"
else
    fail "dry-run 显示操作"
fi

run_vpf delete 2 --yes
assert_false "删除规则移除配置" grep -Eq '^2[[:space:]]' "$VPF_CONFIG_FILE"
assert_false "删除规则无 Masquerade 残留" grep -Fq '192.0.2.11' "$VPF_MOCK_DIR/active.nft"

status_json="$(run_vpf status --json)"
if [[ "$status_json" == *'"total":1'*'"enabled":1'*'"tables":"present"'* ]]; then
    pass "status JSON 输出"
else
    fail "status JSON 输出"
fi

run_vpf check
pass "check 通过"

idempotent_before="$(sha256sum "$VPF_CONFIG_FILE" "$VPF_MOCK_DIR/active.nft")"
run_vpf apply
run_vpf apply
idempotent_after="$(sha256sum "$VPF_CONFIG_FILE" "$VPF_MOCK_DIR/active.nft")"
if [[ "$idempotent_before" == "$idempotent_after" ]]; then
    pass "重复 apply 幂等"
else
    fail "重复 apply 幂等"
fi

config_mode="$(stat -c '%a' "$VPF_CONFIG_FILE")"
generated_mode="$(stat -c '%a' "$VPF_GENERATED_FILE")"
if [[ "$config_mode" == "600" && "$generated_mode" == "600" ]]; then
    pass "配置与生成文件权限为 0600"
else
    fail "配置与生成文件权限为 0600"
fi

printf '1..%d\n' "$TESTS_RUN"
