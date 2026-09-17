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

validate_critical_port_artifacts() {
    local failed=0
    local mediaserver="build/portrom/images/system/system/bin/mediaserver"
    local codec2_rc="build/portrom/images/vendor/etc/init/vendor.qti.media.c2@1.0-service.rc"

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
    else
        local framework_res systemui_cert framework_cert
        framework_res="build/portrom/images/system/system/framework/framework-res.apk"
        systemui_cert=$(apksigner verify --print-certs "$systemui" 2>/dev/null |
            awk -F': ' '/Signer #1 certificate SHA-256 digest:/{print $2; exit}')
        framework_cert=$(apksigner verify --print-certs "$framework_res" 2>/dev/null |
            awk -F': ' '/Signer #1 certificate SHA-256 digest:/{print $2; exit}')
        if [[ -z "$framework_cert" || "$systemui_cert" != "$framework_cert" ]]; then
            error "SystemUI 与 framework-res 的签名证书不一致" \
                  "SystemUI signer does not match framework-res"
            failed=1
        fi
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
            bin/patchmethod.py \
            bin/patchmethod_v2.py \
            bin/clear_testonly.py \
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
