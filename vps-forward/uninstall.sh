#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x /usr/local/sbin/vps-forward ]]; then
    exec /usr/local/sbin/vps-forward uninstall "$@"
elif [[ -x "$SCRIPT_DIR/vps-forward.sh" ]]; then
    exec "$SCRIPT_DIR/vps-forward.sh" uninstall "$@"
else
    printf '错误: 找不到 vps-forward 主程序。\n' >&2
    exit 1
fi
