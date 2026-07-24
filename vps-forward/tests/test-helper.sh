#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT="$(mktemp -d)"

export VPF_CONFIG_DIR="$TEST_ROOT/etc/vps-forward"
export VPF_CONFIG_FILE="$VPF_CONFIG_DIR/config.tsv"
export VPF_GENERATED_FILE="$VPF_CONFIG_DIR/generated.nft"
export VPF_BACKUP_DIR="$VPF_CONFIG_DIR/backups"
export VPF_LOCK_FILE="$VPF_CONFIG_DIR/lock"
export VPF_STATE_FILE="$VPF_CONFIG_DIR/state"
export VPF_LOG_FILE="$TEST_ROOT/var/log/vps-forward.log"
export VPF_MOCK_DIR="$TEST_ROOT/mock"
export VPF_SYSTEM_MODE=mock
export VPF_ALLOW_NON_ROOT=1
export VPF_QUIET=1

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/vps-forward-core.sh"
trap 'vpf_cleanup; rm -rf -- "$TEST_ROOT"' EXIT

TESTS_RUN=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'not ok %d - %s\n' "$TESTS_RUN" "$1" >&2
    exit 1
}

assert_true() {
    local description="$1"
    shift
    if "$@"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_false() {
    local description="$1"
    shift
    if "$@"; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_contains() {
    local description="$1" file="$2" text="$3"
    if grep -Fq -- "$text" "$file"; then
        pass "$description"
    else
        printf 'Missing text: %s\n' "$text" >&2
        fail "$description"
    fi
}

write_fixture_config() {
    local output="$1"
    mkdir -p -- "$(dirname -- "$output")"
    {
        printf '# vps-forward-config-v1\n'
        printf '# id\tenabled\tprotocol\tlisten_ip\tlisten_port\ttarget_ip\ttarget_port\tmasquerade_mode\tname\tcreated_at\tupdated_at\n'
        printf '1\t1\tboth\t*\t8443\t192.0.2.10\t20086\tprecise\tdemo\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n'
        printf '2\t1\ttcp\t198.51.100.2\t9443\t192.0.2.20\t443\tdestination\tweb\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n'
        printf '3\t0\tudp\t*\t5353\t192.0.2.30\t53\tnone\tdisabled\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n'
    } >"$output"
    chmod 600 "$output"
}
