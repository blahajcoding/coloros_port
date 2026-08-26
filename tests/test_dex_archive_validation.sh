#!/bin/bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d /tmp/coloros-dex-validation.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT

error() { :; }
yellow() { :; }
green() { :; }

source "${repo_dir}/lib/compat_fixes.sh"

make_archive() {
    local name="$1"
    local size="$2"
    local magic="$3"
    local archive_dir="${test_dir}/${name}"

    mkdir -p "$archive_dir"
    printf '%b' "$magic" > "${archive_dir}/classes.dex"
    truncate -s "$size" "${archive_dir}/classes.dex"
    (cd "$archive_dir" && zip -q "${test_dir}/${name}.jar" classes.dex)
}

expect_rejected() {
    if validate_dex_archive "$@" >/dev/null 2>&1; then
        printf 'expected rejection: %s\n' "$1" >&2
        exit 1
    fi
}

make_archive source 4096 'dex\n041\0'
make_archive valid 4080 'dex\n041\0'
make_archive tiny 140 'dex\n041\0'
make_archive bad_magic 4096 'not-a-dex'
make_archive shrunken 1500 'dex\n041\0'

validate_dex_archive "${test_dir}/valid.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/tiny.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/bad_magic.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/shrunken.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/missing.jar" "${test_dir}/source.jar" 1024

printf 'DEX archive validation tests passed\n'
