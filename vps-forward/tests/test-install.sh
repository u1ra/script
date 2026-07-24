#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-helper.sh"

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VPF="$PROJECT_ROOT/vps-forward.sh"

for platform in ubuntu debian alpine; do
    mkdir -p "$VPF_MOCK_DIR"
    : >"$VPF_MOCK_DIR/actions"
    VPF_TEST_PLATFORM="$platform" "$VPF" install --yes
    assert_contains "$platform 包管理分支" "$VPF_MOCK_DIR/actions" "install-packages=$platform"
    if [[ "$platform" == "alpine" ]]; then
        assert_contains "$platform OpenRC 分支" "$VPF_MOCK_DIR/actions" "service=openrc"
    else
        assert_contains "$platform systemd 分支" "$VPF_MOCK_DIR/actions" "service=systemd"
    fi
done

before="$(sha256sum "$VPF_CONFIG_FILE")"
VPF_TEST_PLATFORM=debian "$VPF" install --yes
after="$(sha256sum "$VPF_CONFIG_FILE")"
if [[ "$before" == "$after" ]]; then
    pass "重复 install 保留配置"
else
    fail "重复 install 保留配置"
fi

if [[ -f "$VPF_MOCK_DIR/usr/local/sbin/vps-forward" ]]; then
    pass "安装主程序"
else
    fail "安装主程序"
fi
if [[ -f "$VPF_MOCK_DIR/usr/local/lib/vps-forward/vps-forward-core.sh" ]]; then
    pass "安装核心库"
else
    fail "安装核心库"
fi
assert_contains "开启 IPv4 转发动作" "$VPF_MOCK_DIR/actions" 'sysctl=net.ipv4.ip_forward=1'

"$VPF" uninstall --rules-only --yes
if [[ ! -e "$VPF_MOCK_DIR/active.nft" ]]; then
    pass "rules-only 删除项目表"
else
    fail "rules-only 删除项目表"
fi
if [[ -f "$VPF_CONFIG_FILE" ]]; then
    pass "rules-only 保留配置"
else
    fail "rules-only 保留配置"
fi

VPF_TEST_PLATFORM=debian "$VPF" install --yes
"$VPF" uninstall --keep-config --yes
assert_contains "保守卸载删除程序动作" "$VPF_MOCK_DIR/actions" 'uninstall-program=1'
if [[ -f "$VPF_CONFIG_FILE" ]]; then
    pass "保守卸载保留配置"
else
    fail "保守卸载保留配置"
fi

printf '1..%d\n' "$TESTS_RUN"
