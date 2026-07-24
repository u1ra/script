#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tests=(
    test-validation.sh
    test-generator.sh
    test-cli.sh
    test-reliability.sh
    test-install.sh
    test-menu.sh
)

for test_file in "${tests[@]}"; do
    printf '\n== %s ==\n' "$test_file"
    bash "$ROOT/tests/$test_file"
done

printf '\nAll tests passed.\n'
