#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/devices/common" \
    "$fixture/build/portrom/images/my_product/app/AudioEffectCenter"
ln -s "$repo_dir/devices/common/dolby_fix.zip" "$fixture/devices/common/dolby_fix.zip"
apk="$fixture/build/portrom/images/my_product/app/AudioEffectCenter/AudioEffectCenter.apk"
printf 'donor platform-signed APK\n' > "$apk"
before=$(sha256sum "$apk")

# Exercise the actual overlay command used by port.sh without running a full port.
mapfile -t commands < <(grep -E '^[[:space:]]*unzip .*devices/common/dolby_fix.zip' "$repo_dir/port.sh")
[[ ${#commands[@]} == 1 ]]
cd "$fixture"
for attempt in 1 2; do
    bash -ec "${commands[0]}"
    [[ $(sha256sum "$apk") == "$before" ]]
    [[ -s build/portrom/images/odm/etc/dolby/multimedia_dolby_dax_default.xml ]]
    [[ ! -e build/portrom/images/my_product/app/AudioEffectCenter/oat ]]
done

# A donor without this app must not acquire the incompatible legacy APK either.
rm "$apk"
bash -ec "${commands[0]}"
[[ ! -e "$apk" ]]
echo 'Dolby overlay preserves donor APK and only installs ODM fixes: PASS'
