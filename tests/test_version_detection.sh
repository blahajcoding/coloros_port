#!/bin/bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d /tmp/coloros-version-detection.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT

error() { :; }
yellow() { :; }
green() { :; }

source "${repo_dir}/functions.sh"

printf '%s\n' \
    'ro.build.version.release=16' > "$test_dir/preview-system.prop"
printf '%s\n' \
    'ro.build.version.release_or_codename=17' > "$test_dir/preview-manifest.prop"
printf '%s\n' \
    'ro.build.version.release=14' \
    'ro.build.version.release_or_codename=14' > "$test_dir/stable.prop"
printf '%s\n' \
    'ro.build.version.release=16' \
    'ro.build.version.release_or_codename=CinnamonBun' > "$test_dir/codename.prop"

[[ $(android_platform_version_from_prop \
    "$test_dir/preview-system.prop" "$test_dir/preview-manifest.prop") == 17 ]]
[[ $(android_platform_version_from_prop "$test_dir/stable.prop") == 14 ]]
[[ $(android_platform_version_from_prop "$test_dir/codename.prop") == 16 ]]
[[ $(canonical_oplusrom_version V17.0) == 17.0.0 ]]
[[ $(canonical_oplusrom_version 17.0.0.1) == 17.0.0 ]]

printf '%s\n' \
    'ro.build.version.oplusrom=V16.0.0' \
    'ro.build.version.oplusrom.display=16.0' > "$test_dir/oplus.prop"
set_prop_value "$test_dir/oplus.prop" ro.build.version.oplusrom V17.0.0
set_prop_value "$test_dir/oplus.prop" ro.build.version.oplusrom.display 17.0
set_prop_value "$test_dir/oplus.prop" ro.build.version.oplusrom.confidential V17.0.0
grep -Fqx 'ro.build.version.oplusrom=V17.0.0' "$test_dir/oplus.prop"
grep -Fqx 'ro.build.version.oplusrom.display=17.0' "$test_dir/oplus.prop"
grep -Fqx 'ro.build.version.oplusrom.confidential=V17.0.0' "$test_dir/oplus.prop"

printf 'Android/ColorOS version detection tests passed\n'
