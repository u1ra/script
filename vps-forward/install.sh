#!/bin/sh

set -eu

REPO_SLUG="${VPF_REPO_SLUG:-u1ra/script}"
INSTALL_REF="${VPF_INSTALL_VERSION:-main}"
EXPECTED_SHA256="${VPF_SHA256:-}"
TEMP_DIR=""

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT HUP INT TERM

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

run_main_installer() {
    main_script="$1"
    shift
    if [ -c /dev/tty ] && (: </dev/tty) 2>/dev/null; then
        bash "$main_script" install "$@" </dev/tty
    else
        bash "$main_script" install "$@"
    fi
}

[ "$(id -u)" -eq 0 ] || die "安装需要 root 权限，请使用 sudo ./install.sh"
[ -r /etc/os-release ] || die "无法识别系统：缺少 /etc/os-release"

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian)
        if ! command -v bash >/dev/null 2>&1; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y bash
        fi
        ;;
    alpine)
        if ! command -v bash >/dev/null 2>&1; then
            apk add --no-cache bash
        fi
        ;;
    *)
        case " ${ID_LIKE:-} " in
            *" debian "*)
                if ! command -v bash >/dev/null 2>&1; then
                    apt-get update
                    DEBIAN_FRONTEND=noninteractive apt-get install -y bash
                fi
                ;;
            *) die "不支持的系统: ${ID:-unknown}；仅支持 Ubuntu、Debian、Alpine" ;;
        esac
        ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/vps-forward.sh" ] &&
    [ -f "$SCRIPT_DIR/lib/vps-forward-core.sh" ]; then
    run_main_installer "$SCRIPT_DIR/vps-forward.sh" "$@"
    exit $?
fi

command -v tar >/dev/null 2>&1 || die "远程安装需要 tar"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    case "${ID:-}" in
        alpine) apk add --no-cache curl ;;
        *) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ;;
    esac
fi

TEMP_DIR=$(mktemp -d)
ARCHIVE="$TEMP_DIR/source.tar.gz"
URL="https://github.com/$REPO_SLUG/archive/refs/heads/$INSTALL_REF.tar.gz"
case "$INSTALL_REF" in
    v[0-9]*|[0-9]*)
        URL="https://github.com/$REPO_SLUG/archive/refs/tags/$INSTALL_REF.tar.gz"
        ;;
esac

printf '将从 %s 下载源码。\n' "$URL"
if command -v curl >/dev/null 2>&1; then
    curl --fail --location --proto '=https' --tlsv1.2 --output "$ARCHIVE" "$URL"
else
    wget --https-only --output-document="$ARCHIVE" "$URL"
fi

if [ -n "$EXPECTED_SHA256" ]; then
    command -v sha256sum >/dev/null 2>&1 || die "指定了 VPF_SHA256，但系统缺少 sha256sum"
    printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE" | sha256sum -c -
else
    printf '警告: 未提供 VPF_SHA256；便捷安装无法验证发布包内容。生产环境请下载固定版本并校验 SHA256。\n' >&2
fi

tar -xzf "$ARCHIVE" -C "$TEMP_DIR"
SOURCE_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
if [ -f "$SOURCE_DIR/vps-forward/vps-forward.sh" ] &&
    [ -f "$SOURCE_DIR/vps-forward/lib/vps-forward-core.sh" ]; then
    SOURCE_DIR="$SOURCE_DIR/vps-forward"
fi
[ -f "$SOURCE_DIR/vps-forward.sh" ] || die "下载包中缺少 vps-forward.sh"
[ -f "$SOURCE_DIR/lib/vps-forward-core.sh" ] || die "下载包中缺少核心库"
run_main_installer "$SOURCE_DIR/vps-forward.sh" "$@"
