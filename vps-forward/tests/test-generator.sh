#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-helper.sh"

fixture="$TEST_ROOT/fixture.tsv"
rules="$TEST_ROOT/generated.nft"
write_fixture_config "$fixture"
vpf_generate_ruleset "$fixture" "$rules"

assert_contains "生成独立 NAT 表" "$rules" 'table ip vps_forward_nat {'
assert_contains "生成独立 filter 表" "$rules" 'table inet vps_forward_filter {'
assert_contains "BOTH 生成 TCP DNAT" "$rules" 'tcp dport 8443 dnat to 192.0.2.10:20086'
assert_contains "BOTH 生成 UDP DNAT" "$rules" 'udp dport 8443 dnat to 192.0.2.10:20086'
assert_contains "监听 IP 进入规则" "$rules" 'ip daddr 198.51.100.2 tcp dport 9443'
assert_contains "生成精确 TCP Masquerade" "$rules" 'ip daddr 192.0.2.10 tcp dport 20086 masquerade'
assert_contains "生成精确 UDP Masquerade" "$rules" 'ip daddr 192.0.2.10 udp dport 20086 masquerade'
assert_contains "生成目标 IP Masquerade" "$rules" 'ip daddr 192.0.2.20 masquerade'
assert_false "禁用规则不进入 ruleset" grep -Fq '192.0.2.30' "$rules"
assert_false "生成文件绝不 flush ruleset" grep -Eq 'flush[[:space:]]+ruleset' "$rules"

# 同目标 destination 模式只生成一条共享 Masquerade。
printf '4\t1\tudp\t*\t9444\t192.0.2.20\t443\tdestination\tweb-udp\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n' >>"$fixture"
vpf_generate_ruleset "$fixture" "$rules"
count="$(grep -Fc 'ip daddr 192.0.2.20 masquerade' "$rules")"
if [[ "$count" == "1" ]]; then
    pass "共享 destination Masquerade 去重"
else
    fail "共享 destination Masquerade 去重"
fi

remaining="$TEST_ROOT/remaining.tsv"
awk -F '\t' '$1 != "2"' "$fixture" >"$remaining"
vpf_generate_ruleset "$remaining" "$rules"
count="$(grep -Fc 'ip daddr 192.0.2.20 masquerade' "$rules")"
if [[ "$count" == "1" ]]; then
    pass "删除一个共享引用仍保留 Masquerade"
else
    fail "删除一个共享引用仍保留 Masquerade"
fi

printf '5\t1\ttcp\t*\t10443\t203.0.113.5\t443\tnone\tno-snat\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n' >>"$remaining"
vpf_generate_ruleset "$remaining" "$rules"
assert_contains "关闭 Masquerade 仍生成 DNAT" "$rules" 'tcp dport 10443 dnat to 203.0.113.5:443'
assert_false "关闭 Masquerade 不生成 SNAT" grep -Fq 'ip daddr 203.0.113.5 tcp dport 443 masquerade' "$rules"

printf '1..%d\n' "$TESTS_RUN"
