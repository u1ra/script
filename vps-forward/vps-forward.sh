#!/usr/bin/env bash
# vps-forward managed program

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/vps-forward-core.sh" ]]; then
    # shellcheck source=lib/vps-forward-core.sh
    source "$SCRIPT_DIR/lib/vps-forward-core.sh"
elif [[ -f /usr/local/lib/vps-forward/vps-forward-core.sh ]]; then
    # shellcheck disable=SC1091
    source /usr/local/lib/vps-forward/vps-forward-core.sh
else
    printf '错误: 找不到 vps-forward 核心库。\n' >&2
    exit 1
fi

vpf_error_trap() {
    local error_status=$? error_line="$1"
    vpf_log "unexpected error line=$error_line status=$error_status"
    exit "$error_status"
}

trap 'vpf_cleanup' EXIT
trap 'vpf_error_trap "$LINENO"' ERR

usage() {
    cat <<'EOF'
vps-forward - 安全管理 nftables IPv4 四层端口转发

用法:
  vps-forward <命令> [参数]
  vps-forward                    打开交互菜单

命令:
  install [版本操作]             安装依赖、程序、IPv4 转发和启动服务
  add                            新增规则
  list [--json]                  列出规则
  show <ID> [--json]             查看规则
  edit <ID> [规则参数]           修改规则
  delete <ID> --yes              删除规则
  enable|disable <ID>            启用或禁用规则
  apply [--dry-run]              检查并重新应用全部项目规则
  check                          检查配置和生成规则语法
  status [--json]                显示简要状态
  doctor [--json]                只读诊断系统与冲突
  rules                          显示项目实际 nftables 表
  backup                         创建备份
  restore <备份名> --yes         恢复内部备份
  export --output <文件>         导出配置
  import --input <文件> --yes    导入并应用配置
  uninstall --yes [选项]         保守卸载
  help | version

新增/修改参数:
  --name <名称>                  1～64 个字母、数字、空格、点、下划线或连字符
  --listen-ip <IPv4|any>         默认 any（所有本机 IPv4）
  --listen-port <1-65535>        必填
  --target-ip <IPv4>             必填，仅支持 IPv4
  --target-port <1-65535>        必填
  --protocol <tcp|udp|both>      默认 both
  --masquerade-mode <precise|destination>
                                  默认 precise
  --no-masquerade                关闭 Masquerade
  --enabled | --disabled         新增时默认启用
  --dry-run                      只显示候选配置、规则和操作
  --yes                          确认 SSH 端口等风险
  --quiet                        减少普通输出

重复安装的版本操作:
  --upgrade                      保留配置并升级/切换到源码版本
  --reinstall                    保留配置，卸载程序和项目表后重新安装
  --uninstall-existing           卸载现有版本后停止，不继续安装
  --yes                          无交互且版本不一致时默认选择升级

卸载选项:
  --rules-only                   只删除项目 nftables 表
  --keep-config                  删除程序和服务但保留配置（默认）
  --purge                        删除项目配置和备份
  --remove-sysctl                删除项目 sysctl 文件（不主动写 0）
  --remove-package               尝试卸载 nftables（不推荐）

示例:
  vps-forward add --name edge-to-origin --listen-port 8443 \
    --target-ip 192.0.2.10 --target-port 20086 --protocol both
  vps-forward edit 1 --target-port 20087 --masquerade-mode destination
  vps-forward disable 1
  vps-forward delete 1 --yes
EOF
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

normalize_listen_ip() {
    if [[ "$1" == "any" || "$1" == "*" || -z "$1" ]]; then
        printf '*\n'
    else
        printf '%s\n' "$1"
    fi
}

set_common_flag() {
    case "$1" in
        --dry-run) VPF_DRY_RUN=1 ;;
        --yes) VPF_ASSUME_YES=1 ;;
        --quiet) VPF_QUIET=1 ;;
        *) return 1 ;;
    esac
}

prepare_mutation() {
    local empty_config
    if [[ "$VPF_DRY_RUN" == "1" ]]; then
        VPF_TEMP_PARENT="${TMPDIR:-/tmp}"
        if [[ -f "$VPF_CONFIG_FILE" && ! -L "$VPF_CONFIG_FILE" ]]; then
            vpf_validate_config "$VPF_CONFIG_FILE"
        elif [[ ! -e "$VPF_CONFIG_FILE" ]]; then
            empty_config="$(vpf_make_tmp "$VPF_TEMP_PARENT")"
            vpf_write_empty_config "$empty_config"
            VPF_CONFIG_FILE="$empty_config"
        else
            vpf_die "配置路径存在但不是安全的普通文件: $VPF_CONFIG_FILE"
        fi
        return 0
    fi
    vpf_require_root
    vpf_acquire_lock
    vpf_ensure_config
    vpf_validate_config "$VPF_CONFIG_FILE"
}

validate_rule_values() {
    local name="$1" protocol="$2" listen_ip="$3" listen_port="$4"
    local target_ip="$5" target_port="$6" masq="$7"
    vpf_valid_name "$name" || vpf_die "规则名称无效（允许 1～64 个字母、数字、空格、点、下划线和连字符）"
    vpf_valid_protocol "$protocol" || vpf_die "协议必须是 tcp、udp 或 both"
    vpf_valid_listen_ip "$listen_ip" || vpf_die "监听地址必须是有效 IPv4 或 any"
    vpf_valid_port "$listen_port" || vpf_die "入口端口必须在 1～65535"
    vpf_valid_ipv4 "$target_ip" || vpf_die "目标地址必须是有效 IPv4"
    vpf_valid_port "$target_port" || vpf_die "目标端口必须在 1～65535"
    vpf_valid_masq_mode "$masq" || vpf_die "Masquerade 模式必须是 precise、destination 或 none"
}

warn_port_risk() {
    local protocol="$1" listen_ip="$2" port="$3" output=""
    [[ "$VPF_SYSTEM_MODE" == "real" && -x "$(command -v ss 2>/dev/null || true)" ]] || return 0
    output="$(ss -H -lntup 2>/dev/null || true)"
    if grep -Eq "(^|[[:space:]])([^[:space:]]*:)?${port}([[:space:]]|$)" <<<"$output"; then
        vpf_warn "端口 $port 似乎已被本机服务占用；此检查只是提示，仍需自行确认绑定 IP 和协议。"
    fi
    if grep -Ei "([^[:space:]]*:)?${port}([[:space:]]|$).*sshd|sshd.*([^[:space:]]*:)?${port}([[:space:]]|$)" <<<"$output" >/dev/null; then
        vpf_warn "端口 $port 可能是当前 SSH 管理端口，错误转发可能导致断连。"
        [[ "$VPF_ASSUME_YES" == "1" ]] || vpf_die "如确认继续，请重新执行并添加 --yes"
    fi
    if [[ "$protocol" == "udp" ]]; then
        vpf_warn "UDP 端口监听检测不能证明端口一定可用。"
    fi
    return 0
}

check_new_rule_conflicts() {
    local file="$1" ignore_id="$2" protocol="$3" listen_ip="$4" listen_port="$5"
    local target_ip="$6" target_port="$7" existing
    if existing="$(vpf_check_exact_duplicate "$file" "$ignore_id" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port")"; then
        vpf_die "与规则 ID $existing 完全重复"
        return
    fi
    if existing="$(vpf_check_rule_conflict "$file" "$ignore_id" "$protocol" "$listen_ip" "$listen_port")"; then
        vpf_die "入口端口/协议/监听地址与规则 ID $existing 冲突"
        return
    fi
}

cmd_add() {
    local name="" protocol="both" listen_ip="*" listen_port="" target_ip="" target_port=""
    local masq="precise" enabled=1 masq_option_seen=0 no_masq_seen=0 id now candidate
    while (($#)); do
        case "$1" in
            --name) [[ $# -ge 2 ]] || vpf_die "--name 缺少值"; name="$2"; shift 2 ;;
            --protocol) [[ $# -ge 2 ]] || vpf_die "--protocol 缺少值"; protocol="${2,,}"; shift 2 ;;
            --listen-ip) [[ $# -ge 2 ]] || vpf_die "--listen-ip 缺少值"; listen_ip="$(normalize_listen_ip "$2")"; shift 2 ;;
            --listen-port) [[ $# -ge 2 ]] || vpf_die "--listen-port 缺少值"; listen_port="$2"; shift 2 ;;
            --target-ip) [[ $# -ge 2 ]] || vpf_die "--target-ip 缺少值"; target_ip="$2"; shift 2 ;;
            --target-port) [[ $# -ge 2 ]] || vpf_die "--target-port 缺少值"; target_port="$2"; shift 2 ;;
            --masquerade-mode)
                [[ $# -ge 2 ]] || vpf_die "--masquerade-mode 缺少值"
                masq="${2,,}"; masq_option_seen=1; shift 2
                ;;
            --no-masquerade) masq="none"; no_masq_seen=1; shift ;;
            --enabled) enabled=1; shift ;;
            --disabled) enabled=0; shift ;;
            --dry-run|--yes|--quiet) set_common_flag "$1"; shift ;;
            *) vpf_die "add 的未知参数: $1" ;;
        esac
    done
    [[ "$masq_option_seen" == "0" || "$no_masq_seen" == "0" ]] ||
        vpf_die "--no-masquerade 不能与 --masquerade-mode 同时使用"
    [[ -n "$listen_port" && -n "$target_ip" && -n "$target_port" ]] ||
        vpf_die "add 必须提供 --listen-port、--target-ip 和 --target-port"

    prepare_mutation
    id="$(vpf_next_id "$VPF_CONFIG_FILE")"
    [[ -n "$name" ]] || name="forward-$id"
    validate_rule_values "$name" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$masq"
    check_new_rule_conflicts "$VPF_CONFIG_FILE" 0 "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port"
    if [[ "$masq" == "none" ]]; then
        vpf_warn "已关闭 Masquerade：目标 VPS 必须具备正确回程路由，否则会出现非对称路由，TCP/UDP 可能无法通信。"
    fi
    warn_port_risk "$protocol" "$listen_ip" "$listen_port"
    now="$(vpf_now)"
    candidate="$(vpf_make_tmp)"
    cp -- "$VPF_CONFIG_FILE" "$candidate"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$enabled" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port" \
        "$masq" "$name" "$now" "$now" >>"$candidate"
    vpf_commit_candidate "$candidate" "add-$id"
    vpf_info "规则 $id 已新增。"
}

print_rule_json() {
    local id="$1" enabled="$2" protocol="$3" listen_ip="$4" listen_port="$5"
    local target_ip="$6" target_port="$7" masq="$8" name="$9" created="${10}" updated="${11}"
    printf '{"id":%s,"name":"%s","enabled":%s,"protocol":"%s","listen_ip":' \
        "$id" "$(json_escape "$name")" "$([[ "$enabled" == 1 ]] && printf true || printf false)" "$protocol"
    if [[ "$listen_ip" == "*" ]]; then
        printf 'null'
    else
        printf '"%s"' "$listen_ip"
    fi
    printf ',"listen_port":%s,"target_ip":"%s","target_port":%s,"masquerade_mode":"%s","created_at":"%s","updated_at":"%s"}' \
        "$listen_port" "$target_ip" "$target_port" "$masq" "$created" "$updated"
}

cmd_list() {
    local json=0 first=1 id enabled protocol listen_ip listen_port target_ip target_port masq name created updated
    while (($#)); do
        case "$1" in
            --json) json=1; shift ;;
            --quiet) VPF_QUIET=1; shift ;;
            *) vpf_die "list 的未知参数: $1" ;;
        esac
    done
    vpf_ensure_config
    vpf_validate_config "$VPF_CONFIG_FILE"
    if [[ "$json" == "1" ]]; then
        printf '['
    else
        printf '%-5s %-4s %-8s %-15s %-6s %-15s %-6s %-11s %s\n' \
            ID 状态 协议 监听IP 入口 目标IP 目标端口 Masquerade 名称
    fi
    while IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated; do
        [[ "$id" =~ ^[1-9][0-9]*$ ]] || continue
        if [[ "$json" == "1" ]]; then
            [[ "$first" == "1" ]] || printf ','
            print_rule_json "$id" "$enabled" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$masq" "$name" "$created" "$updated"
            first=0
        else
            printf '%-5s %-4s %-8s %-15s %-6s %-15s %-6s %-11s %s\n' \
                "$id" "$([[ "$enabled" == 1 ]] && printf 启用 || printf 禁用)" "$protocol" \
                "$([[ "$listen_ip" == "*" ]] && printf any || printf '%s' "$listen_ip")" \
                "$listen_port" "$target_ip" "$target_port" "$masq" "$name"
        fi
    done <"$VPF_CONFIG_FILE"
    if [[ "$json" == "1" ]]; then
        printf ']\n'
    fi
}

cmd_show() {
    local id="${1:-}" json=0 line
    [[ "$id" =~ ^[1-9][0-9]*$ ]] || vpf_die "show 需要有效数字 ID"
    shift || true
    while (($#)); do
        case "$1" in
            --json) json=1 ;;
            *) vpf_die "show 的未知参数: $1" ;;
        esac
        shift
    done
    vpf_ensure_config
    line="$(vpf_get_rule "$id" "$VPF_CONFIG_FILE")" || vpf_die "规则 ID $id 不存在"
    IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated <<<"$line"
    if [[ "$json" == "1" ]]; then
        print_rule_json "$id" "$enabled" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$masq" "$name" "$created" "$updated"
        printf '\n'
    else
        printf 'ID: %s\n名称: %s\n状态: %s\n协议: %s\n监听 IP: %s\n入口端口: %s\n目标: %s:%s\nMasquerade: %s\n创建: %s\n更新: %s\n' \
            "$id" "$name" "$([[ "$enabled" == 1 ]] && printf 启用 || printf 禁用)" "$protocol" \
            "$([[ "$listen_ip" == "*" ]] && printf any || printf '%s' "$listen_ip")" "$listen_port" \
            "$target_ip" "$target_port" "$masq" "$created" "$updated"
    fi
}

replace_rule_in_candidate() {
    local source="$1" output="$2" wanted="$3" replacement="$4" line id
    : >"$output"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == \#* || -z "$line" ]]; then
            printf '%s\n' "$line" >>"$output"
            continue
        fi
        IFS=$'\t' read -r id _ <<<"$line"
        if [[ "$id" == "$wanted" ]]; then
            [[ -n "$replacement" ]] && printf '%s\n' "$replacement" >>"$output"
        else
            printf '%s\n' "$line" >>"$output"
        fi
    done <"$source"
    return 0
}

cmd_edit() {
    local wanted="${1:-}" line id enabled protocol listen_ip listen_port target_ip target_port masq name created updated
    local new_name="" new_protocol="" new_listen_ip="" new_listen_port="" new_target_ip="" new_target_port=""
    local new_masq="" new_enabled="" edit_masq_seen=0 no_masq_seen=0 candidate replacement
    [[ "$wanted" =~ ^[1-9][0-9]*$ ]] || vpf_die "edit 需要有效数字 ID"
    shift || true
    while (($#)); do
        case "$1" in
            --name) [[ $# -ge 2 ]] || vpf_die "--name 缺少值"; new_name="$2"; shift 2 ;;
            --protocol) [[ $# -ge 2 ]] || vpf_die "--protocol 缺少值"; new_protocol="${2,,}"; shift 2 ;;
            --listen-ip) [[ $# -ge 2 ]] || vpf_die "--listen-ip 缺少值"; new_listen_ip="$(normalize_listen_ip "$2")"; shift 2 ;;
            --listen-port) [[ $# -ge 2 ]] || vpf_die "--listen-port 缺少值"; new_listen_port="$2"; shift 2 ;;
            --target-ip) [[ $# -ge 2 ]] || vpf_die "--target-ip 缺少值"; new_target_ip="$2"; shift 2 ;;
            --target-port) [[ $# -ge 2 ]] || vpf_die "--target-port 缺少值"; new_target_port="$2"; shift 2 ;;
            --masquerade-mode)
                [[ $# -ge 2 ]] || vpf_die "--masquerade-mode 缺少值"
                new_masq="${2,,}"; edit_masq_seen=1; shift 2
                ;;
            --no-masquerade) new_masq="none"; no_masq_seen=1; shift ;;
            --enabled) new_enabled=1; shift ;;
            --disabled) new_enabled=0; shift ;;
            --dry-run|--yes|--quiet) set_common_flag "$1"; shift ;;
            *) vpf_die "edit 的未知参数: $1" ;;
        esac
    done
    [[ "$edit_masq_seen" == "0" || "$no_masq_seen" == "0" ]] ||
        vpf_die "--no-masquerade 不能与 --masquerade-mode 同时使用"
    prepare_mutation
    line="$(vpf_get_rule "$wanted")" || vpf_die "规则 ID $wanted 不存在"
    IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated <<<"$line"
    [[ -z "$new_name" ]] || name="$new_name"
    [[ -z "$new_protocol" ]] || protocol="$new_protocol"
    [[ -z "$new_listen_ip" ]] || listen_ip="$new_listen_ip"
    [[ -z "$new_listen_port" ]] || listen_port="$new_listen_port"
    [[ -z "$new_target_ip" ]] || target_ip="$new_target_ip"
    [[ -z "$new_target_port" ]] || target_port="$new_target_port"
    [[ -z "$new_masq" ]] || masq="$new_masq"
    [[ -z "$new_enabled" ]] || enabled="$new_enabled"
    validate_rule_values "$name" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$masq"
    check_new_rule_conflicts "$VPF_CONFIG_FILE" "$wanted" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port"
    [[ "$masq" != "none" ]] ||
        vpf_warn "Masquerade 已关闭；请确认目标端具备正确回程路由。"
    warn_port_risk "$protocol" "$listen_ip" "$listen_port"
    updated="$(vpf_now)"
    printf -v replacement '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$id" "$enabled" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$masq" "$name" "$created" "$updated"
    candidate="$(vpf_make_tmp)"
    replace_rule_in_candidate "$VPF_CONFIG_FILE" "$candidate" "$wanted" "$replacement"
    vpf_commit_candidate "$candidate" "edit-$wanted"
    vpf_info "规则 $wanted 已更新。"
}

cmd_delete() {
    local wanted="${1:-}" candidate
    [[ "$wanted" =~ ^[1-9][0-9]*$ ]] || vpf_die "delete 需要有效数字 ID"
    shift || true
    while (($#)); do
        case "$1" in
            --yes|--dry-run|--quiet) set_common_flag "$1"; shift ;;
            *) vpf_die "delete 的未知参数: $1" ;;
        esac
    done
    [[ "$VPF_ASSUME_YES" == "1" || "$VPF_DRY_RUN" == "1" ]] ||
        vpf_die "删除需要显式确认，请添加 --yes"
    prepare_mutation
    vpf_rule_exists "$wanted" || vpf_die "规则 ID $wanted 不存在"
    candidate="$(vpf_make_tmp)"
    replace_rule_in_candidate "$VPF_CONFIG_FILE" "$candidate" "$wanted" ""
    vpf_commit_candidate "$candidate" "delete-$wanted"
    vpf_info "规则 $wanted 已删除。"
}

cmd_set_enabled() {
    local wanted="$1" desired="$2" line id enabled protocol listen_ip listen_port target_ip target_port masq name created updated
    local replacement candidate
    shift 2
    while (($#)); do
        case "$1" in
            --dry-run|--quiet) set_common_flag "$1"; shift ;;
            *) vpf_die "未知参数: $1" ;;
        esac
    done
    [[ "$wanted" =~ ^[1-9][0-9]*$ ]] || vpf_die "需要有效数字 ID"
    prepare_mutation
    line="$(vpf_get_rule "$wanted")" || vpf_die "规则 ID $wanted 不存在"
    IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated <<<"$line"
    [[ "$enabled" != "$desired" ]] || {
        vpf_info "规则 $wanted 已是目标状态，无需修改。"
        return 0
    }
    updated="$(vpf_now)"
    printf -v replacement '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$id" "$desired" "$protocol" "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$masq" "$name" "$created" "$updated"
    candidate="$(vpf_make_tmp)"
    replace_rule_in_candidate "$VPF_CONFIG_FILE" "$candidate" "$wanted" "$replacement"
    vpf_commit_candidate "$candidate" "$([[ "$desired" == 1 ]] && printf enable || printf disable)-$wanted"
    vpf_info "规则 $wanted 已$([[ "$desired" == 1 ]] && printf 启用 || printf 禁用)。"
}

cmd_apply() {
    while (($#)); do
        case "$1" in
            --dry-run|--yes|--quiet) set_common_flag "$1"; shift ;;
            --boot) VPF_QUIET=1; shift ;;
            *) vpf_die "apply 的未知参数: $1" ;;
        esac
    done
    prepare_mutation
    vpf_apply_current
    vpf_info "项目规则已应用。"
}

cmd_check() {
    local rules transaction
    while (($#)); do
        case "$1" in
            --quiet) VPF_QUIET=1; shift ;;
            *) vpf_die "check 的未知参数: $1" ;;
        esac
    done
    vpf_ensure_config
    vpf_validate_config "$VPF_CONFIG_FILE"
    rules="$(vpf_make_tmp)"
    transaction="$(vpf_make_tmp)"
    vpf_generate_ruleset "$VPF_CONFIG_FILE" "$rules"
    vpf_build_transaction "$rules" "$transaction"
    vpf_nft_check "$transaction" || vpf_die "nftables 语法检查失败"
    vpf_info "配置格式、输入约束和 nftables 规则语法检查通过。"
}

detect_os() {
    local id="unknown" version=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        id="${ID:-unknown}"
        version="${VERSION_ID:-}"
    fi
    printf '%s\t%s\n' "$id" "$version"
}

service_state() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-enabled vps-forward.service 2>/dev/null || printf '未启用'
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service vps-forward status >/dev/null 2>&1 && printf '运行中' || printf '未运行'
    else
        printf '无可用服务管理器'
    fi
}

count_rules() {
    local mode="$1"
    awk -F '\t' -v mode="$mode" '
        $1 ~ /^[1-9][0-9]*$/ {
            if (mode == "all" || (mode == "enabled" && $2 == "1") || (mode == "disabled" && $2 == "0")) n++
        }
        END { print n + 0 }
    ' "$VPF_CONFIG_FILE"
}

project_tables_state() {
    if vpf_table_exists ip vps_forward_nat && vpf_table_exists inet vps_forward_filter; then
        printf 'present'
    else
        printf 'missing'
    fi
}

config_sync_state() {
    local candidate actual expected_count actual_count expected_comment
    candidate="$(vpf_make_tmp)"
    vpf_generate_ruleset "$VPF_CONFIG_FILE" "$candidate" >/dev/null 2>&1 || {
        printf 'invalid'
        return
    }
    if [[ "$VPF_SYSTEM_MODE" == "mock" && -f "$VPF_MOCK_DIR/active.nft" ]]; then
        cmp -s "$candidate" "$VPF_MOCK_DIR/active.nft" && printf 'synced' || printf 'different'
    else
        command -v "$VPF_NFT_BIN" >/dev/null 2>&1 || {
            printf 'unknown'
            return
        }
        actual="$(
            "$VPF_NFT_BIN" list table ip vps_forward_nat 2>/dev/null
            "$VPF_NFT_BIN" list table inet vps_forward_filter 2>/dev/null
        )" || {
            printf 'unknown'
            return
        }
        grep -Fq "$VPF_MARK" <<<"$actual" || {
            printf 'different'
            return
        }
        expected_count="$(grep -Fc 'comment "vps-forward id=' "$candidate" || true)"
        actual_count="$(grep -Fc 'comment "vps-forward id=' <<<"$actual" || true)"
        [[ "$expected_count" == "$actual_count" ]] || {
            printf 'different'
            return
        }
        while IFS= read -r expected_comment; do
            [[ -z "$expected_comment" ]] && continue
            grep -Fq "$expected_comment" <<<"$actual" || {
                printf 'different'
                return
            }
        done < <(sed -n 's/.*\\(comment "vps-forward id=[^"]*"\\).*/\\1/p' "$candidate" | sort -u)
        printf 'synced'
    fi
}

cmd_status() {
    local json=0 os_line os_id os_version nft_version="未安装" ip_forward="未知" service tables sync
    local total enabled disabled last_apply="" last_backup=""
    while (($#)); do
        case "$1" in
            --json) json=1; shift ;;
            --quiet) VPF_QUIET=1; shift ;;
            *) vpf_die "status 的未知参数: $1" ;;
        esac
    done
    vpf_ensure_config
    vpf_validate_config "$VPF_CONFIG_FILE"
    os_line="$(detect_os)"
    IFS=$'\t' read -r os_id os_version <<<"$os_line"
    command -v "$VPF_NFT_BIN" >/dev/null 2>&1 && nft_version="$("$VPF_NFT_BIN" --version 2>/dev/null | head -1)"
    [[ -r /proc/sys/net/ipv4/ip_forward ]] && ip_forward="$(</proc/sys/net/ipv4/ip_forward)"
    service="$(service_state)"
    tables="$(project_tables_state)"
    sync="$(config_sync_state)"
    total="$(count_rules all)"
    enabled="$(count_rules enabled)"
    disabled="$(count_rules disabled)"
    if [[ -f "$VPF_STATE_FILE" && ! -L "$VPF_STATE_FILE" ]]; then
        last_apply="$(sed -n 's/^last_apply=//p' "$VPF_STATE_FILE")"
        last_backup="$(sed -n 's/^last_backup=//p' "$VPF_STATE_FILE")"
    fi
    if [[ "$json" == "1" ]]; then
        printf '{"version":"%s","os":"%s","os_version":"%s","nftables":"%s","service":"%s","ipv4_forward":%s,' \
            "$VPF_VERSION" "$(json_escape "$os_id")" "$(json_escape "$os_version")" "$(json_escape "$nft_version")" \
            "$(json_escape "$service")" "$([[ "$ip_forward" =~ ^[01]$ ]] && printf '%s' "$ip_forward" || printf null)"
        printf '"config_path":"%s","rules":{"total":%s,"enabled":%s,"disabled":%s},"tables":"%s","sync":"%s","last_apply":"%s","last_backup":"%s"}\n' \
            "$(json_escape "$VPF_CONFIG_FILE")" "$total" "$enabled" "$disabled" "$tables" "$sync" \
            "$(json_escape "$last_apply")" "$(json_escape "$last_backup")"
    else
        printf 'vps-forward: %s\n系统: %s %s\nnftables: %s\n服务: %s\nIPv4 转发: %s\n配置: %s\n规则: 总计 %s / 启用 %s / 禁用 %s\n项目表: %s\n配置同步: %s\n最近应用: %s\n最近备份: %s\n' \
            "$VPF_VERSION" "$os_id" "$os_version" "$nft_version" "$service" "$ip_forward" "$VPF_CONFIG_FILE" \
            "$total" "$enabled" "$disabled" "$tables" "$sync" "${last_apply:-无}" "${last_backup:-无}"
    fi
}

detect_conflicts() {
    local name state
    for name in ufw firewalld docker fail2ban; do
        state=0
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$name" 2>/dev/null; then
            state=1
        elif command -v rc-service >/dev/null 2>&1 && rc-service "$name" status >/dev/null 2>&1; then
            state=1
        elif pgrep -x "$name" >/dev/null 2>&1; then
            state=1
        fi
        printf '%s=%s\n' "$name" "$state"
    done
    command -v iptables-nft >/dev/null 2>&1 && printf 'iptables_nft=1\n' || printf 'iptables_nft=0\n'
}

cmd_doctor() {
    local json=0 conflicts nft_rules="未知" owner="ok"
    while (($#)); do
        case "$1" in
            --json) json=1; shift ;;
            *) vpf_die "doctor 的未知参数: $1" ;;
        esac
    done
    vpf_ensure_config
    if ! vpf_validate_config "$VPF_CONFIG_FILE"; then
        owner="config-invalid"
    elif ! vpf_verify_table_owner ip vps_forward_nat || ! vpf_verify_table_owner inet vps_forward_filter; then
        owner="foreign-table"
    fi
    conflicts="$(detect_conflicts)"
    if [[ "$VPF_SYSTEM_MODE" == "real" ]] && command -v "$VPF_NFT_BIN" >/dev/null 2>&1; then
        nft_rules="$("$VPF_NFT_BIN" list ruleset 2>/dev/null | wc -l | tr -d ' ')"
    fi
    if [[ "$json" == "1" ]]; then
        printf '{"config":"%s","existing_ruleset_lines":"%s","services":{' "$owner" "$(json_escape "$nft_rules")"
        printf '"ufw":%s,"firewalld":%s,"docker":%s,"fail2ban":%s,"iptables_nft":%s}}\n' \
            "$(sed -n 's/^ufw=//p' <<<"$conflicts")" "$(sed -n 's/^firewalld=//p' <<<"$conflicts")" \
            "$(sed -n 's/^docker=//p' <<<"$conflicts")" "$(sed -n 's/^fail2ban=//p' <<<"$conflicts")" \
            "$(sed -n 's/^iptables_nft=//p' <<<"$conflicts")"
    else
        cmd_status
        printf '\n只读冲突检测:\n%s\n现有 ruleset 行数: %s\n项目所有权/配置: %s\n' "$conflicts" "$nft_rules" "$owner"
        vpf_warn "其他 base chain（包括 UFW/firewalld/用户规则）若稍后 drop，项目 accept 规则仍可能无法放行；doctor 只能提示，不能证明完全兼容。"
    fi
    [[ "$owner" == "ok" ]]
}

cmd_rules() {
    vpf_require_root
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        if [[ -f "$VPF_MOCK_DIR/active.nft" ]]; then
            cat -- "$VPF_MOCK_DIR/active.nft"
        else
            vpf_die "项目规则尚未应用"
        fi
    else
        vpf_verify_table_owner ip vps_forward_nat
        vpf_verify_table_owner inet vps_forward_filter
        "$VPF_NFT_BIN" list table ip vps_forward_nat
        "$VPF_NFT_BIN" list table inet vps_forward_filter
    fi
}

cmd_backup() {
    local destination
    while (($#)); do
        case "$1" in
            --quiet) VPF_QUIET=1; shift ;;
            *) vpf_die "backup 的未知参数: $1" ;;
        esac
    done
    vpf_require_root
    vpf_acquire_lock
    vpf_ensure_config
    vpf_validate_config "$VPF_CONFIG_FILE"
    destination="$(vpf_backup_create manual)"
    vpf_info "备份完成: $destination"
}

validate_backup_name() {
    [[ "$1" =~ ^backup-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
}

cmd_restore() {
    local name="${1:-}" directory candidate current_backup
    validate_backup_name "$name" || vpf_die "备份名无效；只能使用 backup 命令显示的内部名称"
    shift || true
    while (($#)); do
        case "$1" in
            --yes|--dry-run|--quiet) set_common_flag "$1"; shift ;;
            *) vpf_die "restore 的未知参数: $1" ;;
        esac
    done
    [[ "$VPF_ASSUME_YES" == "1" || "$VPF_DRY_RUN" == "1" ]] || vpf_die "恢复需要 --yes"
    prepare_mutation
    directory="$VPF_BACKUP_DIR/$name"
    [[ -d "$directory" && ! -L "$directory" && -f "$directory/manifest" && ! -L "$directory/manifest" ]] ||
        vpf_die "备份不存在或格式不安全: $name"
    grep -Fxq "schema=$VPF_SCHEMA" "$directory/manifest" || vpf_die "备份 schema 不兼容"
    [[ -f "$directory/config.tsv" && ! -L "$directory/config.tsv" ]] || vpf_die "备份缺少配置"
    vpf_validate_config "$directory/config.tsv"
    current_backup="$(vpf_backup_create pre-restore)"
    vpf_info "恢复前状态已备份到 $current_backup"
    candidate="$(vpf_make_tmp)"
    cp -- "$directory/config.tsv" "$candidate"
    vpf_commit_candidate "$candidate" "restore-$name"
    vpf_info "已恢复备份 $name。"
}

cmd_export() {
    local output=""
    while (($#)); do
        case "$1" in
            --output) [[ $# -ge 2 ]] || vpf_die "--output 缺少值"; output="$2"; shift 2 ;;
            *) vpf_die "export 的未知参数: $1" ;;
        esac
    done
    [[ "$output" == /* ]] || vpf_die "导出路径必须是绝对路径"
    vpf_ensure_config
    vpf_validate_config "$VPF_CONFIG_FILE"
    [[ ! -L "$output" ]] || vpf_die "拒绝覆盖符号链接"
    [[ -d "$(dirname -- "$output")" ]] || vpf_die "导出目录不存在"
    vpf_atomic_copy "$VPF_CONFIG_FILE" "$output"
    vpf_info "配置已导出到 $output"
}

cmd_import() {
    local input="" candidate
    while (($#)); do
        case "$1" in
            --input) [[ $# -ge 2 ]] || vpf_die "--input 缺少值"; input="$2"; shift 2 ;;
            --yes|--dry-run|--quiet) set_common_flag "$1"; shift ;;
            *) vpf_die "import 的未知参数: $1" ;;
        esac
    done
    [[ -n "$input" && -f "$input" && ! -L "$input" ]] || vpf_die "导入源必须是安全的普通文件"
    [[ "$VPF_ASSUME_YES" == "1" || "$VPF_DRY_RUN" == "1" ]] || vpf_die "导入需要 --yes"
    prepare_mutation
    vpf_validate_config "$input"
    candidate="$(vpf_make_tmp)"
    cp -- "$input" "$candidate"
    vpf_commit_candidate "$candidate" import
    vpf_info "配置导入并应用成功。"
}

detect_platform() {
    local id_like=""
    if [[ "$VPF_SYSTEM_MODE" == "mock" && -n "${VPF_TEST_PLATFORM:-}" ]]; then
        case "$VPF_TEST_PLATFORM" in
            ubuntu|debian|alpine) printf '%s\n' "$VPF_TEST_PLATFORM"; return 0 ;;
            *) vpf_die "测试平台值无效: $VPF_TEST_PLATFORM" ;;
        esac
    fi
    [[ -r /etc/os-release ]] || vpf_die "无法识别系统：缺少 /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    id_like="${ID_LIKE:-}"
    case "${ID:-}" in
        ubuntu) printf 'ubuntu\n' ;;
        debian) printf 'debian\n' ;;
        alpine) printf 'alpine\n' ;;
        *)
            if [[ " $id_like " == *" debian "* ]]; then
                printf 'debian\n'
            else
                vpf_die "不支持的系统: ${ID:-unknown}；仅支持 Ubuntu、Debian、Alpine"
            fi
            ;;
    esac
}

install_packages() {
    local platform="$1"
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        printf 'install-packages=%s\n' "$platform" >>"$VPF_MOCK_DIR/actions"
        return
    fi
    case "$platform" in
        ubuntu|debian)
            command -v apt-get >/dev/null 2>&1 || vpf_die "系统缺少 apt-get"
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y nftables iproute2 util-linux
            ;;
        alpine)
            command -v apk >/dev/null 2>&1 || vpf_die "系统缺少 apk"
            apk add --no-cache bash nftables iproute2 util-linux
            ;;
    esac
}

detect_installed_version() {
    local program=/usr/local/sbin/vps-forward output version
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        if [[ -n "${VPF_MOCK_INSTALLED_VERSION:-}" ]]; then
            printf '%s\n' "$VPF_MOCK_INSTALLED_VERSION"
            return 0
        fi
        if [[ -f "$VPF_MOCK_DIR/installed-version" ]]; then
            read -r version <"$VPF_MOCK_DIR/installed-version"
            printf '%s\n' "$version"
            return 0
        fi
        return 2
    fi
    if [[ ! -e "$program" && ! -L "$program" ]]; then
        return 2
    fi
    [[ -f "$program" && ! -L "$program" ]] || {
        vpf_die "检测到不安全的已安装程序路径: $program"
        return 1
    }
    grep -Fq '# vps-forward managed program' "$program" || {
        vpf_die "检测到同名但不属于本项目的程序: $program"
        return 1
    }
    output="$("$program" version 2>/dev/null)" || {
        vpf_die "无法读取已安装 vps-forward 的版本"
        return 1
    }
    version="${output#vps-forward }"
    [[ "$version" =~ ^[0-9]+([.][0-9A-Za-z-]+)+$ ]] || {
        vpf_die "已安装程序返回了无效版本: $output"
        return 1
    }
    printf '%s\n' "$version"
}

choose_install_action() {
    local installed_version="$1" requested_action="$2" choice
    if [[ -n "$requested_action" ]]; then
        printf '%s\n' "$requested_action"
        return 0
    fi
    if [[ "$installed_version" == "$VPF_VERSION" ]]; then
        printf 'repair\n'
        return 0
    fi
    if [[ "$VPF_ASSUME_YES" == "1" ]]; then
        printf 'upgrade\n'
        return 0
    fi
    [[ -t 0 ]] || {
        vpf_die "检测到版本 $installed_version，与待安装版本 $VPF_VERSION 不一致；无交互环境请指定 --upgrade、--reinstall 或 --uninstall-existing"
        return 1
    }
    while true; do
        {
            printf '\n检测到已安装 vps-forward %s，当前源码版本为 %s。\n' "$installed_version" "$VPF_VERSION"
            printf '1. 升级/切换版本（推荐，保留配置和备份）\n'
            printf '2. 重装（保留配置，重建程序、服务和项目规则）\n'
            printf '3. 卸载现有版本（保留配置，不继续安装）\n'
            printf '0. 取消\n'
            printf '请选择 [1]: '
        } >&2
        read -r choice || return 1
        case "${choice:-1}" in
            1) printf 'upgrade\n'; return 0 ;;
            2) printf 'reinstall\n'; return 0 ;;
            3) printf 'uninstall\n'; return 0 ;;
            0) printf 'cancel\n'; return 0 ;;
            *) vpf_warn "无效选择，请重新输入。" ;;
        esac
    done
}

write_owned_file() {
    local source="$1" destination="$2" marker="$3"
    if [[ -e "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] || vpf_die "拒绝覆盖非普通文件: $destination"
        grep -Fq "$marker" "$destination" || vpf_die "拒绝覆盖不属于本项目的文件: $destination"
    fi
    vpf_atomic_copy "$source" "$destination"
}

install_program_files() {
    local main_source="$SCRIPT_DIR/vps-forward.sh" core_source="$SCRIPT_DIR/lib/vps-forward-core.sh"
    local installed_main="${VPF_INSTALLED_PROGRAM_SOURCE:-/usr/local/sbin/vps-forward}"
    local installed_core="${VPF_INSTALLED_CORE_SOURCE:-/usr/local/lib/vps-forward/vps-forward-core.sh}"
    local source_is_installed=0
    local shortcut=/usr/local/bin/vpf
    if [[ ! -f "$main_source" || ! -f "$core_source" ]]; then
        if [[ -f "$installed_main" && ! -L "$installed_main" &&
            -f "$installed_core" && ! -L "$installed_core" ]] &&
            grep -Fq '# vps-forward managed program' "$installed_main" &&
            grep -Fq '# vps-forward managed core library' "$installed_core"; then
            main_source="$installed_main"
            core_source="$installed_core"
            source_is_installed=1
        else
            vpf_die "找不到完整源码或已安装程序文件，无法初始化环境"
            return
        fi
    fi
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        mkdir -p "$VPF_MOCK_DIR/usr/local/sbin" "$VPF_MOCK_DIR/usr/local/bin" \
            "$VPF_MOCK_DIR/usr/local/lib/vps-forward"
        cp -- "$main_source" "$VPF_MOCK_DIR/usr/local/sbin/vps-forward"
        cp -- "$core_source" "$VPF_MOCK_DIR/usr/local/lib/vps-forward/"
        rm -f -- "$VPF_MOCK_DIR/usr/local/bin/vpf"
        ln -s ../sbin/vps-forward "$VPF_MOCK_DIR/usr/local/bin/vpf"
        printf '%s\n' "$VPF_VERSION" >"$VPF_MOCK_DIR/installed-version"
        return
    fi
    if [[ -e /usr/local/sbin/vps-forward ]]; then
        [[ -f /usr/local/sbin/vps-forward && ! -L /usr/local/sbin/vps-forward ]] ||
            vpf_die "拒绝覆盖非普通程序文件: /usr/local/sbin/vps-forward"
        grep -Fq '# vps-forward managed program' /usr/local/sbin/vps-forward ||
            vpf_die "拒绝覆盖不属于本项目的程序: /usr/local/sbin/vps-forward"
    fi
    if [[ -e /usr/local/lib/vps-forward/vps-forward-core.sh ]]; then
        [[ -f /usr/local/lib/vps-forward/vps-forward-core.sh &&
            ! -L /usr/local/lib/vps-forward/vps-forward-core.sh ]] ||
            vpf_die "拒绝覆盖非普通核心库文件"
        grep -Fq '# vps-forward managed core library' /usr/local/lib/vps-forward/vps-forward-core.sh ||
            vpf_die "拒绝覆盖不属于本项目的核心库"
    fi
    if [[ -e /usr/local/lib/vps-forward &&
        (! -d /usr/local/lib/vps-forward || -L /usr/local/lib/vps-forward) ]]; then
        vpf_die "拒绝使用不安全的核心库目录: /usr/local/lib/vps-forward"
    fi
    if [[ -e "$shortcut" || -L "$shortcut" ]]; then
        [[ -L "$shortcut" && "$(readlink "$shortcut")" == /usr/local/sbin/vps-forward ]] ||
            vpf_die "拒绝覆盖已存在的快捷命令: $shortcut"
    fi
    install -d -m 755 /usr/local/lib/vps-forward
    install -d -m 755 /usr/local/bin
    if [[ "$source_is_installed" == "0" ]]; then
        install -m 755 "$main_source" /usr/local/sbin/vps-forward
        install -m 644 "$core_source" /usr/local/lib/vps-forward/vps-forward-core.sh
    fi
    if [[ ! -L "$shortcut" ]]; then
        ln -s /usr/local/sbin/vps-forward "$shortcut"
    fi
}

enable_ipv4_forward() {
    local tmp
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        printf 'sysctl=net.ipv4.ip_forward=1\n' >>"$VPF_MOCK_DIR/actions"
        return
    fi
    [[ ! -L /etc/sysctl.d/99-vps-forward.conf ]] || vpf_die "sysctl 项目路径是符号链接"
    if [[ -e /etc/sysctl.d/99-vps-forward.conf ]] &&
        ! grep -Fq '# managed by vps-forward' /etc/sysctl.d/99-vps-forward.conf; then
        vpf_die "拒绝覆盖不属于本项目的 sysctl 文件"
    fi
    tmp="$(mktemp /etc/sysctl.d/.99-vps-forward.XXXXXX)"
    vpf_register_tmp "$tmp"
    {
        printf '# managed by vps-forward\n'
        printf 'net.ipv4.ip_forward=1\n'
    } >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" /etc/sysctl.d/99-vps-forward.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    [[ "$(< /proc/sys/net/ipv4/ip_forward)" == "1" ]] || vpf_die "IPv4 转发未能生效"
}

install_service() {
    local platform="$1" tmp
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        case "$platform" in
            ubuntu|debian) printf 'service=systemd\n' >>"$VPF_MOCK_DIR/actions" ;;
            alpine) printf 'service=openrc\n' >>"$VPF_MOCK_DIR/actions" ;;
        esac
        return
    fi
    if command -v systemctl >/dev/null 2>&1 && [[ "$platform" != "alpine" ]]; then
        tmp="$(vpf_make_tmp)"
        cat >"$tmp" <<'EOF'
# managed by vps-forward
[Unit]
Description=vps-forward nftables rules
Documentation=https://github.com/u1ra/script/tree/main/vps-forward
Wants=network-online.target
After=network-online.target nftables.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-forward apply --boot --yes
ExecReload=/usr/local/sbin/vps-forward apply --boot --yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$tmp"
        write_owned_file "$tmp" /etc/systemd/system/vps-forward.service '# managed by vps-forward'
        systemctl daemon-reload
        systemctl enable vps-forward.service
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        tmp="$(vpf_make_tmp)"
        cat >"$tmp" <<'EOF'
#!/sbin/openrc-run
# managed by vps-forward
description="vps-forward nftables rules"
command="/usr/local/sbin/vps-forward"
command_args="apply --boot --yes"
command_background="no"

depend() {
    need net
    after nftables
    before docker
}
EOF
        chmod 755 "$tmp"
        write_owned_file "$tmp" /etc/init.d/vps-forward '# managed by vps-forward'
        chmod 755 /etc/init.d/vps-forward
        rc-update add vps-forward default
    else
        vpf_die "未找到受支持的服务管理器（systemd/OpenRC）"
    fi
}

restart_installed_service() {
    local platform="$1"
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        exec 8>"$VPF_LOCK_FILE"
        if flock -n 8; then
            printf 'service-restart-lock=free\n' >>"$VPF_MOCK_DIR/actions"
            flock -u 8
            exec 8>&-
            return 0
        fi
        printf 'service-restart-lock=held\n' >>"$VPF_MOCK_DIR/actions"
        exec 8>&-
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && [[ "$platform" != "alpine" ]]; then
        systemctl restart vps-forward.service
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service vps-forward restart
    fi
}

cmd_install() {
    local platform installed_version="" version_status=0 requested_action="" action="" action_count=0
    while (($#)); do
        case "$1" in
            --yes|--quiet) set_common_flag "$1"; shift ;;
            --upgrade) requested_action=upgrade; ((action_count += 1)); shift ;;
            --reinstall) requested_action=reinstall; ((action_count += 1)); shift ;;
            --uninstall-existing) requested_action=uninstall; ((action_count += 1)); shift ;;
            *) vpf_die "install 的未知参数: $1" ;;
        esac
    done
    ((action_count <= 1)) || vpf_die "install 的版本操作参数不能同时使用"
    vpf_require_root install
    platform="$(detect_platform)"
    [[ "$VPF_SYSTEM_MODE" != "mock" ]] || mkdir -p "$VPF_MOCK_DIR"
    if installed_version="$(detect_installed_version)"; then
        action="$(choose_install_action "$installed_version" "$requested_action")" || return
        if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
            printf 'version-action=%s\n' "$action" >>"$VPF_MOCK_DIR/actions"
        fi
        case "$action" in
            cancel)
                vpf_info "已取消安装。"
                return 0
                ;;
            uninstall)
                cmd_uninstall --yes --keep-config
                vpf_release_lock
                vpf_info "已卸载 vps-forward $installed_version，配置和备份已保留。"
                return 0
                ;;
            reinstall)
                vpf_info "将重装 vps-forward：$installed_version -> $VPF_VERSION"
                cmd_uninstall --yes --keep-config
                vpf_release_lock
                ;;
            upgrade)
                vpf_info "将升级/切换 vps-forward：$installed_version -> $VPF_VERSION，并保留配置。"
                ;;
            repair)
                vpf_info "检测到相同版本 $VPF_VERSION，将执行幂等检查和修复。"
                ;;
        esac
    else
        version_status=$?
        [[ "$version_status" == "2" ]] || return "$version_status"
    fi
    install_packages "$platform"
    vpf_acquire_lock
    vpf_ensure_config
    install_program_files
    enable_ipv4_forward
    install_service "$platform"
    vpf_apply_current
    vpf_release_lock
    restart_installed_service "$platform"
    vpf_info "安装完成。输入 vpf 或 vps-forward 可打开管理页面。"
    vpf_info "建议运行 vps-forward doctor，并保留当前 SSH 会话和 VPS 控制台。"
}

remove_service_and_program() {
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        printf 'uninstall-program=1\n' >>"$VPF_MOCK_DIR/actions"
        rm -f -- "$VPF_MOCK_DIR/usr/local/bin/vpf" "$VPF_MOCK_DIR/installed-version" \
            "$VPF_MOCK_DIR/usr/local/sbin/vps-forward" \
            "$VPF_MOCK_DIR/usr/local/lib/vps-forward/vps-forward-core.sh"
        return
    fi
    if [[ -f /etc/systemd/system/vps-forward.service ]] &&
        grep -Fq '# managed by vps-forward' /etc/systemd/system/vps-forward.service; then
        systemctl disable --now vps-forward.service 2>/dev/null || true
        rm -f -- /etc/systemd/system/vps-forward.service
        systemctl daemon-reload
    fi
    if [[ -f /etc/init.d/vps-forward ]] && grep -Fq '# managed by vps-forward' /etc/init.d/vps-forward; then
        rc-service vps-forward stop 2>/dev/null || true
        rc-update del vps-forward default 2>/dev/null || true
        rm -f -- /etc/init.d/vps-forward
    fi
    if [[ -L /usr/local/bin/vpf && "$(readlink /usr/local/bin/vpf)" == /usr/local/sbin/vps-forward ]]; then
        rm -f -- /usr/local/bin/vpf
    fi
    if [[ -f /usr/local/sbin/vps-forward && ! -L /usr/local/sbin/vps-forward ]] &&
        grep -Fq '# vps-forward managed program' /usr/local/sbin/vps-forward; then
        rm -f -- /usr/local/sbin/vps-forward
    fi
    if [[ -d /usr/local/lib/vps-forward && ! -L /usr/local/lib/vps-forward ]]; then
        if [[ -f /usr/local/lib/vps-forward/vps-forward-core.sh &&
            ! -L /usr/local/lib/vps-forward/vps-forward-core.sh ]] &&
            grep -Fq '# vps-forward managed core library' /usr/local/lib/vps-forward/vps-forward-core.sh; then
            rm -f -- /usr/local/lib/vps-forward/vps-forward-core.sh
        fi
        rmdir /usr/local/lib/vps-forward 2>/dev/null || true
    fi
}

remove_nft_package() {
    local platform="$1"
    case "$platform" in
        ubuntu|debian) DEBIAN_FRONTEND=noninteractive apt-get remove -y nftables ;;
        alpine) apk del nftables ;;
    esac
}

cmd_uninstall() {
    local rules_only=0 purge=0 remove_sysctl=0 remove_package=0 platform=""
    while (($#)); do
        case "$1" in
            --rules-only) rules_only=1; shift ;;
            --keep-config) purge=0; shift ;;
            --purge) purge=1; shift ;;
            --remove-sysctl) remove_sysctl=1; shift ;;
            --remove-package) remove_package=1; shift ;;
            --yes|--dry-run|--quiet) set_common_flag "$1"; shift ;;
            *) vpf_die "uninstall 的未知参数: $1" ;;
        esac
    done
    [[ "$VPF_ASSUME_YES" == "1" || "$VPF_DRY_RUN" == "1" ]] || vpf_die "卸载需要 --yes"
    [[ "$VPF_DRY_RUN" == "1" ]] || vpf_require_root uninstall
    if [[ "$VPF_DRY_RUN" == "1" ]]; then
        printf 'DRY-RUN: 删除项目 nftables 表\n'
        [[ "$rules_only" == "1" ]] || printf 'DRY-RUN: 删除项目服务和程序，配置%s保留\n' "$([[ "$purge" == 1 ]] && printf 不 || printf 将)"
        [[ "$remove_sysctl" == "1" ]] && printf 'DRY-RUN: 删除项目 sysctl 文件，但不写 net.ipv4.ip_forward=0\n'
        [[ "$remove_package" == "1" ]] && printf 'DRY-RUN: 尝试卸载 nftables 软件包\n'
        return
    fi
    vpf_acquire_lock
    vpf_delete_project_tables
    if [[ "$rules_only" == "0" ]]; then
        remove_service_and_program
        if [[ "$remove_sysctl" == "1" && -f /etc/sysctl.d/99-vps-forward.conf ]] &&
            grep -Fq '# managed by vps-forward' /etc/sysctl.d/99-vps-forward.conf; then
            rm -f -- /etc/sysctl.d/99-vps-forward.conf
            vpf_warn "已删除项目 sysctl 文件，但没有关闭当前 IPv4 转发，以免影响其他服务。"
        fi
        if [[ "$purge" == "1" ]]; then
            [[ "$VPF_CONFIG_DIR" == /etc/vps-forward && ! -L "$VPF_CONFIG_DIR" ]] &&
                rm -rf -- /etc/vps-forward
        fi
        if [[ "$remove_package" == "1" ]]; then
            platform="$(detect_platform)"
            remove_nft_package "$platform"
        fi
    fi
    vpf_info "卸载操作完成。"
}

prompt_value() {
    local prompt="$1" default="$2" value
    while true; do
        read -r -p "$prompt [$default]（输入 q 取消）: " value || return 1
        [[ "$value" == "q" || "$value" == "Q" ]] && return 1
        printf '%s\n' "${value:-$default}"
        return 0
    done
}

menu_add() {
    local name listen_ip listen_port target_ip target_port protocol masq_choice masq_args=()
    name="$(prompt_value '规则名称' 'forward')" || return
    listen_ip="$(prompt_value '监听 IP' 'any')" || return
    listen_port="$(prompt_value '入口端口' '8443')" || return
    target_ip="$(prompt_value '目标 IPv4' '192.0.2.10')" || return
    target_port="$(prompt_value '目标端口' "$listen_port")" || return
    protocol="$(prompt_value '协议 tcp/udp/both' 'both')" || return
    printf 'Masquerade 匹配范围:\n1. 精确 IP+端口+协议（推荐）\n2. 仅目标 IP\n3. 不启用\n'
    masq_choice="$(prompt_value '请选择' '1')" || return
    case "$masq_choice" in
        1) masq_args=(--masquerade-mode precise) ;;
        2) masq_args=(--masquerade-mode destination) ;;
        3) masq_args=(--no-masquerade) ;;
        *) vpf_warn "选择无效"; return ;;
    esac
    cmd_add --name "$name" --listen-ip "$listen_ip" --listen-port "$listen_port" \
        --target-ip "$target_ip" --target-port "$target_port" --protocol "$protocol" "${masq_args[@]}"
}

menu_id_action() {
    local action="$1" id answer
    id="$(prompt_value '规则 ID' '1')" || return
    case "$action" in
        show) cmd_show "$id" ;;
        edit)
            cmd_show "$id" || return
            vpf_info "交互修改采用逐字段命令更安全；空值保留原值。"
            local target_port
            target_port="$(prompt_value '新的目标端口' '')" || return
            [[ -n "$target_port" ]] && cmd_edit "$id" --target-port "$target_port"
            ;;
        delete)
            cmd_show "$id" || return
            read -r -p '确认删除？输入 YES: ' answer || return
            if [[ "$answer" == "YES" ]]; then
                cmd_delete "$id" --yes
            else
                vpf_info "已取消。"
            fi
            ;;
        enable) cmd_set_enabled "$id" 1 ;;
        disable) cmd_set_enabled "$id" 0 ;;
    esac
}

VPF_UI_RESET=""
VPF_UI_BOLD=""
VPF_UI_DIM=""
VPF_UI_CYAN=""
VPF_UI_BLUE=""
VPF_UI_GREEN=""
VPF_UI_YELLOW=""
VPF_UI_RED=""

vpf_ui_init() {
    local color_mode="${VPF_COLOR:-auto}" enable_color=0
    case "$color_mode" in
        always) enable_color=1 ;;
        never) enable_color=0 ;;
        auto)
            if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
                enable_color=1
            fi
            ;;
        *) enable_color=0 ;;
    esac
    if [[ "$enable_color" == "1" ]]; then
        VPF_UI_RESET=$'\033[0m'
        VPF_UI_BOLD=$'\033[1m'
        VPF_UI_DIM=$'\033[2m'
        VPF_UI_CYAN=$'\033[36m'
        VPF_UI_BLUE=$'\033[34m'
        VPF_UI_GREEN=$'\033[32m'
        VPF_UI_YELLOW=$'\033[33m'
        VPF_UI_RED=$'\033[31m'
    else
        VPF_UI_RESET=""
        VPF_UI_BOLD=""
        VPF_UI_DIM=""
        VPF_UI_CYAN=""
        VPF_UI_BLUE=""
        VPF_UI_GREEN=""
        VPF_UI_YELLOW=""
        VPF_UI_RED=""
    fi
}

menu_service_summary() {
    if [[ -n "${VPF_MENU_SERVICE_STATE:-}" ]]; then
        printf '%s\n' "$VPF_MENU_SERVICE_STATE"
    elif [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        if [[ -f "$VPF_MOCK_DIR/installed-version" ]]; then
            printf '运行中\n'
        else
            printf '未安装\n'
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet vps-forward.service 2>/dev/null; then
            printf '运行中\n'
        elif systemctl is-enabled --quiet vps-forward.service 2>/dev/null; then
            printf '已启用/未运行\n'
        else
            printf '未安装\n'
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service vps-forward status >/dev/null 2>&1; then
            printf '运行中\n'
        elif [[ -e /etc/init.d/vps-forward ]]; then
            printf '未运行\n'
        else
            printf '未安装\n'
        fi
    else
        printf '未知\n'
    fi
}

menu_status_value() {
    local value="$1" good_pattern="$2"
    if [[ "$value" =~ $good_pattern ]]; then
        printf '%s● %s%s' "$VPF_UI_GREEN" "$value" "$VPF_UI_RESET"
    elif [[ "$value" == "配置异常" || "$value" == "未开启" ||
        "$value" == "未运行" || "$value" == "已启用/未运行" ]]; then
        printf '%s● %s%s' "$VPF_UI_RED" "$value" "$VPF_UI_RESET"
    elif [[ "$value" == "未知" ]]; then
        printf '%s● %s%s' "$VPF_UI_DIM" "$value" "$VPF_UI_RESET"
    else
        printf '%s● %s%s' "$VPF_UI_YELLOW" "$value" "$VPF_UI_RESET"
    fi
}

render_main_menu() {
    local os_line os_id os_version service ip_forward ip_forward_label
    local config_state total=0 enabled=0 disabled=0

    vpf_ui_init
    os_line="$(detect_os)"
    IFS=$'\t' read -r os_id os_version <<<"$os_line"
    service="$(menu_service_summary)"
    if [[ -n "${VPF_MENU_IP_FORWARD:-}" ]]; then
        ip_forward="$VPF_MENU_IP_FORWARD"
    elif [[ -r /proc/sys/net/ipv4/ip_forward ]]; then
        ip_forward="$(</proc/sys/net/ipv4/ip_forward)"
    else
        ip_forward="未知"
    fi
    case "$ip_forward" in
        1) ip_forward_label="已开启" ;;
        0) ip_forward_label="未开启" ;;
        *) ip_forward_label="未知" ;;
    esac

    if [[ ! -e "$VPF_CONFIG_FILE" ]]; then
        config_state="未初始化"
    elif [[ -f "$VPF_CONFIG_FILE" && ! -L "$VPF_CONFIG_FILE" ]] &&
        vpf_validate_config "$VPF_CONFIG_FILE" >/dev/null 2>&1; then
        config_state="正常"
        total="$(count_rules all)"
        enabled="$(count_rules enabled)"
        disabled="$(count_rules disabled)"
    else
        config_state="配置异常"
    fi

    printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s%sVPS FORWARD%s  %snftables IPv4 四层端口转发管理%s\n' \
        "$VPF_UI_BOLD" "$VPF_UI_CYAN" "$VPF_UI_RESET" "$VPF_UI_DIM" "$VPF_UI_RESET"
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s版本%s v%s  %s系统%s %s %s\n' \
        "$VPF_UI_DIM" "$VPF_UI_RESET" "$VPF_VERSION" \
        "$VPF_UI_DIM" "$VPF_UI_RESET" "$os_id" "${os_version:-}"
    printf '  %s服务%s ' "$VPF_UI_DIM" "$VPF_UI_RESET"
    menu_status_value "$service" '^运行中$'
    printf '   %sIPv4 转发%s ' "$VPF_UI_DIM" "$VPF_UI_RESET"
    menu_status_value "$ip_forward_label" '^已开启$'
    printf '   %s配置%s ' "$VPF_UI_DIM" "$VPF_UI_RESET"
    menu_status_value "$config_state" '^正常$'
    printf '\n'
    printf '  %s规则%s 总计 %s / %s启用 %s%s / %s禁用 %s%s\n' \
        "$VPF_UI_DIM" "$VPF_UI_RESET" "$total" \
        "$VPF_UI_GREEN" "$enabled" "$VPF_UI_RESET" \
        "$VPF_UI_YELLOW" "$disabled" "$VPF_UI_RESET"

    printf '\n  %s%s规则管理%s\n' "$VPF_UI_BOLD" "$VPF_UI_BLUE" "$VPF_UI_RESET"
    printf '  %s[1]%s  初始化 / 修复环境\n' "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s[2]%s  新增转发规则          %s[3]%s  查看转发规则\n' \
        "$VPF_UI_CYAN" "$VPF_UI_RESET" "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s[4]%s  修改转发规则          %s[5]%s  删除转发规则\n' \
        "$VPF_UI_CYAN" "$VPF_UI_RESET" "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s[6]%s  启用规则              %s[7]%s  禁用规则\n' \
        "$VPF_UI_CYAN" "$VPF_UI_RESET" "$VPF_UI_CYAN" "$VPF_UI_RESET"

    printf '\n  %s%s系统与诊断%s\n' "$VPF_UI_BOLD" "$VPF_UI_BLUE" "$VPF_UI_RESET"
    printf '  %s[8]%s  查看 nftables 实际规则\n' "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s[9]%s  检查配置              %s[14]%s 修复 / 重新应用规则\n' \
        "$VPF_UI_CYAN" "$VPF_UI_RESET" "$VPF_UI_CYAN" "$VPF_UI_RESET"

    printf '\n  %s%s数据与维护%s\n' "$VPF_UI_BOLD" "$VPF_UI_BLUE" "$VPF_UI_RESET"
    printf '  %s[10]%s 备份配置              %s[11]%s 恢复配置\n' \
        "$VPF_UI_CYAN" "$VPF_UI_RESET" "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s[12]%s 导入配置              %s[13]%s 导出配置\n' \
        "$VPF_UI_CYAN" "$VPF_UI_RESET" "$VPF_UI_CYAN" "$VPF_UI_RESET"
    printf '  %s[15]%s 卸载\n' "$VPF_UI_RED" "$VPF_UI_RESET"

    printf '\n  %s[0]%s 退出    %sq%s 退出当前菜单\n' \
        "$VPF_UI_DIM" "$VPF_UI_RESET" "$VPF_UI_DIM" "$VPF_UI_RESET"
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$VPF_UI_CYAN" "$VPF_UI_RESET"
}

menu_clear() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" && "${VPF_MENU_NO_CLEAR:-0}" != "1" ]]; then
        printf '\033[2J\033[H'
    fi
}

menu_pause() {
    [[ -t 0 && -t 1 ]] || return 0
    printf '\n%s按 Enter 返回主菜单…%s' "$VPF_UI_DIM" "$VPF_UI_RESET"
    read -r || true
}

menu_run_action() {
    local status=0
    trap - ERR
    set +e
    (
        set -Eeuo pipefail
        trap 'exit $?' ERR
        "$@"
    )
    status=$?
    set -e
    trap 'vpf_error_trap "$LINENO"' ERR
    VPF_MENU_LAST_STATUS="$status"
    if [[ "$status" != "0" ]]; then
        vpf_warn "操作未完成（退出码 $status），请检查上方提示。"
    fi
    menu_pause
    return 0
}

interactive_menu() {
    local choice backup_name file answer
    VPF_MENU_LAST_STATUS=0
    while true; do
        menu_clear
        render_main_menu
        printf '  %s请选择 [0-15]:%s ' "$VPF_UI_BOLD" "$VPF_UI_RESET"
        read -r choice || return 0
        case "$choice" in
            1) menu_run_action cmd_install ;;
            2) menu_run_action menu_add ;;
            3) menu_run_action cmd_list ;;
            4) menu_run_action menu_id_action edit ;;
            5) menu_run_action menu_id_action delete ;;
            6) menu_run_action menu_id_action enable ;;
            7) menu_run_action menu_id_action disable ;;
            8) menu_run_action cmd_rules ;;
            9) menu_run_action cmd_check ;;
            10) menu_run_action cmd_backup ;;
            11)
                backup_name="$(prompt_value '备份目录名' 'backup-YYYYMMDDTHHMMSSZ-PID-RANDOM')" || continue
                read -r -p '确认恢复？输入 YES: ' answer || continue
                if [[ "$answer" == "YES" ]]; then
                    menu_run_action cmd_restore "$backup_name" --yes
                else
                    vpf_info "已取消。"
                    menu_pause
                fi
                ;;
            12)
                file="$(prompt_value '导入文件绝对路径' '/root/config.tsv')" || continue
                read -r -p '确认导入？输入 YES: ' answer || continue
                if [[ "$answer" == "YES" ]]; then
                    menu_run_action cmd_import --input "$file" --yes
                else
                    vpf_info "已取消。"
                    menu_pause
                fi
                ;;
            13)
                file="$(prompt_value '导出文件绝对路径' '/root/vps-forward-config.tsv')" || continue
                menu_run_action cmd_export --output "$file"
                ;;
            14) menu_run_action cmd_apply ;;
            15)
                read -r -p '确认保守卸载（保留配置和 sysctl）？输入 YES: ' answer || continue
                if [[ "$answer" == "YES" ]]; then
                    menu_run_action cmd_uninstall --yes --keep-config
                    if [[ "$VPF_MENU_LAST_STATUS" == "0" ]]; then
                        vpf_info "程序已卸载，管理菜单退出。"
                        return 0
                    fi
                else
                    vpf_info "已取消。"
                    menu_pause
                fi
                ;;
            0|q|Q) return 0 ;;
            *) vpf_warn "无效选择，请输入 0～15。"; menu_pause ;;
        esac
    done
}

main() {
    local command="${1:-menu}"
    [[ $# -eq 0 ]] || shift
    case "$command" in
        menu) interactive_menu ;;
        install) cmd_install "$@" ;;
        add) cmd_add "$@" ;;
        list) cmd_list "$@" ;;
        show) cmd_show "$@" ;;
        edit) cmd_edit "$@" ;;
        delete|remove) cmd_delete "$@" ;;
        enable) cmd_set_enabled "${1:-}" 1 "${@:2}" ;;
        disable) cmd_set_enabled "${1:-}" 0 "${@:2}" ;;
        apply|repair) cmd_apply "$@" ;;
        check) cmd_check "$@" ;;
        status) cmd_status "$@" ;;
        doctor) cmd_doctor "$@" ;;
        rules) cmd_rules "$@" ;;
        backup) cmd_backup "$@" ;;
        restore) cmd_restore "$@" ;;
        export) cmd_export "$@" ;;
        import) cmd_import "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        help|-h|--help) usage ;;
        version|-V|--version) printf 'vps-forward %s\n' "$VPF_VERSION" ;;
        *) vpf_error "未知命令: $command"; usage >&2; return 2 ;;
    esac
}

if [[ "${VPF_LIB_MODE:-0}" != "1" ]]; then
    main "$@"
fi
