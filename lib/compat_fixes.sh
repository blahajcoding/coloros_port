#!/bin/bash

elf_class() {
    local file="$1"
    LC_ALL=C readelf -h "$file" 2>/dev/null |
        awk -F: '/^[[:space:]]*Class:/{gsub(/[[:space:]]/, "", $2); print $2; exit}'
}

install_compat_library() {
    local source="$1"
    local destination="$2"
    local expected_class="$3"

    if [[ ! -f "$source" ]]; then
        error "兼容库不存在: ${source}" "Compatibility library not found: ${source}"
        return 1
    fi
    if [[ "$(elf_class "$source")" != "$expected_class" ]]; then
        error "兼容库 ABI 不匹配: ${source}" \
              "Compatibility library ABI mismatch: ${source}"
        return 1
    fi

    mkdir -p "$(dirname "$destination")"
    cp -f "$source" "$destination"
    chmod 0644 "$destination"
}

apply_mediaserver_compat() {
    local mediaserver="build/portrom/images/system/system/bin/mediaserver"
    local dependency="liboplusbindermonitor.so"

    [[ -f "$mediaserver" ]] || return 0
    readelf -d "$mediaserver" 2>/dev/null | grep -qF "[$dependency]" || return 0

    local server_class
    server_class=$(elf_class "$mediaserver")
    case "$server_class" in
        ELF32)
            local source32="${work_dir}/tmp/media-compat/liboplusbindermonitor.so"
            mkdir -p "$(dirname "$source32")"

            if [[ -f devices/common/16.1-mediaserver-fix.zip ]]; then
                unzip -p devices/common/16.1-mediaserver-fix.zip \
                    system_ext/lib/liboplusbindermonitor.so > "$source32" || {
                    error "无法提取 mediaserver 兼容库" \
                          "Failed to extract the mediaserver compatibility library"
                    return 1
                }
            elif [[ -f build/baserom/images/system/system/lib/$dependency ]]; then
                cp -f "build/baserom/images/system/system/lib/$dependency" "$source32"
            else
                error "缺少 32 位 ${dependency}，mediaserver 将无法启动" \
                      "Missing 32-bit ${dependency}; mediaserver cannot start"
                return 1
            fi

            install_compat_library "$source32" \
                "build/portrom/images/system/system/lib/$dependency" ELF32 || return 1
            install_compat_library "$source32" \
                "build/portrom/images/system_ext/lib/$dependency" ELF32 || return 1
            ;;
        ELF64)
            local source64=""
            for candidate in \
                "build/portrom/images/system_ext/lib64/$dependency" \
                "build/baserom/images/system/system/lib64/$dependency"; do
                if [[ -f "$candidate" && "$(elf_class "$candidate")" == "ELF64" ]]; then
                    source64="$candidate"
                    break
                fi
            done
            if [[ -z "$source64" ]]; then
                error "缺少 64 位 ${dependency}，mediaserver 将无法启动" \
                      "Missing 64-bit ${dependency}; mediaserver cannot start"
                return 1
            fi
            install_compat_library "$source64" \
                "build/portrom/images/system/system/lib64/$dependency" ELF64 || return 1
            ;;
        *)
            error "无法识别 mediaserver ABI" "Unable to determine mediaserver ABI"
            return 1
            ;;
    esac

    green "已安装 ${server_class} mediaserver 兼容库" \
          "Installed ${server_class} mediaserver compatibility library"
}

apply_gui_extension_compat() {
    local abi libdir expected_class
    for abi in 32 64; do
        if [[ "$abi" == "32" ]]; then
            libdir="lib"
            expected_class="ELF32"
        else
            libdir="lib64"
            expected_class="ELF64"
        fi

        local consumer="build/portrom/images/system/system/${libdir}/libgui.so"
        local source="build/portrom/images/system_ext/${libdir}/libguiextimpl.so"
        local destination="build/portrom/images/system/system/${libdir}/libguiextimpl.so"
        [[ -f "$consumer" && -f "$source" ]] || continue
        grep -aF 'libguiextimpl.so' "$consumer" >/dev/null || continue
        install_compat_library "$source" "$destination" "$expected_class" || return 1
    done
}

apply_codec2_lazy_hal_fix() {
    local rc="build/portrom/images/vendor/etc/init/vendor.qti.media.c2@1.0-service.rc"
    local manifest="build/portrom/images/vendor/etc/vintf/manifest/c2_manifest_vendor.xml"
    [[ -f "$rc" && -f "$manifest" ]] || return 0
    grep -q 'android.hardware.media.c2' "$manifest" || return 0
    grep -q 'IComponentStore' "$manifest" || return 0
    grep -q '<instance>default</instance>' "$manifest" || return 0

    local temp
    temp=$(mktemp "${work_dir}/tmp/codec2-rc.XXXXXX")
    awk '
        /^service[[:space:]]+vendor-qti-media-c2-hal-1-0[[:space:]]/ {
            in_service = 1
        }
        in_service && /^[^[:space:]]/ && !/^service[[:space:]]+vendor-qti-media-c2-hal-1-0[[:space:]]/ {
            if (!has_interface) {
                print "    interface android.hardware.media.c2@1.0::IComponentStore default"
            }
            if (!has_disabled) print "    disabled"
            if (!has_oneshot) print "    oneshot"
            in_service = 0
        }
        in_service && /^[[:space:]]+interface[[:space:]]+android.hardware.media.c2@1.0::IComponentStore[[:space:]]+default/ {
            has_interface = 1
        }
        in_service && /^[[:space:]]+disabled([[:space:]]|$)/ { has_disabled = 1 }
        in_service && /^[[:space:]]+oneshot([[:space:]]|$)/ { has_oneshot = 1 }
        { print }
        END {
            if (in_service) {
                if (!has_interface) {
                    print "    interface android.hardware.media.c2@1.0::IComponentStore default"
                }
                if (!has_disabled) print "    disabled"
                if (!has_oneshot) print "    oneshot"
            }
        }
    ' "$rc" > "$temp"
    cat "$temp" > "$rc"
    rm -f "$temp"

    local property_contexts="build/portrom/images/vendor/etc/selinux/vendor_property_contexts"
    if [[ -f "$property_contexts" ]] &&
       ! grep -qE '^vendor\.oplus\.media\.vpp\.[[:space:]]' "$property_contexts"; then
        printf '%s\n' \
            'vendor.oplus.media.vpp. u:object_r:vendor_oplus_prop:s0' \
            >> "$property_contexts"
    fi

    green "已修复 QTI Codec2 lazy HAL 的 init/VINTF 配对" \
          "Fixed QTI Codec2 lazy-HAL init/VINTF pairing"
}

apply_android17_wifi_vendor_cmd_compat() {
    [[ ${port_android_version:-0} -ge 17 ]] || return 0

    local wifi_service="build/portrom/images/odm/bin/hw/vendor.oplus.hardware.wifi-aidl-service"
    local vendor_cmd="build/portrom/images/vendor/etc/wifi/vendor_cmd.xml"
    [[ -f "$wifi_service" ]] || return 0
    strings "$wifi_service" 2>/dev/null |
        grep -qF '/vendor/bin/vendor_cmd_tool' || return 0

    if [[ ! -s "$vendor_cmd" ]]; then
        error "Android 17 Oplus Wi-Fi服务需要的vendor_cmd.xml缺失" \
              "vendor_cmd.xml required by the Android 17 Oplus Wi-Fi service is missing"
        return 1
    fi

    mkdir -p "${work_dir}/tmp" build/diagnostics/a17-compat/originals
    local additions output
    additions=$(mktemp "${work_dir}/tmp/vendor-cmd-additions.XXXXXX") || return 1
    output=$(mktemp "${work_dir}/tmp/vendor-cmd.XXXXXX") || {
        rm -f "$additions"
        return 1
    }

    # These are the Qualcomm SET_WIFI_CONFIGURATION IDs used by the official
    # ColorOS 17 vendor_cmd.xml. The A17 Oplus Wi-Fi AIDL service sends all
    # eight names when changing STA antenna mode. Android 14's XML stops at
    # CONFIG_NSS, so the legacy helper dereferences a missing attribute and
    # crashes in strtoul instead of returning the driver's result.
    local name id name_count exact_count
    while read -r name id; do
        name_count=$(xmlstarlet sel -t -v \
            "count(/WCN_VenTool/VendorCmd[@name='SET_WIFI_CONFIG']/Attribute[@name='${name}'])" \
            "$vendor_cmd" 2>/dev/null) || name_count=0
        exact_count=$(xmlstarlet sel -t -v \
            "count(/WCN_VenTool/VendorCmd[@name='SET_WIFI_CONFIG']/Attribute[@name='${name}' and @ID='${id}' and @TYPE='u8'])" \
            "$vendor_cmd" 2>/dev/null) || exact_count=0
        if [[ "$name_count" == 0 ]]; then
            printf '\t\t<Attribute name="%s" ID="%s" TYPE="u8"/>\n' \
                "$name" "$id" >> "$additions"
        elif [[ "$name_count" != 1 || "$exact_count" != 1 ]]; then
            rm -f "$additions" "$output"
            error "vendor_cmd.xml中的${name}定义错误或重复" \
                  "vendor_cmd.xml has an invalid or duplicate ${name} definition"
            return 1
        fi
    done <<'EOF'
CONFIG_TX_NSS_2GHZ 110
CONFIG_RX_NSS_2GHZ 111
CONFIG_TX_NSS_5GHZ 112
CONFIG_RX_NSS_5GHZ 113
CONFIG_NUM_TX_CHAINS_2GHZ 114
CONFIG_NUM_RX_CHAINS_2GHZ 115
CONFIG_NUM_TX_CHAINS_5GHZ 116
CONFIG_NUM_RX_CHAINS_5GHZ 117
EOF

    if [[ -s "$additions" ]]; then
        local backup="build/diagnostics/a17-compat/originals/vendor_cmd.xml"
        [[ -f "$backup" ]] || cp -p "$vendor_cmd" "$backup"
        if ! awk -v additions_file="$additions" '
            BEGIN {
                while ((getline line < additions_file) > 0)
                    additions = additions line ORS
                close(additions_file)
            }
            /<VendorCmd[[:space:]][^>]*name="SET_WIFI_CONFIG"/ {
                in_set_wifi = 1
                found_set_wifi = 1
            }
            in_set_wifi && /<\/VendorCmd>/ {
                printf "%s", additions
                in_set_wifi = 0
                inserted = 1
            }
            { print }
            END {
                if (!found_set_wifi || !inserted)
                    exit 42
            }
        ' "$vendor_cmd" > "$output"; then
            rm -f "$additions" "$output"
            error "vendor_cmd.xml中找不到SET_WIFI_CONFIG" \
                  "SET_WIFI_CONFIG was not found in vendor_cmd.xml"
            return 1
        fi
        mv -f "$output" "$vendor_cmd"
        chmod 0644 "$vendor_cmd"
    fi
    rm -f "$additions" "$output"

    if ! xmlstarlet val "$vendor_cmd" >/dev/null 2>&1; then
        error "修复后的vendor_cmd.xml无效" \
              "Patched vendor_cmd.xml is invalid"
        return 1
    fi
    while read -r name id; do
        name_count=$(xmlstarlet sel -t -v \
            "count(/WCN_VenTool/VendorCmd[@name='SET_WIFI_CONFIG']/Attribute[@name='${name}'])" \
            "$vendor_cmd" 2>/dev/null) || name_count=0
        exact_count=$(xmlstarlet sel -t -v \
            "count(/WCN_VenTool/VendorCmd[@name='SET_WIFI_CONFIG']/Attribute[@name='${name}' and @ID='${id}' and @TYPE='u8'])" \
            "$vendor_cmd" 2>/dev/null) || exact_count=0
        if [[ "$name_count" != 1 || "$exact_count" != 1 ]]; then
            error "vendor_cmd.xml缺少Android 17属性: ${name}" \
                  "vendor_cmd.xml is missing Android 17 attribute: ${name}"
            return 1
        fi
    done <<'EOF'
CONFIG_TX_NSS_2GHZ 110
CONFIG_RX_NSS_2GHZ 111
CONFIG_TX_NSS_5GHZ 112
CONFIG_RX_NSS_5GHZ 113
CONFIG_NUM_TX_CHAINS_2GHZ 114
CONFIG_NUM_RX_CHAINS_2GHZ 115
CONFIG_NUM_TX_CHAINS_5GHZ 116
CONFIG_NUM_RX_CHAINS_5GHZ 117
EOF

    green "已补齐Android 17 Wi-Fi NSS/chain vendor命令" \
          "Installed Android 17 Wi-Fi NSS/chain vendor commands"
}

dedupe_selinux_context_file() {
    local file="$1"
    local temp
    temp=$(mktemp "${work_dir}/tmp/context.XXXXXX")

    awk '
        /^[[:space:]]*(#|$)/ { print; next }
        !seen[$1]++ { print }
    ' "$file" > "$temp"

    if cmp -s "$file" "$temp"; then
        rm -f "$temp"
        return 0
    fi

    local before after
    before=$(awk '!/^[[:space:]]*(#|$)/ { count++ } END { print count + 0 }' "$file")
    after=$(awk '!/^[[:space:]]*(#|$)/ { count++ } END { print count + 0 }' "$temp")
    cat "$temp" > "$file"
    rm -f "$temp"
    yellow "$(basename "$file"): 删除 $((before - after)) 个重复上下文" \
           "$(basename "$file"): removed $((before - after)) duplicate contexts"
}

dedupe_selinux_contexts() {
    local file
    while IFS= read -r -d '' file; do
        dedupe_selinux_context_file "$file" || return 1
    done < <(
        find build/portrom/images -type f \
            \( -name '*_service_contexts' -o \
               -name '*_hwservice_contexts' -o \
               -name '*_property_contexts' \) -print0
    )
}

dex_archive_total_bytes() {
    local archive="$1"
    unzip -l "$archive" 2>/dev/null |
        awk '$4 ~ /(^|\/)classes([0-9]+)?\.dex$/ { total += $1 }
             END { print total + 0 }'
}

validate_dex_archive() {
    local archive="$1"
    local reference="${2:-}"
    local minimum_bytes="${3:-1024}"

    local dex_tool="${work_dir:-}"
    if [[ -n "$dex_tool" ]]; then
        dex_tool="${dex_tool}/bin/dex_archive.py"
    else
        dex_tool=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
        dex_tool="${dex_tool}/bin/dex_archive.py"
    fi

    if [[ ! -f "$archive" ]] ||
       ! python3 "$dex_tool" validate "$archive" >/dev/null 2>&1; then
        error "DEX archive 无效: ${archive}" "Invalid DEX archive: ${archive}"
        return 1
    fi

    local archive_bytes reference_bytes
    archive_bytes=$(dex_archive_total_bytes "$archive")
    if [[ "$archive_bytes" -lt "$minimum_bytes" ]]; then
        error "DEX 内容异常小: ${archive} (${archive_bytes} bytes)" \
              "DEX payload is unexpectedly small: ${archive} (${archive_bytes} bytes)"
        return 1
    fi

    if [[ -n "$reference" ]]; then
        reference_bytes=$(dex_archive_total_bytes "$reference")
        if [[ "$reference_bytes" -le 0 || $((archive_bytes * 2)) -lt "$reference_bytes" ]]; then
            error "补丁 DEX 相对原文件异常缩小: ${archive}" \
                  "Patched DEX shrank unexpectedly relative to its source: ${archive}"
            return 1
        fi
    fi

    return 0
}

dex_patch_cache_path() {
    local directory="$1" source="$2" source_hash
    source_hash=$(sha256sum "$source") || return 1
    # Build names alone can reuse patches from a different donor revision.
    printf '%s/%s-%s.jar\n' "$directory" "$(basename "$source" .jar)" "${source_hash%% *}"
}

install_cached_dex_patch() {
    local cache="$1"
    local target="$2"
    [[ -f "$cache" ]] || return 1

    if validate_dex_archive "$cache" "$target" 1048576; then
        cp -f "$cache" "$target"
        return 0
    fi

    local rejected="${cache}.invalid"
    local suffix=0
    while [[ -e "$rejected" ]]; do
        suffix=$((suffix + 1))
        rejected="${cache}.invalid.${suffix}"
    done
    mv -f "$cache" "$rejected"
    yellow "拒绝损坏的补丁 cache: ${cache}" \
           "Rejected corrupt patched-artifact cache: ${cache}"
    return 1
}

validate_critical_port_artifacts() {
    local failed=0
    local mediaserver="build/portrom/images/system/system/bin/mediaserver"
    local codec2_rc="build/portrom/images/vendor/etc/init/vendor.qti.media.c2@1.0-service.rc"

    local framework_jar services_jar oplus_services_jar critical_jar
    framework_jar="build/portrom/images/system/system/framework/framework.jar"
    services_jar="build/portrom/images/system/system/framework/services.jar"
    oplus_services_jar=$(find build/portrom/images -type f -name oplus-services.jar -print -quit)
    for critical_jar in "$framework_jar" "$services_jar" "$oplus_services_jar"; do
        if [[ -z "$critical_jar" ]] ||
           ! validate_dex_archive "$critical_jar" "" 1048576; then
            failed=1
        fi
    done

    local systemui
    systemui=$(find build/portrom/images -type f -name SystemUI.apk -print -quit)
    if [[ -z "$systemui" ]]; then
        error "关键 APK 缺失: SystemUI.apk" "Missing critical APK: SystemUI.apk"
        failed=1
    elif ! apksigner verify "$systemui" >/dev/null 2>&1; then
        error "关键 APK 签名无效: SystemUI.apk" \
              "Invalid critical APK signature: SystemUI.apk"
        failed=1
    elif [[ -e "${systemui}.idsig" ]]; then
        error "SystemUI 不应包含 APK v4 idsig sidecar" \
              "SystemUI must not include an APK v4 idsig sidecar"
        failed=1
    fi

    local aod
    aod=$(find build/portrom/images -type f -name Aod.apk -print -quit)
    if [[ -z "$aod" ]]; then
        error "关键 APK 缺失: Aod.apk" "Missing critical APK: Aod.apk"
        failed=1
    elif ! apksigner verify "$aod" >/dev/null 2>&1; then
        error "关键 APK 签名无效: Aod.apk" \
              "Invalid critical APK signature: Aod.apk"
        failed=1
    elif [[ -e "${aod}.idsig" ]]; then
        error "Aod.apk 不应包含 APK v4 idsig sidecar" \
              "Aod.apk must not include an APK v4 idsig sidecar"
        failed=1
    fi

    if [[ "${base_device_family:-}" == "OPSM8350" ]]; then
        local composer aod_fix expected_composer_hash actual_composer_hash
        composer="build/portrom/images/vendor/bin/hw/vendor.qti.hardware.display.composer-service"
        aod_fix="devices/common/aod_fix_sm8350.zip"
        if [[ ! -f "$composer" || ! -f "$aod_fix" ]]; then
            error "SM8350 AOD composer 修复缺失" \
                  "SM8350 AOD composer fix is missing"
            failed=1
        else
            expected_composer_hash=$(unzip -p "$aod_fix" \
                vendor/bin/hw/vendor.qti.hardware.display.composer-service |
                sha256sum | awk '{print $1}')
            actual_composer_hash=$(sha256sum "$composer" | awk '{print $1}')
            if [[ -z "$expected_composer_hash" || \
                  "$actual_composer_hash" != "$expected_composer_hash" ]]; then
                error "SM8350 AOD composer 修复未应用" \
                      "SM8350 AOD composer fix was not applied"
                failed=1
            fi
        fi
    fi

    # OplusLauncher needs CustCore's AppFeature provider for Seedling/Fluid
    # Cloud card pinning. A manifest edit inside the module invalidates both
    # the inner APK and outer OPEX signatures and makes the package disappear.
    if type validate_custcore_opex_signatures &>/dev/null &&
       ! validate_custcore_opex_signatures; then
        failed=1
    fi

    if [[ -f "$mediaserver" ]] &&
       readelf -d "$mediaserver" 2>/dev/null |
           grep -qF '[liboplusbindermonitor.so]'; then
        local libdir
        case "$(elf_class "$mediaserver")" in
            ELF32) libdir="lib" ;;
            ELF64) libdir="lib64" ;;
            *) libdir="" ;;
        esac
        if [[ -z "$libdir" ||
              ! -f "build/portrom/images/system/system/${libdir}/liboplusbindermonitor.so" ]]; then
            error "mediaserver 依赖未满足: liboplusbindermonitor.so" \
                  "Unresolved mediaserver dependency: liboplusbindermonitor.so"
            failed=1
        fi
    fi

    local libdir
    for libdir in lib lib64; do
        if [[ -f "build/portrom/images/system/system/${libdir}/libgui.so" ]] &&
           grep -aF 'libguiextimpl.so' \
               "build/portrom/images/system/system/${libdir}/libgui.so" >/dev/null &&
           [[ ! -f "build/portrom/images/system/system/${libdir}/libguiextimpl.so" ]]; then
            error "libgui 的扩展库缺失 (${libdir}/libguiextimpl.so)" \
                  "libgui extension is missing (${libdir}/libguiextimpl.so)"
            failed=1
        fi
    done

    if [[ -f "$codec2_rc" ]]; then
        for required in \
            'interface android.hardware.media.c2@1.0::IComponentStore default' \
            'disabled' \
            'oneshot'; do
            if ! grep -qE "^[[:space:]]+${required}([[:space:]]|$)" "$codec2_rc"; then
                error "Codec2 init rc 缺少: ${required}" \
                      "Codec2 init rc is missing: ${required}"
                failed=1
            fi
        done
    fi

    if [[ ${port_android_version:-0} -ge 17 ]];then
        local nfc_apk wificond_rc oiface qape_lib snapdragon_v1_lib
        local se_omapi_vintf
        local qcc_rc qcc_protobuf
        nfc_apk="build/portrom/images/system/system/priv-app/NfcNci/NfcNci.apk"
        wificond_rc="build/portrom/images/system/system/etc/init/wificond.rc"
        oiface="build/portrom/images/system_ext/bin/oiface"
        qape_lib="build/portrom/images/system_ext/lib64/vendor.qti.snapdragonServices.qape-V1-ndk.so"
        snapdragon_v1_lib="build/portrom/images/system_ext/lib64/vendor.qti.snapdragonServices-V1-ndk.so"
        qcc_rc="build/portrom/images/system_ext/etc/init/vendor.qti.hardware.qccsyshal@1.2-service.rc"
        qcc_protobuf="build/portrom/images/system_ext/lib64/libprotobuf-cpp-full-5.26.1.so"
        se_omapi_vintf="build/portrom/images/odm/etc/vintf/manifest/secure_element_omapi_service.xml"

        if [[ ! -f "$nfc_apk" ]] ||
           ! apksigner verify "$nfc_apk" >/dev/null 2>&1;then
            error "Android 17 NFC APK缺失或签名无效" \
                  "Android 17 NFC APK is missing or has an invalid signature"
            failed=1
        fi
        if [[ ! -f "$wificond_rc" ]] ||
           ! grep -Fqx 'service wificond /system/bin/wificond' "$wificond_rc";then
            error "Android 17缺少wificond init服务" \
                  "Android 17 wificond init service is missing"
            failed=1
        fi
        if [[ ! -s "$se_omapi_vintf" ]] ||
           ! xmlstarlet val "$se_omapi_vintf" >/dev/null 2>&1 ||
           [[ "$(xmlstarlet sel -t -v 'count(/manifest[@type="device"]/hal[@format="aidl"][name="android.se.omapi" and version="1"]/interface[name="ISecureElementService" and instance="default"])' "$se_omapi_vintf" 2>/dev/null)" != "1" ]];then
            error "Android 17 Secure Element OMAPI VINTF声明缺失或无效" \
                  "Android 17 Secure Element OMAPI VINTF declaration is missing or invalid"
            failed=1
        fi
        if [[ -x "$oiface" ]] &&
           readelf -d "$oiface" 2>/dev/null |
               grep -qF '[vendor.qti.snapdragonServices.qape-V1-ndk.so]' &&
           { [[ ! -f "$qape_lib" ]] || [[ ! -f "$snapdragon_v1_lib" ]]; };then
            error "Android 17 OIface Qualcomm AIDL依赖缺失" \
                  "Android 17 OIface Qualcomm AIDL dependencies are missing"
            failed=1
        fi
        if [[ -f "$qcc_rc" && ! -f "$qcc_protobuf" ]] &&
           ! sed -n '/^service qccsyshal@1\.2-service /,/^[^[:space:]]/p' \
               "$qcc_rc" | grep -Eq '^[[:space:]]+disabled[[:space:]]*$';then
            error "缺少protobuf 5.26.1的QCC HIDL服务仍被启用" \
                  "QCC HIDL remains enabled without protobuf 5.26.1"
            failed=1
        fi

        local wifi_service vendor_cmd name id name_count exact_count
        wifi_service="build/portrom/images/odm/bin/hw/vendor.oplus.hardware.wifi-aidl-service"
        vendor_cmd="build/portrom/images/vendor/etc/wifi/vendor_cmd.xml"
        if [[ -f "$wifi_service" ]] &&
           strings "$wifi_service" 2>/dev/null |
               grep -qF '/vendor/bin/vendor_cmd_tool';then
            while read -r name id;do
                name_count=$(xmlstarlet sel -t -v \
                    "count(/WCN_VenTool/VendorCmd[@name='SET_WIFI_CONFIG']/Attribute[@name='${name}'])" \
                    "$vendor_cmd" 2>/dev/null) || name_count=0
                exact_count=$(xmlstarlet sel -t -v \
                    "count(/WCN_VenTool/VendorCmd[@name='SET_WIFI_CONFIG']/Attribute[@name='${name}' and @ID='${id}' and @TYPE='u8'])" \
                    "$vendor_cmd" 2>/dev/null) || exact_count=0
                if [[ ! -s "$vendor_cmd" || "$name_count" != 1 || "$exact_count" != 1 ]];then
                    error "Android 17 Wi-Fi vendor命令缺失: ${name}" \
                          "Android 17 Wi-Fi vendor command is missing: ${name}"
                    failed=1
                fi
            done <<'EOF'
CONFIG_TX_NSS_2GHZ 110
CONFIG_RX_NSS_2GHZ 111
CONFIG_TX_NSS_5GHZ 112
CONFIG_RX_NSS_5GHZ 113
CONFIG_NUM_TX_CHAINS_2GHZ 114
CONFIG_NUM_RX_CHAINS_2GHZ 115
CONFIG_NUM_TX_CHAINS_5GHZ 116
CONFIG_NUM_RX_CHAINS_5GHZ 117
EOF
        fi
    fi

    local xml
    for xml in \
        build/portrom/images/my_product/etc/permissions/oplus.product.display_features.xml \
        build/portrom/images/my_product/etc/extension/com.oplus.app-features.xml \
        build/portrom/images/my_product/etc/extension/com.oplus.oplus-feature.xml; do
        if [[ ! -s "$xml" ]] || ! xmlstarlet val "$xml" >/dev/null 2>&1; then
            error "关键 feature XML 无效: ${xml}" "Invalid critical feature XML: ${xml}"
            failed=1
        fi
    done

    local duplicates
    duplicates=$(
        find build/portrom/images -type f \
            \( -name '*_service_contexts' -o \
               -name '*_hwservice_contexts' -o \
               -name '*_property_contexts' \) -print0 |
            xargs -0 -r awk '
                FNR == 1 { delete seen }
                /^[[:space:]]*(#|$)/ { next }
                seen[$1]++ { duplicates++ }
                END { print duplicates + 0 }
            '
    )
    if [[ "${duplicates:-0}" -ne 0 ]]; then
        error "SELinux context 中仍有 ${duplicates} 个重复键" \
              "${duplicates} duplicate SELinux context keys remain"
        failed=1
    fi

    [[ "$failed" -eq 0 ]]
}

discard_extracted_partition() {
    local partition="$1"
    rm -rf "build/portrom/images/${partition}"
    rm -f \
        "build/portrom/images/config/${partition}_file_contexts" \
        "build/portrom/images/config/${partition}_fs_config"
}

select_device_partition_stack() {
    port_device_stack_compatible=false

    local port_vendor_img="build/portrom/images/vendor.img"
    local port_odm_img="build/portrom/images/odm.img"
    [[ -f "$port_vendor_img" && -f "$port_odm_img" ]] || {
        yellow "移植包未包含 vendor/odm，继续使用底包设备分区" \
               "PORTROM has no vendor/odm pair; keeping the base device stack"
        return 0
    }

    extract_partition "$port_vendor_img" "build/portrom/images" || return 1
    extract_partition "$port_odm_img" "build/portrom/images" || return 1

    local base_family port_family port_platform base_device port_device
    base_family=$(
        grep -Rhs -m1 '^ro.build.device_family=' \
            build/baserom/images/my_product \
            build/baserom/images/my_manifest 2>/dev/null |
            cut -d= -f2- |
            head -n1
    )
    port_family=$(
        grep -Rhs -m1 '^ro.build.device_family=' \
            build/portrom/images/odm \
            build/portrom/images/vendor 2>/dev/null |
            cut -d= -f2- |
            head -n1
    )
    port_platform=$(
        grep -Rhs -m1 '^ro.board.platform=' \
            build/portrom/images/vendor \
            build/portrom/images/odm 2>/dev/null |
            cut -d= -f2- |
            head -n1
    )
    base_device=$(
        grep -h -m1 '^ro.product.device=' \
            build/baserom/images/my_manifest/build.prop 2>/dev/null |
            cut -d= -f2-
    )
    port_device=$(
        grep -h -m1 '^ro.product.device=' \
            build/portrom/images/my_manifest/build.prop 2>/dev/null |
            cut -d= -f2-
    )

    if [[ -n "$base_family" &&
          "$base_family" == "$port_family" &&
          ( -z "$base_device" || -z "$port_device" || "$base_device" == "$port_device" ) ]]; then
        port_device_stack_compatible=true
        # Kernel module partitions are tied to the boot kernel ABI. Preserve
        # them from the base independently of the matched vendor/odm stack.
        for dlkm in vendor_dlkm system_dlkm system_dlkm_oki; do
            discard_extracted_partition "$dlkm"
            rm -f "build/portrom/images/${dlkm}.img"
        done
        green "移植包设备分区匹配: ${port_device:-unknown}/${port_family} (${port_platform:-unknown})" \
              "PORTROM device stack matches: ${port_device:-unknown}/${port_family} (${port_platform:-unknown})"
        return 0
    fi

    yellow "移植包设备分区不匹配 (base=${base_device:-unknown}/${base_family:-unknown}, port=${port_device:-unknown}/${port_family:-unknown})" \
           "PORTROM device stack mismatch (base=${base_device:-unknown}/${base_family:-unknown}, port=${port_device:-unknown}/${port_family:-unknown})"
    discard_extracted_partition vendor
    discard_extracted_partition odm
    return 0
}

prepare_patch_cache() {
    local cache_root="$1"
    local patch_dir="${cache_root}/patched"
    local revision_file="${patch_dir}/.patchset"
    local revision

    revision=$(
        sha256sum \
            port.sh \
            functions.sh \
            bin/apktool/APKEditor.jar \
            bin/dex_archive.py \
            bin/patchmethod.py \
            bin/patchmethod_v2.py \
            bin/clear_testonly.py \
            devices/common/0001-core-framework-Introduce-OplusPropsHookUtils-V6.patch \
            lib/compat_fixes.sh \
            lib/opex_patch.sh \
            lib/selinux_merge.sh |
            sha256sum |
            awk '{print $1}'
    )

    if [[ -d "$patch_dir" ]] &&
       [[ ! -f "$revision_file" || "$(<"$revision_file")" != "$revision" ]]; then
        yellow "补丁逻辑已变化，清除旧 APK/JAR cache" \
               "Patch logic changed; invalidating cached APK/JAR artifacts"
        rm -rf "$patch_dir"
    fi

    mkdir -p "$patch_dir"
    printf '%s\n' "$revision" > "$revision_file"
}
