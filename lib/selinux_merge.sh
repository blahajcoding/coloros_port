#!/bin/bash
# SELinux context merge for cross-version ports.
#
# Problem this solves
# -------------------
# A port keeps vendor/odm from the BASE ROM but takes system/system_ext/product
# from the PORT ROM. SELinux labels for vendor-side services and properties live
# in the *vendor* partition, so every service or property that the port ROM
# introduced has no label on the resulting device. servicemanager then falls
# back to default_android_service / default_prop and the access is denied.
#
# Measured on OnePlus 9 Pro (A14 base) + OnePlus 15 (A16 port):
#   214 SELinux denials; 10 of the 11 denied services were exactly the
#   definitions present in the port ROM's vendor_service_contexts but absent
#   from the base ROM's.
#
# Strategy
# --------
# For every context file we append ONLY the entries the base ROM does not
# already define. Base labels are never overwritten - the A14 vendor binaries
# depend on them.
#
# A raw append is not enough: an entry may reference an SELinux type that the
# base policy does not declare, and servicemanager refuses to parse a context
# file pointing at an unknown type. So each candidate entry is validated
# against the base policy first, and any missing type is declared (together
# with its roletype and the allow rules that make it reachable) in a CIL
# fragment appended to vendor_sepolicy.cil.

# Extract the port ROM's vendor partition into a scratch dir so its SELinux
# context files can be read. The port vendor is NOT used for anything else -
# the device keeps the base ROM's vendor.
#
# $1: path to the port ROM zip
# $2: destination directory
# Sets: port_vendor_dir (empty on failure)
extract_port_vendor_for_selinux() {
    local portrom_zip="$1"
    local dest="$2"

    port_vendor_dir=""

    if [[ -d "${dest}/vendor" ]]; then
        port_vendor_dir="${dest}/vendor"
        blue "复用已解包的移植包 vendor" "Reusing already-extracted PORTROM vendor"
        return 0
    fi

    mkdir -p "$dest"
    blue "为 SELinux 合并解包移植包 vendor" "Extracting PORTROM vendor for SELinux merge"

    if [[ ! -f "${dest}/vendor.img" ]]; then
        payload-dumper --partitions vendor --out "$dest" "$portrom_zip" >/dev/null 2>&1 || {
            yellow "移植包 vendor 提取失败，跳过 SELinux 合并" \
                   "Failed to extract PORTROM vendor, skipping SELinux merge"
            return 1
        }
    fi

    [[ -f "${dest}/vendor.img" ]] || {
        yellow "未找到移植包 vendor.img，跳过 SELinux 合并" \
               "PORTROM vendor.img not found, skipping SELinux merge"
        return 1
    }

    extract_partition "${dest}/vendor.img" "$dest" || {
        yellow "移植包 vendor 解包失败，跳过 SELinux 合并" \
               "Failed to unpack PORTROM vendor, skipping SELinux merge"
        return 1
    }

    if [[ -d "${dest}/vendor" ]]; then
        port_vendor_dir="${dest}/vendor"
        return 0
    fi

    yellow "移植包 vendor 目录缺失，跳过 SELinux 合并" \
           "PORTROM vendor dir missing, skipping SELinux merge"
    return 1
}

# True when $1 is declared as a type or typeattribute anywhere in the base
# policy (vendor_sepolicy.cil or plat_pub_versioned.cil).
_selinux_type_known() {
    local t="$1" seldir="$2"
    grep -qE "\(type ${t}\)|\(typeattribute ${t}\)" \
        "${seldir}/vendor_sepolicy.cil" "${seldir}/plat_pub_versioned.cil" 2>/dev/null
}

# Pull the declaration of type $1 out of the port policy and emit a CIL
# fragment that declares it and grants the same access the port ROM granted.
# Only allow rules whose subject already exists in the base policy are copied,
# so we never reference an unknown domain.
_selinux_emit_type_cil() {
    local t="$1" port_cil="$2" base_seldir="$3" out="$4"

    grep -qE "^\(type ${t}\)" "$port_cil" 2>/dev/null || return 1

    # A type can be referenced by several context entries (and by several
    # context files). CIL rejects a duplicate (type ...) declaration, so emit
    # each one only once.
    if grep -qE "^\(type ${t}\)$" "$out" 2>/dev/null; then
        return 0
    fi

    {
        echo "(type ${t})"
        echo "(roletype object_r ${t})"
    } >> "$out"

    # service_manager needs the type to be a service_manager_type, otherwise
    # servicemanager rejects the lookup regardless of any allow rule.
    if grep -qE "typeattributeset service_manager_type \(.*\b${t}\b" "$port_cil" 2>/dev/null; then
        echo "(typeattributeset service_manager_type (${t}))" >> "$out"
    fi
    if grep -qE "typeattributeset hal_service_type \(.*\b${t}\b" "$port_cil" 2>/dev/null; then
        echo "(typeattributeset hal_service_type (${t}))" >> "$out"
    fi

    local rule subj
    while IFS= read -r rule; do
        subj=$(echo "$rule" | sed -n 's/^(allow \([A-Za-z0-9_]*\) .*/\1/p')
        [[ -n "$subj" ]] || continue
        # Never reference a domain the base policy does not know about.
        _selinux_type_known "$subj" "$base_seldir" || continue
        # The base policy may already grant this exact access.
        grep -qF "$rule" "${base_seldir}/vendor_sepolicy.cil" 2>/dev/null && continue
        grep -qF "$rule" "$out" 2>/dev/null && continue
        echo "$rule" >> "$out"
    done < <(grep -E "^\(allow [A-Za-z0-9_]+ ${t} " "$port_cil" 2>/dev/null)

    return 0
}

# Merge vendor_service_contexts / vendor_property_contexts /
# vendor_hwservice_contexts from the port ROM into the (base-derived) vendor
# that ships on the device, declaring any missing types along the way.
merge_vendor_selinux_contexts() {
    local base_seldir="build/portrom/images/vendor/etc/selinux"
    local port_seldir="${port_vendor_dir}/etc/selinux"

    if [[ -z "$port_vendor_dir" ]] || [[ ! -d "$port_seldir" ]]; then
        yellow "移植包 vendor SELinux 目录不可用，跳过" \
               "PORTROM vendor SELinux dir unavailable, skipping"
        return 0
    fi
    if [[ ! -d "$base_seldir" ]]; then
        yellow "底包 vendor SELinux 目录不存在，跳过" \
               "BASEROM vendor SELinux dir missing, skipping"
        return 0
    fi

    local port_cil="${port_seldir}/vendor_sepolicy.cil"
    local cil_add="${work_dir}/tmp/selinux_added.cil"
    : > "$cil_add"

    local total_added=0 total_skipped=0
    local ctx key label t added skipped

    for ctx in vendor_service_contexts vendor_hwservice_contexts vendor_property_contexts; do
        [[ -f "${base_seldir}/${ctx}" && -f "${port_seldir}/${ctx}" ]] || continue

        added=0
        skipped=0
        local pending="${work_dir}/tmp/${ctx}.add"
        : > "$pending"

        while read -r key label; do
            [[ -n "$key" && -n "$label" ]] || continue
            [[ "$key" == \#* ]] && continue

            # Already labelled by the base policy - leave it alone.
            grep -qE "^${key//./\\.}[[:space:]]" "${base_seldir}/${ctx}" && continue

            t=$(echo "$label" | cut -d: -f3)
            [[ -n "$t" ]] || continue

            if ! _selinux_type_known "$t" "$base_seldir"; then
                if ! _selinux_emit_type_cil "$t" "$port_cil" "$base_seldir" "$cil_add"; then
                    skipped=$((skipped + 1))
                    continue
                fi
            fi

            printf '%s %s\n' "$key" "$label" >> "$pending"
            added=$((added + 1))
        done < <(grep -vE '^\s*(#|$)' "${port_seldir}/${ctx}" | awk 'NF>=2 {print $1, $2}')

        if (( added > 0 )); then
            {
                echo ""
                echo "# --- merged from PORTROM (Android ${port_android_version}) ---"
                cat "$pending"
            } >> "${base_seldir}/${ctx}"
            green "  ${ctx}: +${added} 条" "  ${ctx}: +${added} entries"
        fi
        (( skipped > 0 )) && \
            yellow "  ${ctx}: 跳过 ${skipped} 条 (类型无法安全引入)" \
                   "  ${ctx}: skipped ${skipped} (type could not be introduced safely)"

        rm -f "$pending"
        total_added=$((total_added + added))
        total_skipped=$((total_skipped + skipped))
    done

    if [[ -s "$cil_add" ]]; then
        local ndecl
        ndecl=$(grep -c '^(type ' "$cil_add")
        {
            echo ""
            echo ";; --- types introduced for PORTROM services (coloros_port) ---"
            cat "$cil_add"
        } >> "${base_seldir}/vendor_sepolicy.cil"
        green "  vendor_sepolicy.cil: +${ndecl} 个类型" \
              "  vendor_sepolicy.cil: +${ndecl} types"

        # The debug policy must stay in sync or the debug build fails to load.
        if [[ -f "${base_seldir}/vendor_sepolicy_debug.cil" ]]; then
            {
                echo ""
                echo ";; --- types introduced for PORTROM services (coloros_port) ---"
                cat "$cil_add"
            } >> "${base_seldir}/vendor_sepolicy_debug.cil"
        fi
    fi

    rm -f "$cil_add"

    if (( total_added > 0 )); then
        green "SELinux 上下文合并完成: 共 ${total_added} 条" \
              "SELinux context merge done: ${total_added} entries"
    else
        blue "SELinux 上下文无需合并" "No SELinux context merge needed"
    fi

    grant_port_client_access "$base_seldir"
    return 0
}

# Some A16 system components look up a vendor HAL that the A14 vendor policy
# labels correctly but never grants their domain access to. The base ROM has no
# reason to allow it (nothing on A14 asked), and the port ROM's vendor policy
# does not cover it either, because on a real OnePlus 15 the caller runs in a
# different domain.
#
# Observed on device:
#   avc: denied { find } name=vendor.oplus.hardware.charger.ICharger/default
#        scontext=u:r:radio:s0 tcontext=u:object_r:hal_charger_service:s0
#
# com.oplus.nhs (uid 1001 -> radio) tries the AIDL charger first, is denied,
# falls back to the HIDL v1.0 interface which A16 no longer ships, and logs
# ClassNotFoundException: vendor.oplus.hardware.charger.V1_0.ICharger.
#
# Only service_manager:find is granted, and only to domains that already exist
# in the base policy for services the base policy already labels.
grant_port_client_access() {
    local seldir="$1"
    local cil="${seldir}/vendor_sepolicy.cil"
    [[ -f "$cil" ]] || return 0

    # subject:service pairs confirmed to be denied on a ported device.
    local grants=(
        "radio:hal_charger_service"
        "bluetooth:hal_charger_service"
        "stats:hal_oplus_touch_aidl_service"
    )

    local added=0 pair subj svc rule
    for pair in "${grants[@]}"; do
        subj="${pair%%:*}"
        svc="${pair#*:}"

        # Both sides must already be known to the base policy.
        _selinux_type_known "$subj" "$seldir" || continue
        _selinux_type_known "$svc" "$seldir" || continue

        rule="(allow ${subj} ${svc} (service_manager (find)))"
        grep -qF "$rule" "$cil" && continue

        if (( added == 0 )); then
            {
                echo ""
                echo ";; --- client access for PORTROM components (coloros_port) ---"
            } >> "$cil"
        fi
        echo "$rule" >> "$cil"
        [[ -f "${seldir}/vendor_sepolicy_debug.cil" ]] && \
            echo "$rule" >> "${seldir}/vendor_sepolicy_debug.cil"
        added=$((added + 1))
    done

    (( added > 0 )) && \
        green "  追加 ${added} 条客户端访问规则" "  Added ${added} client access rules"
    return 0
}
