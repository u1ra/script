#!/usr/bin/env bash
# vps-forward managed core library

# vps-forward 核心库。主程序负责启用严格模式，本文件也可由测试直接加载。

VPF_VERSION="${VPF_VERSION:-0.1.3}"
VPF_SCHEMA="vps-forward-config-v1"
VPF_MARK="vps-forward managed table v1"

VPF_CONFIG_DIR="${VPF_CONFIG_DIR:-/etc/vps-forward}"
VPF_CONFIG_FILE="${VPF_CONFIG_FILE:-${VPF_CONFIG_DIR}/config.tsv}"
VPF_GENERATED_FILE="${VPF_GENERATED_FILE:-${VPF_CONFIG_DIR}/generated.nft}"
VPF_BACKUP_DIR="${VPF_BACKUP_DIR:-${VPF_CONFIG_DIR}/backups}"
VPF_LOCK_FILE="${VPF_LOCK_FILE:-${VPF_CONFIG_DIR}/lock}"
VPF_STATE_FILE="${VPF_STATE_FILE:-${VPF_CONFIG_DIR}/state}"
VPF_LOG_FILE="${VPF_LOG_FILE:-/var/log/vps-forward.log}"
VPF_MOCK_DIR="${VPF_MOCK_DIR:-${VPF_CONFIG_DIR}/mock}"
VPF_NFT_BIN="${VPF_NFT_BIN:-nft}"
VPF_SYSTEM_MODE="${VPF_SYSTEM_MODE:-real}"
VPF_DRY_RUN="${VPF_DRY_RUN:-0}"
VPF_QUIET="${VPF_QUIET:-0}"
VPF_ASSUME_YES="${VPF_ASSUME_YES:-0}"
VPF_KEEP_BACKUPS="${VPF_KEEP_BACKUPS:-20}"
VPF_TEMP_PARENT="${VPF_TEMP_PARENT:-}"

VPF_TMP_FILES=()
VPF_TMP_REGISTRY="$(mktemp "${TMPDIR:-/tmp}/vps-forward-tmp.XXXXXX")"
chmod 600 "$VPF_TMP_REGISTRY"

vpf_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

vpf_info() {
    [[ "$VPF_QUIET" == "1" ]] || printf '信息: %s\n' "$*"
}

vpf_warn() {
    printf '警告: %s\n' "$*" >&2
}

vpf_error() {
    printf '错误: %s\n' "$*" >&2
}

vpf_die() {
    vpf_error "$*"
    return 1
}

vpf_log() {
    local message="$*"
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        mkdir -p -- "$(dirname -- "$VPF_LOG_FILE")"
    fi
    if [[ -d "$(dirname -- "$VPF_LOG_FILE")" && ! -L "$VPF_LOG_FILE" ]]; then
        printf '%s %s\n' "$(vpf_now)" "$message" >>"$VPF_LOG_FILE" 2>/dev/null || true
    fi
}

vpf_register_tmp() {
    VPF_TMP_FILES+=("$1")
    printf '%s\n' "$1" >>"$VPF_TMP_REGISTRY"
}

vpf_cleanup() {
    local path
    if [[ -f "$VPF_TMP_REGISTRY" && ! -L "$VPF_TMP_REGISTRY" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" && "$path" == */.vps-forward.* && -f "$path" && ! -L "$path" ]] &&
                rm -f -- "$path"
        done <"$VPF_TMP_REGISTRY"
        rm -f -- "$VPF_TMP_REGISTRY"
    fi
    VPF_TMP_FILES=()
}

vpf_require_root() {
    if [[ "${VPF_ALLOW_NON_ROOT:-0}" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
        vpf_die "此操作需要 root 权限，请使用 sudo vps-forward $*"
    fi
}

vpf_assert_safe_path() {
    local path="$1"
    [[ -n "$path" && "$path" == /* ]] || vpf_die "内部路径必须为绝对路径: $path"
    [[ ! -L "$path" ]] || vpf_die "拒绝操作符号链接: $path"
}

vpf_prepare_dirs() {
    local dir
    for dir in "$VPF_CONFIG_DIR" "$VPF_BACKUP_DIR"; do
        vpf_assert_safe_path "$dir" || return
        if [[ -e "$dir" && ! -d "$dir" ]]; then
            vpf_die "路径存在但不是目录: $dir"
            return
        fi
        mkdir -p -- "$dir"
        chmod 700 "$dir"
    done
}

vpf_acquire_lock() {
    vpf_prepare_dirs || return
    vpf_assert_safe_path "$VPF_LOCK_FILE" || return
    command -v flock >/dev/null 2>&1 || {
        vpf_die "缺少 flock；请安装 util-linux"
        return
    }
    exec 9>"$VPF_LOCK_FILE"
    chmod 600 "$VPF_LOCK_FILE"
    if ! flock -n 9; then
        vpf_die "另一个 vps-forward 实例正在修改配置"
        return
    fi
}

vpf_release_lock() {
    # 安装流程启动 systemd/OpenRC 子进程前必须释放锁，否则子进程会与父进程自锁。
    flock -u 9 2>/dev/null || true
    exec 9>&-
}

vpf_make_tmp() {
    local parent="${1:-${VPF_TEMP_PARENT:-$VPF_CONFIG_DIR}}"
    local tmp
    tmp="$(mktemp "${parent}/.vps-forward.XXXXXX")"
    chmod 600 "$tmp"
    vpf_register_tmp "$tmp"
    printf '%s\n' "$tmp"
}

vpf_atomic_copy() {
    local source="$1" destination="$2" tmp
    vpf_assert_safe_path "$destination" || return
    [[ -f "$source" && ! -L "$source" ]] || {
        vpf_die "原子写入源文件无效: $source"
        return
    }
    tmp="$(vpf_make_tmp "$(dirname -- "$destination")")" || return
    cp -- "$source" "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$destination"
}

vpf_write_empty_config() {
    local output="$1"
    {
        printf '# %s\n' "$VPF_SCHEMA"
        printf '# id\tenabled\tprotocol\tlisten_ip\tlisten_port\ttarget_ip\ttarget_port\tmasquerade_mode\tname\tcreated_at\tupdated_at\n'
    } >"$output"
    chmod 600 "$output"
}

vpf_ensure_config() {
    local tmp
    vpf_prepare_dirs || return
    vpf_assert_safe_path "$VPF_CONFIG_FILE" || return
    if [[ ! -e "$VPF_CONFIG_FILE" ]]; then
        tmp="$(vpf_make_tmp)" || return
        vpf_write_empty_config "$tmp"
        mv -f -- "$tmp" "$VPF_CONFIG_FILE"
    fi
    [[ -f "$VPF_CONFIG_FILE" && ! -L "$VPF_CONFIG_FILE" ]] ||
        vpf_die "配置文件不是安全的普通文件: $VPF_CONFIG_FILE"
    chmod 600 "$VPF_CONFIG_FILE"
}

vpf_valid_ipv4() {
    local ip="$1" octet
    local IFS=.
    local -a parts
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    read -r -a parts <<<"$ip"
    [[ "${#parts[@]}" -eq 4 ]] || return 1
    for octet in "${parts[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
        [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
    done
}

vpf_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

vpf_valid_protocol() {
    [[ "$1" == "tcp" || "$1" == "udp" || "$1" == "both" ]]
}

vpf_valid_listen_ip() {
    [[ "$1" == "*" ]] || vpf_valid_ipv4 "$1"
}

vpf_valid_masq_mode() {
    [[ "$1" == "precise" || "$1" == "destination" || "$1" == "none" ]]
}

vpf_valid_name() {
    local name="$1"
    ((${#name} >= 1 && ${#name} <= 64)) || return 1
    [[ "$name" =~ ^[[:alnum:]_.[:space:]-]+$ ]] || return 1
    [[ "$name" != *$'\t'* && "$name" != *$'\n'* && "$name" != *$'\r'* ]]
}

vpf_valid_timestamp() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

vpf_protocols_overlap() {
    local left="$1" right="$2"
    [[ "$left" == "both" || "$right" == "both" || "$left" == "$right" ]]
}

vpf_listen_ips_overlap() {
    local left="$1" right="$2"
    [[ "$left" == "*" || "$right" == "*" || "$left" == "$right" ]]
}

vpf_validate_config() {
    local file="${1:-$VPF_CONFIG_FILE}"
    local line id enabled protocol listen_ip listen_port target_ip target_port masq name created updated extra
    local line_no=0 index
    local -A seen_ids=()
    local -a rule_ids=() rule_protocols=() rule_ips=() rule_ports=()

    [[ -f "$file" && ! -L "$file" ]] || {
        vpf_die "配置必须是普通文件且不能是符号链接: $file"
        return
    }
    IFS= read -r line <"$file" || {
        vpf_die "配置文件为空"
        return
    }
    [[ "$line" == "# $VPF_SCHEMA" ]] || {
        vpf_die "不支持或损坏的配置版本"
        return
    }

    while IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated extra; do
        ((line_no += 1))
        [[ -z "$id" || "$id" == \#* ]] && continue
        [[ -z "$extra" ]] || {
            vpf_die "配置第 $line_no 行字段数量错误"
            return
        }
        [[ "$id" =~ ^[1-9][0-9]*$ ]] || {
            vpf_die "配置第 $line_no 行 ID 无效"
            return
        }
        [[ -z "${seen_ids[$id]+x}" ]] || {
            vpf_die "配置存在重复 ID: $id"
            return
        }
        seen_ids["$id"]=1
        [[ "$enabled" == "0" || "$enabled" == "1" ]] || {
            vpf_die "规则 $id 的 enabled 无效"
            return
        }
        vpf_valid_protocol "$protocol" || {
            vpf_die "规则 $id 的协议无效"
            return
        }
        vpf_valid_listen_ip "$listen_ip" || {
            vpf_die "规则 $id 的监听 IPv4 无效"
            return
        }
        vpf_valid_port "$listen_port" || {
            vpf_die "规则 $id 的入口端口无效"
            return
        }
        vpf_valid_ipv4 "$target_ip" || {
            vpf_die "规则 $id 的目标 IPv4 无效"
            return
        }
        vpf_valid_port "$target_port" || {
            vpf_die "规则 $id 的目标端口无效"
            return
        }
        vpf_valid_masq_mode "$masq" || {
            vpf_die "规则 $id 的 Masquerade 模式无效"
            return
        }
        vpf_valid_name "$name" || {
            vpf_die "规则 $id 的名称无效"
            return
        }
        if ! vpf_valid_timestamp "$created" || ! vpf_valid_timestamp "$updated"; then
            vpf_die "规则 $id 的时间戳无效"
            return
        fi
        for index in "${!rule_ids[@]}"; do
            if [[ "${rule_ports[$index]}" == "$listen_port" ]] &&
                vpf_protocols_overlap "${rule_protocols[$index]}" "$protocol" &&
                vpf_listen_ips_overlap "${rule_ips[$index]}" "$listen_ip"; then
                vpf_die "配置中的规则 $id 与规则 ${rule_ids[$index]} 入口端口/协议/监听地址冲突"
                return
            fi
        done
        rule_ids+=("$id")
        rule_protocols+=("$protocol")
        rule_ips+=("$listen_ip")
        rule_ports+=("$listen_port")
    done <"$file"
}

vpf_next_id() {
    local file="${1:-$VPF_CONFIG_FILE}"
    local max=0 id
    while IFS=$'\t' read -r id _; do
        [[ "$id" =~ ^[1-9][0-9]*$ ]] || continue
        ((id > max)) && max="$id"
    done <"$file"
    printf '%s\n' "$((max + 1))"
}

vpf_rule_exists() {
    local wanted="$1" file="${2:-$VPF_CONFIG_FILE}" id
    while IFS=$'\t' read -r id _; do
        [[ "$id" == "$wanted" ]] && return 0
    done <"$file"
    return 1
}

vpf_get_rule() {
    local wanted="$1" file="${2:-$VPF_CONFIG_FILE}" line id
    while IFS= read -r line; do
        [[ "$line" == \#* || -z "$line" ]] && continue
        IFS=$'\t' read -r id _ <<<"$line"
        if [[ "$id" == "$wanted" ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done <"$file"
    return 1
}

vpf_check_rule_conflict() {
    local file="$1" ignore_id="$2" candidate_protocol="$3" candidate_ip="$4" candidate_port="$5"
    local id enabled protocol listen_ip listen_port rest
    while IFS=$'\t' read -r id enabled protocol listen_ip listen_port rest; do
        [[ "$id" =~ ^[1-9][0-9]*$ ]] || continue
        [[ "$id" == "$ignore_id" ]] && continue
        if [[ "$listen_port" == "$candidate_port" ]] &&
            vpf_protocols_overlap "$protocol" "$candidate_protocol" &&
            vpf_listen_ips_overlap "$listen_ip" "$candidate_ip"; then
            printf '%s\n' "$id"
            return 0
        fi
    done <"$file"
    return 1
}

vpf_check_exact_duplicate() {
    local file="$1" ignore_id="$2" candidate_protocol="$3" candidate_ip="$4"
    local candidate_port="$5" target_ip="$6" target_port="$7"
    local id enabled protocol listen_ip listen_port existing_target_ip existing_target_port rest
    while IFS=$'\t' read -r id enabled protocol listen_ip listen_port existing_target_ip existing_target_port rest; do
        [[ "$id" =~ ^[1-9][0-9]*$ ]] || continue
        [[ "$id" == "$ignore_id" ]] && continue
        if [[ "$protocol" == "$candidate_protocol" && "$listen_ip" == "$candidate_ip" &&
            "$listen_port" == "$candidate_port" && "$existing_target_ip" == "$target_ip" &&
            "$existing_target_port" == "$target_port" ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    done <"$file"
    return 1
}

vpf_expand_protocols() {
    if [[ "$1" == "both" ]]; then
        printf 'tcp\nudp\n'
    else
        printf '%s\n' "$1"
    fi
}

vpf_nft_comment_name() {
    # 名称已通过白名单验证；将连续空格压缩，保持 comment 简洁可审计。
    local name="$1"
    printf '%s' "$name" | tr -s ' '
}

vpf_generate_ruleset() {
    local config="$1" output="$2"
    local id enabled protocol listen_ip listen_port target_ip target_port masq name created updated
    local proto comment key
    local -A masq_seen=()

    vpf_validate_config "$config" || return
    {
        printf 'table ip vps_forward_nat {\n'
        printf '    comment "%s"\n' "$VPF_MARK"
        printf '    chain prerouting {\n'
        printf '        type nat hook prerouting priority dstnat; policy accept;\n'
        while IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated; do
            [[ "$id" =~ ^[1-9][0-9]*$ && "$enabled" == "1" ]] || continue
            comment="$(vpf_nft_comment_name "$name")"
            while IFS= read -r proto; do
                printf '        '
                [[ "$listen_ip" == "*" ]] || printf 'ip daddr %s ' "$listen_ip"
                printf '%s dport %s dnat to %s:%s comment "vps-forward id=%s name=%s"\n' \
                    "$proto" "$listen_port" "$target_ip" "$target_port" "$id" "$comment"
            done < <(vpf_expand_protocols "$protocol")
        done <"$config"
        printf '    }\n'
        printf '    chain postrouting {\n'
        printf '        type nat hook postrouting priority srcnat; policy accept;\n'
        while IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated; do
            [[ "$id" =~ ^[1-9][0-9]*$ && "$enabled" == "1" && "$masq" != "none" ]] || continue
            comment="$(vpf_nft_comment_name "$name")"
            if [[ "$masq" == "destination" ]]; then
                key="destination|$target_ip"
                if [[ -z "${masq_seen[$key]+x}" ]]; then
                    masq_seen["$key"]=1
                    printf '        ct status dnat ip daddr %s masquerade comment "vps-forward id=%s name=%s masq=destination"\n' \
                        "$target_ip" "$id" "$comment"
                fi
            else
                while IFS= read -r proto; do
                    key="precise|$target_ip|$target_port|$proto"
                    if [[ -z "${masq_seen[$key]+x}" ]]; then
                        masq_seen["$key"]=1
                        printf '        ct status dnat ip daddr %s %s dport %s masquerade comment "vps-forward id=%s name=%s masq=precise"\n' \
                            "$target_ip" "$proto" "$target_port" "$id" "$comment"
                    fi
                done < <(vpf_expand_protocols "$protocol")
            fi
        done <"$config"
        printf '    }\n'
        printf '}\n\n'
        printf 'table inet vps_forward_filter {\n'
        printf '    comment "%s"\n' "$VPF_MARK"
        printf '    chain forward {\n'
        printf '        type filter hook forward priority -5; policy accept;\n'
        printf '        ct status dnat ct state established,related accept comment "vps-forward established dnat"\n'
        while IFS=$'\t' read -r id enabled protocol listen_ip listen_port target_ip target_port masq name created updated; do
            [[ "$id" =~ ^[1-9][0-9]*$ && "$enabled" == "1" ]] || continue
            comment="$(vpf_nft_comment_name "$name")"
            while IFS= read -r proto; do
                printf '        ct status dnat ip daddr %s %s dport %s accept comment "vps-forward id=%s name=%s"\n' \
                    "$target_ip" "$proto" "$target_port" "$id" "$comment"
            done < <(vpf_expand_protocols "$protocol")
        done <"$config"
        printf '    }\n'
        printf '}\n'
    } >"$output"
    chmod 600 "$output"
}

vpf_table_exists() {
    local family="$1" table="$2"
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        [[ -f "$VPF_MOCK_DIR/active.nft" ]] &&
            grep -Fq "table $family $table {" "$VPF_MOCK_DIR/active.nft"
    else
        "$VPF_NFT_BIN" list table "$family" "$table" >/dev/null 2>&1
    fi
}

vpf_verify_table_owner() {
    local family="$1" table="$2" content
    vpf_table_exists "$family" "$table" || return 0
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        content="$(<"$VPF_MOCK_DIR/active.nft")"
    else
        content="$("$VPF_NFT_BIN" list table "$family" "$table" 2>/dev/null)" || return
    fi
    grep -Fq "$VPF_MARK" <<<"$content" || {
        vpf_die "检测到同名但不属于本项目的 nftables 表: $family $table"
        return
    }
}

vpf_build_transaction() {
    local generated="$1" transaction="$2"
    vpf_verify_table_owner ip vps_forward_nat || return
    vpf_verify_table_owner inet vps_forward_filter || return
    : >"$transaction"
    if vpf_table_exists ip vps_forward_nat; then
        printf 'delete table ip vps_forward_nat\n' >>"$transaction"
    fi
    if vpf_table_exists inet vps_forward_filter; then
        printf 'delete table inet vps_forward_filter\n' >>"$transaction"
    fi
    cat -- "$generated" >>"$transaction"
    chmod 600 "$transaction"
}

vpf_nft_check() {
    local transaction="$1"
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        grep -Fq 'table ip vps_forward_nat {' "$transaction" &&
            grep -Fq 'table inet vps_forward_filter {' "$transaction" &&
            ! grep -Eq 'flush[[:space:]]+ruleset' "$transaction"
    elif [[ "$VPF_DRY_RUN" == "1" ]]; then
        if command -v "$VPF_NFT_BIN" >/dev/null 2>&1 &&
            "$VPF_NFT_BIN" --check --file "$transaction" >/dev/null 2>&1; then
            return 0
        fi
        vpf_warn "dry-run 环境无法执行真实 nft --check（可能未安装或权限不足）；仅执行结构安全检查。"
        grep -Fq 'table ip vps_forward_nat {' "$transaction" &&
            grep -Fq 'table inet vps_forward_filter {' "$transaction" &&
            ! grep -Eq 'flush[[:space:]]+ruleset' "$transaction"
    else
        command -v "$VPF_NFT_BIN" >/dev/null 2>&1 || {
            vpf_die "nftables 未安装，请先运行 vps-forward install"
            return
        }
        "$VPF_NFT_BIN" --check --file "$transaction"
    fi
}

vpf_nft_apply() {
    local transaction="$1" generated="$2"
    if [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        mkdir -p -- "$VPF_MOCK_DIR"
        [[ "${VPF_MOCK_FAIL_APPLY:-0}" != "1" ]] || return 1
        cp -- "$generated" "$VPF_MOCK_DIR/active.nft"
    else
        "$VPF_NFT_BIN" --file "$transaction"
    fi
}

vpf_verify_applied() {
    [[ "${VPF_MOCK_FAIL_VERIFY:-0}" != "1" ]] || return 1
    vpf_table_exists ip vps_forward_nat && vpf_table_exists inet vps_forward_filter
}

vpf_restore_ruleset_file() {
    local previous="$1" tmp_tx
    [[ -f "$previous" ]] || return 0
    tmp_tx="$(vpf_make_tmp)" || return
    vpf_build_transaction "$previous" "$tmp_tx" || return
    vpf_nft_check "$tmp_tx" && vpf_nft_apply "$tmp_tx" "$previous"
}

vpf_backup_prune() {
    local -a backups=()
    local path
    [[ "$VPF_KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || VPF_KEEP_BACKUPS=20
    while IFS= read -r path; do
        backups+=("$path")
    done < <(find "$VPF_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' -print | sort -r)
    if ((${#backups[@]} > VPF_KEEP_BACKUPS)); then
        for path in "${backups[@]:VPF_KEEP_BACKUPS}"; do
            [[ "$path" == "$VPF_BACKUP_DIR"/backup-* && ! -L "$path" ]] && rm -rf -- "$path"
        done
    fi
}

vpf_backup_create() {
    local reason="${1:-manual}" stamp destination
    vpf_prepare_dirs || return
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
    destination="$VPF_BACKUP_DIR/backup-$stamp"
    [[ ! -e "$destination" ]] || {
        vpf_die "备份目录已存在"
        return
    }
    mkdir -m 700 -- "$destination"
    [[ -f "$VPF_CONFIG_FILE" && ! -L "$VPF_CONFIG_FILE" ]] && cp -- "$VPF_CONFIG_FILE" "$destination/config.tsv"
    [[ -f "$VPF_GENERATED_FILE" && ! -L "$VPF_GENERATED_FILE" ]] && cp -- "$VPF_GENERATED_FILE" "$destination/generated.nft"
    if [[ -f /etc/systemd/system/vps-forward.service && ! -L /etc/systemd/system/vps-forward.service ]]; then
        cp -- /etc/systemd/system/vps-forward.service "$destination/" 2>/dev/null || true
    fi
    if [[ -f /etc/init.d/vps-forward && ! -L /etc/init.d/vps-forward ]]; then
        cp -- /etc/init.d/vps-forward "$destination/vps-forward.openrc" 2>/dev/null || true
    fi
    if [[ -f /etc/sysctl.d/99-vps-forward.conf && ! -L /etc/sysctl.d/99-vps-forward.conf ]]; then
        cp -- /etc/sysctl.d/99-vps-forward.conf "$destination/" 2>/dev/null || true
    fi
    {
        printf 'schema=%s\n' "$VPF_SCHEMA"
        printf 'version=%s\n' "$VPF_VERSION"
        printf 'created_at=%s\n' "$(vpf_now)"
        printf 'reason=%s\n' "${reason//[^[:alnum:]_.-]/_}"
    } >"$destination/manifest"
    chmod 600 "$destination"/*
    vpf_backup_prune
    printf '%s\n' "$destination"
}

vpf_commit_candidate() {
    local candidate_config="$1" reason="${2:-update}"
    local candidate_rules transaction previous_rules backup_path state_candidate

    vpf_validate_config "$candidate_config" || return
    vpf_assert_safe_path "$VPF_STATE_FILE" || return
    candidate_rules="$(vpf_make_tmp)" || return
    transaction="$(vpf_make_tmp)" || return
    previous_rules="$(vpf_make_tmp)" || return
    vpf_generate_ruleset "$candidate_config" "$candidate_rules" || return
    vpf_build_transaction "$candidate_rules" "$transaction" || return
    vpf_nft_check "$transaction" || {
        vpf_die "nftables 候选配置语法检查失败"
        return
    }

    if [[ "$VPF_DRY_RUN" == "1" ]]; then
        printf '%s\n' '--- 候选配置 ---'
        cat -- "$candidate_config"
        printf '%s\n' '--- 将生成的 nftables 规则 ---'
        cat -- "$candidate_rules"
        printf '%s\n' '--- 将执行的 nftables 事务 ---'
        cat -- "$transaction"
        printf '%s\n' 'DRY-RUN：未修改配置、nftables 或系统文件。'
        return 0
    fi

    if [[ -f "$VPF_GENERATED_FILE" && ! -L "$VPF_GENERATED_FILE" ]]; then
        cp -- "$VPF_GENERATED_FILE" "$previous_rules"
    else
        vpf_write_empty_ruleset "$previous_rules"
    fi
    backup_path="$(vpf_backup_create "$reason")" || return
    vpf_info "已自动备份到 $backup_path"
    state_candidate="$(vpf_make_tmp)" || return
    {
        printf 'last_apply=%s\n' "$(vpf_now)"
        printf 'last_backup=%s\n' "${backup_path##*/}"
    } >"$state_candidate"

    if ! vpf_nft_apply "$transaction" "$candidate_rules" || ! vpf_verify_applied; then
        vpf_warn "应用或验证失败，正在恢复之前的项目规则"
        VPF_MOCK_FAIL_VERIFY=0 vpf_restore_ruleset_file "$previous_rules" || true
        vpf_log "apply failed reason=$reason rollback=attempted"
        vpf_die "应用失败；旧配置未改动"
        return
    fi

    if ! vpf_atomic_copy "$candidate_config" "$VPF_CONFIG_FILE" ||
        ! vpf_atomic_copy "$candidate_rules" "$VPF_GENERATED_FILE"; then
        vpf_warn "持久化配置失败，正在回滚项目规则"
        VPF_MOCK_FAIL_VERIFY=0 vpf_restore_ruleset_file "$previous_rules" || true
        if [[ -f "$backup_path/config.tsv" ]]; then
            vpf_atomic_copy "$backup_path/config.tsv" "$VPF_CONFIG_FILE" || true
        fi
        if [[ -f "$backup_path/generated.nft" ]]; then
            vpf_atomic_copy "$backup_path/generated.nft" "$VPF_GENERATED_FILE" || true
        fi
        vpf_die "持久化失败，已尝试恢复之前状态"
        return
    fi
    if ! vpf_atomic_copy "$state_candidate" "$VPF_STATE_FILE"; then
        vpf_warn "规则已应用，但无法更新非关键状态元数据"
    fi
    vpf_log "apply success reason=$reason"
}

vpf_write_empty_ruleset() {
    local output="$1" empty_config
    empty_config="$(vpf_make_tmp)" || return
    vpf_write_empty_config "$empty_config"
    vpf_generate_ruleset "$empty_config" "$output"
}

vpf_apply_current() {
    local candidate
    vpf_ensure_config || return
    vpf_validate_config "$VPF_CONFIG_FILE" || return
    candidate="$(vpf_make_tmp)" || return
    cp -- "$VPF_CONFIG_FILE" "$candidate"
    vpf_commit_candidate "$candidate" "apply"
}

vpf_delete_project_tables() {
    local transaction
    vpf_verify_table_owner ip vps_forward_nat || return
    vpf_verify_table_owner inet vps_forward_filter || return
    transaction="$(vpf_make_tmp)" || return
    : >"$transaction"
    vpf_table_exists ip vps_forward_nat && printf 'delete table ip vps_forward_nat\n' >>"$transaction"
    vpf_table_exists inet vps_forward_filter && printf 'delete table inet vps_forward_filter\n' >>"$transaction"
    [[ -s "$transaction" ]] || return 0
    if [[ "$VPF_DRY_RUN" == "1" ]]; then
        cat -- "$transaction"
    elif [[ "$VPF_SYSTEM_MODE" == "mock" ]]; then
        rm -f -- "$VPF_MOCK_DIR/active.nft"
    else
        "$VPF_NFT_BIN" --check --file "$transaction"
        "$VPF_NFT_BIN" --file "$transaction"
    fi
}
