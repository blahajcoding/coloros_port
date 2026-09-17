#!/bin/bash
# Inspect APKs that live inside OPEX modules (system_ext/opex/*.opex).
#
# Background
# ----------
# A16 ships several system components as OPEX modules: an APK-shaped container
# whose payload is an ext4 image mounted at /mnt/opex/<name>@<version>.
#
# CustCore.opex carries com.oplus.customize.coreapp, the package providing
#   content://com.oplus.customize.coreapp.configmanager.configprovider.AppFeatureProvider
# Its inner APK is platform-signed and the outer OPEX container has a separate
# OEM signature. Editing AndroidManifest.xml invalidates both layers. When that
# happened PackageManager did not merely disable the test package: the OPEX was
# never mounted and com.oplus.customize.coreapp was absent. OplusLauncher then
# lost the AppFeature provider used by Seedling/Fluid Cloud card pinning.
#
# android:testOnly must therefore be left intact. A preinstalled, correctly
# signed copy is accepted by PackageManager; the build-time fix is to preserve
# and verify both OEM signatures, not to rewrite the manifest.

# Rewrite one APK inside an OPEX module's ext4 payload.
#
# $1: path to the .opex file (modified in place)
# $2: path of the APK inside the image, e.g. priv-app/CustCoreApp/CustCore.apk
# $3..: command + args to run against the extracted AndroidManifest.xml
patch_apk_inside_opex() {
    local opex
    opex=$(realpath "$1")
    local apk_in_img="$2"
    shift 2

    if [[ ! -f "$opex" ]]; then
        yellow "opex 不存在: $(basename "$opex")" "opex not found: $(basename "$opex")"
        return 1
    fi
    if ! command -v debugfs >/dev/null 2>&1; then
        yellow "缺少 debugfs，跳过 opex 修补" "debugfs missing, skipping opex patch"
        return 1
    fi

    local name work
    name=$(basename "$opex")
    work="${work_dir}/tmp/opex_$(basename "${opex%.opex}")"
    rm -rf "$work"
    mkdir -p "$work"

    if ! unzip -o -q "$opex" opex.img -d "$work" 2>/dev/null; then
        yellow "无法从 ${name} 提取 opex.img" "Cannot extract opex.img from ${name}"
        rm -rf "$work"
        return 1
    fi

    # Pull the APK out of the ext4 payload.
    if ! debugfs -R "dump -p /${apk_in_img} ${work}/target.apk" "${work}/opex.img" \
            >/dev/null 2>&1 || [[ ! -s "${work}/target.apk" ]]; then
        yellow "在 ${name} 中未找到 ${apk_in_img}" "${apk_in_img} not found in ${name}"
        rm -rf "$work"
        return 1
    fi

    local inode_stat inode_mode inode_uid inode_gid
    inode_stat=$(debugfs -R "stat /${apk_in_img}" "${work}/opex.img" 2>/dev/null)
    inode_mode=$(sed -n 's/.*Mode:[[:space:]]*\([0-7]\+\).*/\1/p' <<< "$inode_stat")
    inode_uid=$(sed -n 's/.*User:[[:space:]]*\([0-9]\+\).*/\1/p' <<< "$inode_stat")
    inode_gid=$(sed -n 's/.*Group:[[:space:]]*\([0-9]\+\).*/\1/p' <<< "$inode_stat")
    if [[ -z "$inode_mode" || -z "$inode_uid" || -z "$inode_gid" ]]; then
        error "无法读取 ${apk_in_img} 的 inode 元数据" \
              "Failed to read inode metadata for ${apk_in_img}"
        rm -rf "$work"
        return 1
    fi
    debugfs -R \
        "ea_get -f ${work}/selinux.xattr /${apk_in_img} security.selinux" \
        "${work}/opex.img" >/dev/null 2>&1 || rm -f "${work}/selinux.xattr"

    mkdir -p "${work}/m"
    if ! unzip -o -q "${work}/target.apk" AndroidManifest.xml -d "${work}/m" 2>/dev/null; then
        yellow "无法提取 AndroidManifest.xml" "Cannot extract AndroidManifest.xml"
        rm -rf "$work"
        return 1
    fi

    "$@" "${work}/m/AndroidManifest.xml"
    local transform_status=$?
    if [[ "$transform_status" -eq 2 ]]; then
        blue "${name}: 无需修改" "${name}: nothing to change"
        rm -rf "$work"
        return 0
    elif [[ "$transform_status" -ne 0 ]]; then
        error "${name}: AndroidManifest 转换失败 (${transform_status})" \
              "${name}: AndroidManifest transform failed (${transform_status})"
        rm -rf "$work"
        return 1
    fi

    # Put the manifest back. The edit is length-preserving, so the APK's
    # overall layout does not shift.
    ( cd "${work}/m" && zip -q "${work}/target.apk" AndroidManifest.xml ) || {
        error "回写 AndroidManifest 失败" "Failed to write back AndroidManifest"
        rm -rf "$work"
        return 1
    }
    align_apk_in_place "${work}/target.apk" || {
        rm -rf "$work"
        return 1
    }

    # Write the APK back into the ext4 image. debugfs needs the old inode gone
    # before it will accept a replacement of a different size.
    debugfs -w -R "rm /${apk_in_img}" "${work}/opex.img" >/dev/null 2>&1
    if ! debugfs -w -R "write ${work}/target.apk ${apk_in_img}" "${work}/opex.img" \
            >/dev/null 2>&1; then
        error "回写 APK 到 opex.img 失败" "Failed to write APK into opex.img"
        rm -rf "$work"
        return 1
    fi
    debugfs -w -R \
        "set_inode_field /${apk_in_img} mode 010${inode_mode}" \
        "${work}/opex.img" >/dev/null 2>&1 &&
    debugfs -w -R \
        "set_inode_field /${apk_in_img} uid ${inode_uid}" \
        "${work}/opex.img" >/dev/null 2>&1 &&
    debugfs -w -R \
        "set_inode_field /${apk_in_img} gid ${inode_gid}" \
        "${work}/opex.img" >/dev/null 2>&1 || {
        error "恢复 APK inode 元数据失败" "Failed to restore APK inode metadata"
        rm -rf "$work"
        return 1
    }
    if [[ -s "${work}/selinux.xattr" ]]; then
        debugfs -w -R \
            "ea_set -f ${work}/selinux.xattr /${apk_in_img} security.selinux" \
            "${work}/opex.img" >/dev/null 2>&1 || {
            error "恢复 APK SELinux xattr 失败" \
                  "Failed to restore APK SELinux xattr"
            rm -rf "$work"
            return 1
        }
    fi

    e2fsck -fy "${work}/opex.img" >/dev/null 2>&1 || true

    # Replace opex.img inside the .opex container (which is itself a zip).
    ( cd "$work" && zip -q "$opex" opex.img ) || {
        error "回写 opex.img 到 ${name} 失败" "Failed to write opex.img back into ${name}"
        rm -rf "$work"
        return 1
    }

    green "${name}: 已修补 ${apk_in_img}" "${name}: patched ${apk_in_img}"
    rm -rf "$work"
    return 0
}

# Verify the outer OPEX signature and the inner CustCore.apk signature. The
# outer package targets a modern platform, so apksigner must not apply its
# legacy API 9-17 JAR-signing compatibility check.
validate_custcore_opex_signatures() {
    local opex
    opex=$(find build/portrom/images -type f -name "CustCore.opex" -print -quit 2>/dev/null)

    if [[ -z "$opex" ]]; then
        # Older ColorOS layouts use a normal priv-app instead of OPEX.
        return 0
    fi

    if ! apksigner verify --min-sdk-version 18 "$opex" >/dev/null 2>&1; then
        error "CustCore.opex 外层 OEM 签名无效" \
              "CustCore.opex outer OEM signature is invalid"
        return 1
    fi

    local work inner_apk
    work=$(mktemp -d "${work_dir}/tmp/custcore_verify.XXXXXX") || return 1
    inner_apk="${work}/CustCore.apk"

    if ! unzip -o -q "$opex" opex.img -d "$work" 2>/dev/null ||
       ! debugfs -R \
           "dump -p /priv-app/CustCoreApp/CustCore.apk ${inner_apk}" \
           "${work}/opex.img" >/dev/null 2>&1 ||
       [[ ! -s "$inner_apk" ]]; then
        error "CustCore.opex から内部 APK を抽出できません" \
              "Cannot extract the inner APK from CustCore.opex"
        rm -rf "$work"
        return 1
    fi

    if ! apksigner verify "$inner_apk" >/dev/null 2>&1; then
        error "CustCore.apk 内层 OEM 签名无效" \
              "CustCore.apk inner OEM signature is invalid"
        rm -rf "$work"
        return 1
    fi

    rm -rf "$work"
    return 0
}

# Kept under the old name so existing port.sh call sites remain compatible.
# This function intentionally performs no mutation.
fix_custcore_testonly() {
    blue "保留 CustCore OEM 签名 (修复流体云卡片固定)" \
         "Preserving CustCore OEM signatures (fixes Fluid Cloud card pinning)"

    validate_custcore_opex_signatures
}
