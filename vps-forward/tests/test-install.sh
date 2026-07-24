#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-helper.sh"

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VPF="$PROJECT_ROOT/vps-forward.sh"

if [[ "$("$VPF" version)" == "vps-forward 0.1.3" ]]; then
    pass "源码版本为 0.1.3"
else
    fail "源码版本为 0.1.3"
fi

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
    assert_contains "$platform 启动服务前已释放安装锁" "$VPF_MOCK_DIR/actions" "service-restart-lock=free"
    assert_false "$platform 未发生服务自锁" grep -Fq 'service-restart-lock=held' "$VPF_MOCK_DIR/actions"
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
if [[ -L "$VPF_MOCK_DIR/usr/local/bin/vpf" &&
    "$(readlink "$VPF_MOCK_DIR/usr/local/bin/vpf")" == ../sbin/vps-forward ]]; then
    pass "安装 vpf 快捷管理命令"
else
    fail "安装 vpf 快捷管理命令"
fi
assert_contains "开启 IPv4 转发动作" "$VPF_MOCK_DIR/actions" 'sysctl=net.ipv4.ip_forward=1'

# 版本不一致且 --yes 时默认安全升级并保留配置。
printf '0.1.1\n' >"$VPF_MOCK_DIR/installed-version"
: >"$VPF_MOCK_DIR/actions"
upgrade_before="$(sha256sum "$VPF_CONFIG_FILE")"
VPF_TEST_PLATFORM=debian "$VPF" install --yes
upgrade_after="$(sha256sum "$VPF_CONFIG_FILE")"
assert_contains "版本不一致默认选择升级" "$VPF_MOCK_DIR/actions" 'version-action=upgrade'
if [[ "$upgrade_before" == "$upgrade_after" ]]; then
    pass "升级保留配置"
else
    fail "升级保留配置"
fi
if [[ "$(<"$VPF_MOCK_DIR/installed-version")" == "0.1.3" ]]; then
    pass "升级写入新版本"
else
    fail "升级写入新版本"
fi

# 重装会先保守卸载，再恢复程序、快捷命令和项目规则。
printf '0.1.1\n' >"$VPF_MOCK_DIR/installed-version"
: >"$VPF_MOCK_DIR/actions"
VPF_TEST_PLATFORM=debian "$VPF" install --reinstall --yes
assert_contains "版本不一致可选择重装" "$VPF_MOCK_DIR/actions" 'version-action=reinstall'
assert_contains "重装先卸载旧程序" "$VPF_MOCK_DIR/actions" 'uninstall-program=1'
if [[ -L "$VPF_MOCK_DIR/usr/local/bin/vpf" && -f "$VPF_MOCK_DIR/active.nft" ]]; then
    pass "重装恢复快捷命令和规则"
else
    fail "重装恢复快捷命令和规则"
fi

if VPF_TEST_PLATFORM=debian "$VPF" install --upgrade --reinstall --yes >/dev/null 2>&1; then
    fail "拒绝冲突的版本操作"
else
    pass "拒绝冲突的版本操作"
fi

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
: >"$VPF_MOCK_DIR/actions"
VPF_TEST_PLATFORM=debian "$VPF" install --uninstall-existing --yes
assert_contains "重复安装可选择卸载" "$VPF_MOCK_DIR/actions" 'version-action=uninstall'
assert_contains "卸载旧程序动作" "$VPF_MOCK_DIR/actions" 'uninstall-program=1'
if [[ -f "$VPF_CONFIG_FILE" ]]; then
    pass "版本卸载保留配置"
else
    fail "版本卸载保留配置"
fi
if [[ ! -e "$VPF_MOCK_DIR/installed-version" && ! -L "$VPF_MOCK_DIR/usr/local/bin/vpf" ]]; then
    pass "版本卸载移除程序和快捷命令"
else
    fail "版本卸载移除程序和快捷命令"
fi

# 从 /usr/local 的已安装布局打开菜单时，初始化应复用受管理的程序和核心库。
installed_layout="$TEST_ROOT/installed-layout"
layout_mock="$TEST_ROOT/layout-mock"
mkdir -p "$installed_layout/sbin" "$installed_layout/lib"
cp -- "$PROJECT_ROOT/vps-forward.sh" "$installed_layout/sbin/vps-forward"
cp -- "$PROJECT_ROOT/lib/vps-forward-core.sh" "$installed_layout/lib/vps-forward-core.sh"
VPF_LIB_MODE=1 \
VPF_SYSTEM_MODE=mock \
VPF_MOCK_DIR="$layout_mock" \
VPF_INSTALLED_PROGRAM_SOURCE="$installed_layout/sbin/vps-forward" \
VPF_INSTALLED_CORE_SOURCE="$installed_layout/lib/vps-forward-core.sh" \
bash -c 'source "$1"; SCRIPT_DIR=/missing/source; install_program_files' _ "$PROJECT_ROOT/vps-forward.sh"
if [[ -f "$layout_mock/usr/local/sbin/vps-forward" &&
    -f "$layout_mock/usr/local/lib/vps-forward/vps-forward-core.sh" ]]; then
    pass "已安装布局可执行初始化修复"
else
    fail "已安装布局可执行初始化修复"
fi

printf '1..%d\n' "$TESTS_RUN"
