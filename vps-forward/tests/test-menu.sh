#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-helper.sh"

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VPF="$PROJECT_ROOT/vps-forward.sh"
menu_output="$TEST_ROOT/menu-output.txt"
color_output="$TEST_ROOT/menu-color-output.txt"

render_menu() {
    local color_mode="$1"
    VPF_LIB_MODE=1 \
    VPF_COLOR="$color_mode" \
    VPF_MENU_SERVICE_STATE=运行中 \
    VPF_MENU_IP_FORWARD=1 \
    bash -c 'source "$1"; render_main_menu' _ "$VPF"
}

render_menu never >"$menu_output"
assert_contains "菜单显示产品标题" "$menu_output" "VPS FORWARD"
assert_contains "未初始化时显示配置状态" "$menu_output" "未初始化"
assert_contains "菜单显示规则管理分组" "$menu_output" "规则管理"
assert_contains "菜单显示系统诊断分组" "$menu_output" "系统与诊断"
assert_contains "菜单显示数据维护分组" "$menu_output" "数据与维护"
assert_contains "菜单提示 q 退出" "$menu_output" "q 退出当前菜单"

if grep -Fq $'\033[' "$menu_output"; then
    fail "never 模式不输出 ANSI 颜色"
else
    pass "never 模式不输出 ANSI 颜色"
fi

write_fixture_config "$VPF_CONFIG_FILE"
render_menu never >"$menu_output"
assert_contains "菜单汇总规则数量" "$menu_output" "规则 总计 3 / 启用 2 / 禁用 1"
assert_contains "正常配置显示状态" "$menu_output" "配置 ● 正常"

render_menu always >"$color_output"
if grep -Fq $'\033[' "$color_output"; then
    pass "always 模式输出 ANSI 颜色"
else
    fail "always 模式输出 ANSI 颜色"
fi

if VPF_LIB_MODE=1 VPF_SYSTEM_MODE=mock bash -c '
    source "$1"
    menu_pause() { :; }
    menu_run_action false
    [[ "$VPF_MENU_LAST_STATUS" == "1" ]]
' _ "$VPF" >/dev/null 2>&1; then
    pass "菜单捕获失败操作并保留状态"
else
    fail "菜单捕获失败操作并保留状态"
fi

if VPF_LIB_MODE=1 VPF_SYSTEM_MODE=mock bash -c '
    source "$1"
    menu_pause() { :; }
    menu_run_action true
    [[ "$VPF_MENU_LAST_STATUS" == "0" ]]
' _ "$VPF" >/dev/null 2>&1; then
    pass "菜单记录成功操作状态"
else
    fail "菜单记录成功操作状态"
fi

printf '1..%d\n' "$TESTS_RUN"
