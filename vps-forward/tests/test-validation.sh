#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-helper.sh"

assert_true "接受普通 IPv4" vpf_valid_ipv4 192.0.2.1
assert_true "接受边界 IPv4" vpf_valid_ipv4 255.255.255.255
assert_false "拒绝越界 IPv4" vpf_valid_ipv4 192.0.2.256
assert_false "拒绝前导零 IPv4" vpf_valid_ipv4 192.00.2.1
assert_false "拒绝命令字符串" vpf_valid_ipv4 '192.0.2.1;id'
assert_true "接受最低端口" vpf_valid_port 1
assert_true "接受最高端口" vpf_valid_port 65535
assert_false "拒绝零端口" vpf_valid_port 0
assert_false "拒绝越界端口" vpf_valid_port 65536
assert_true "接受 both 协议" vpf_valid_protocol both
assert_false "拒绝未知协议" vpf_valid_protocol icmp
assert_true "接受安全规则名" vpf_valid_name 'sg-to-jp 01'
assert_false "拒绝引号规则名" vpf_valid_name 'bad"name'

fixture="$TEST_ROOT/fixture.tsv"
write_fixture_config "$fixture"
assert_true "接受有效配置" vpf_validate_config "$fixture"

broken="$TEST_ROOT/broken.tsv"
sed 's/192[.]0[.]2[.]10/999.0.2.10/' "$fixture" >"$broken"
assert_false "拒绝损坏配置" vpf_validate_config "$broken"

conflicting="$TEST_ROOT/conflicting.tsv"
cp -- "$fixture" "$conflicting"
printf '4\t1\ttcp\t*\t8443\t192.0.2.40\t40\tprecise\tconflict\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n' >>"$conflicting"
assert_false "拒绝导入内部协议冲突" vpf_validate_config "$conflicting"

conflict_id="$(vpf_check_rule_conflict "$fixture" 0 tcp '*' 8443)"
if [[ "$conflict_id" == "1" ]]; then
    pass "BOTH 与 TCP 发生冲突"
else
    fail "BOTH 与 TCP 发生冲突"
fi
assert_false "同端口 TCP 与 UDP 不冲突" vpf_check_rule_conflict "$fixture" 0 udp 198.51.100.2 9443
if vpf_check_exact_duplicate "$fixture" 0 both '*' 8443 192.0.2.10 20086 >/dev/null; then
    pass "检测完全重复"
else
    fail "检测完全重复"
fi

printf '1..%d\n' "$TESTS_RUN"
