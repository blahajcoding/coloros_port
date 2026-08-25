#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

blue() { :; }
green() { :; }
yellow() { :; }
error() { printf '%s\n' "$2" >&2; }
work_dir="$fixture"
source "$repo_dir/lib/selinux_merge.sh"

base="$fixture/base"
port="$fixture/port"

mkdir -p \
    "$base/system/system/etc/selinux/mapping" \
    "$base/system_ext/etc/selinux/mapping" \
    "$base/product/etc/selinux/mapping" \
    "$port/system/system/etc/selinux/mapping" \
    "$port/system_ext/etc/selinux/mapping" \
    "$port/product/etc/selinux/mapping" \
    "$port/config" \
    "$port/vendor/etc/selinux" \
    "$port/odm/etc/selinux"

printf '30.0\n' > "$port/vendor/etc/selinux/plat_sepolicy_vers.txt"
printf 'base-platform\n' > "$base/system/system/etc/selinux/mapping/30.0.cil"
printf 'base-compat\n' > "$base/system/system/etc/selinux/mapping/30.0.compat.cil"
printf 'base-system-ext\n' > "$base/system_ext/etc/selinux/mapping/30.0.cil"
printf 'base-product\n' > "$base/product/etc/selinux/mapping/30.0.cil"
printf '/system/system/etc/selinux/mapping/30\\.0\\.cil u:object_r:system_file:s0\n' \
    > "$port/config/system_file_contexts"
: > "$port/config/system_ext_file_contexts"
: > "$port/config/product_file_contexts"

# Existing PORTROM content must not be overwritten.
printf 'port-product\n' > "$port/product/etc/selinux/mapping/30.0.cil"

preserve_base_selinux_compat_mappings "$base" "$port"

grep -qx 'base-platform' "$port/system/system/etc/selinux/mapping/30.0.cil"
grep -qx 'base-compat' "$port/system/system/etc/selinux/mapping/30.0.compat.cil"
grep -qx 'base-system-ext' "$port/system_ext/etc/selinux/mapping/30.0.cil"
grep -qx 'port-product' "$port/product/etc/selinux/mapping/30.0.cil"
grep -qx '/system/system/etc/selinux/mapping/30\\.0\\.cil u:object_r:sepolicy_file:s0' \
    "$port/config/system_file_contexts"
grep -qx '/system_ext/etc/selinux/mapping/30\\.0\\.cil u:object_r:sepolicy_file:s0' \
    "$port/config/system_ext_file_contexts"
grep -qx '/product/etc/selinux/mapping/30\\.0\\.cil u:object_r:sepolicy_file:s0' \
    "$port/config/product_file_contexts"
! grep -q '30\\.0\\.cil u:object_r:system_file:s0' \
    "$port/config/system_file_contexts"

# Exercise the compile-gate argument construction with a deterministic fake
# compiler.  Real-policy integration is performed by the repair workflow.
printf 'plat\n' > "$port/system/system/etc/selinux/plat_sepolicy.cil"
printf 'system-ext\n' > "$port/system_ext/etc/selinux/system_ext_sepolicy.cil"
printf 'product\n' > "$port/product/etc/selinux/product_sepolicy.cil"
printf 'pub\n' > "$port/vendor/etc/selinux/plat_pub_versioned.cil"
printf 'vendor\n' > "$port/vendor/etc/selinux/vendor_sepolicy.cil"
printf 'odm\n' > "$port/odm/etc/selinux/odm_sepolicy.cil"

fake_bin="$fixture/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/secilc-modern" <<'EOF'
#!/bin/bash
set -e
out=
while (($#)); do
    if [[ "$1" == -o ]]; then
        out="$2"
        shift 2
        continue
    fi
    shift
done
[[ -n "$out" ]]
printf 'compiled\n' > "$out"
EOF
chmod 0755 "$fake_bin/secilc-modern"

PATH="$fake_bin:$PATH" SECILC_BIN="$fake_bin/secilc-modern" \
    validate_split_selinux_policy "$port"

grep -qx compiled "$fixture/tmp/selinux-compile-check/sepolicy"

# A missing platform mapping is fatal.
rm -f "$port/system/system/etc/selinux/mapping/30.0.cil"
if validate_split_selinux_policy "$port" 2>/dev/null; then
    echo 'missing required mapping unexpectedly passed' >&2
    exit 1
fi

echo 'SELinux mapping tests passed'
