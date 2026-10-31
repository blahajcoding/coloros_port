#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
source "$repo_dir/lib/compat_fixes.sh"
error() { printf '%s\n' "$2" >&2; }
cd "$fixture"
mkdir -p otatools/bin images/system/system/framework images/system_ext/app
cat > otatools/bin/aapt2 <<'SH'
#!/bin/bash
[[ "$1 $2 $4 $5" == 'dump xmltree --file AndroidManifest.xml' ]] || exit 1
cat "$3.manifest"
SH
chmod +x otatools/bin/aapt2

# Mock tool output, not the validator: exercise failures, parsing and signer groups.
apksigner() {
    [[ "$1 $2" == 'verify --print-certs' ]] || return 1
    local certificate
    [[ $(cat "$3.cert") != invalid ]] || return 1
    while IFS= read -r certificate; do
        printf 'Signer #1 certificate SHA-256 digest: %s\n' "$certificate"
    done < "$3.cert"
}
donor=$(printf '%064d' 1)
testkey=$(printf '%064d' 2)
apk() {
    touch "$1"
    printf '%s\n' "$2" > "$1.cert"
    printf 'E: manifest (line=1)\n' > "$1.manifest"
    if [[ -n "$3" ]]; then
        printf '  A: http://schemas.android.com/apk/res/android:sharedUserId(0x0101000b)="%s" (Raw: "%s")\n' "$3" "$3" >> "$1.manifest"
    fi
}
reject() {
    if validate_shared_uid_signatures images > result.log 2>&1; then
        echo 'expected shared-UID validation to fail' >&2
        exit 1
    fi
}
platform=images/system/system/framework/framework-res.apk
battery='images/system_ext/app/Battery test.apk'
overlay=images/system_ext/app/WifiOverlay.apk
apk "$platform" "$donor" ''
apk "$battery" "$donor" android.uid.system
apk "$overlay" "$testkey" ''
validate_shared_uid_signatures images

apk "$battery" "$testkey" android.uid.system
reject
grep -Fq "Shared-UID signer mismatch (android.uid.system): $battery" result.log
apk "$battery" "$donor" android.uid.system
apk images/system_ext/app/Other.apk "$testkey" com.oplus.other
apk images/system_ext/app/Other2.apk "$testkey" com.oplus.other
validate_shared_uid_signatures images
printf '%s\n' "$donor" > images/system_ext/app/Other2.apk.cert
reject
grep -Fq 'Shared-UID signer mismatch (com.oplus.other)' result.log
printf '%s\n' "$testkey" > images/system_ext/app/Other2.apk.cert

for cert in invalid '' 'not-a-sha256'; do
    printf '%s\n' "$cert" > "$battery.cert"
    reject
done
apk "$battery" "$donor" android.uid.system
for manifest in '' 'E: manifest (line=1)
  A: android:sharedUserId(0x0101000b)=@0x7f010001'; do
    printf '%s\n' "$manifest" > "$battery.manifest"
    reject
done
rm "$battery.manifest"
reject
apk "$battery" "$donor" 'invalid[shared-uid]'
reject
apk "$battery" "$donor" android.uid.system

# Multisigner order does not change identity; missing/invalid platform fails closed.
printf '%s\n%s\n' "$donor" "$testkey" > "$platform.cert"
printf '%s\n%s\n' "$testkey" "$donor" > "$battery.cert"
validate_shared_uid_signatures images
printf 'invalid\n' > "$platform.cert"
reject
rm "$platform.cert"
reject

python3 - "$repo_dir" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
port = (root / 'port.sh').read_text()
assert 'sign_apk_in_place' not in port, 'OEM APK testkey signing reintroduced'
assert not re.search(r'patched/[^\s/]+\.apk', port), 'patched APK cache import reintroduced'
assert 'devices/common/OTA_CN.apk' not in port
assert 'devices/common/OTA_IN.apk' not in port
assert 'validate_critical_port_artifacts || exit 1' in port
assert 'validate_shared_uid_signatures || failed=1' in (root / 'lib/compat_fixes.sh').read_text()
PY
echo 'Shared-UID signer validation and donor APK preservation: PASS'
