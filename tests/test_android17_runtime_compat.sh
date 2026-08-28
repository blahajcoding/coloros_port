#!/bin/bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d /tmp/coloros-a17-compat.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT

error() { printf '%s\n' "$2" >&2; }
green() { :; }
work_dir="$fixture"
port_android_version=17
source "${repo_dir}/lib/compat_fixes.sh"

mkdir -p \
    "$fixture/build/portrom/images/odm/bin/hw" \
    "$fixture/build/portrom/images/vendor/etc/wifi" \
    "$fixture/tmp"

# strings(1) only needs to see the helper path to exercise the same feature
# detection used for the real Oplus Wi-Fi AIDL binary.
printf '%s\n' '/vendor/bin/vendor_cmd_tool' > \
    "$fixture/build/portrom/images/odm/bin/hw/vendor.oplus.hardware.wifi-aidl-service"
cat > "$fixture/build/portrom/images/vendor/etc/wifi/vendor_cmd.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<WCN_VenTool>
    <VendorCmd name="SET_WIFI_CONFIG" ID="74">
        <Attribute name="CONFIG_NSS" ID="70" TYPE="u8"/>
    </VendorCmd>
    <!-- A definition in another command must not satisfy SET_WIFI_CONFIG. -->
    <VendorCmd name="GET_WIFI_CONFIG" ID="75">
        <Attribute name="CONFIG_TX_NSS_2GHZ" ID="110" TYPE="u8"/>
        <Attribute name="CONFIG_RX_NSS_2GHZ" ID="111" TYPE="u8"/>
        <Attribute name="CONFIG_TX_NSS_5GHZ" ID="112" TYPE="u8"/>
        <Attribute name="CONFIG_RX_NSS_5GHZ" ID="113" TYPE="u8"/>
        <Attribute name="CONFIG_NUM_TX_CHAINS_2GHZ" ID="114" TYPE="u8"/>
        <Attribute name="CONFIG_NUM_RX_CHAINS_2GHZ" ID="115" TYPE="u8"/>
        <Attribute name="CONFIG_NUM_TX_CHAINS_5GHZ" ID="116" TYPE="u8"/>
        <Attribute name="CONFIG_NUM_RX_CHAINS_5GHZ" ID="117" TYPE="u8"/>
    </VendorCmd>
</WCN_VenTool>
EOF

cd "$fixture"
apply_android17_wifi_vendor_cmd_compat
first_hash=$(sha256sum build/portrom/images/vendor/etc/wifi/vendor_cmd.xml)
apply_android17_wifi_vendor_cmd_compat
second_hash=$(sha256sum build/portrom/images/vendor/etc/wifi/vendor_cmd.xml)
[[ "$first_hash" == "$second_hash" ]]

while read -r name id;do
    [[ $(xmlstarlet sel -t -v \
        "count(/WCN_VenTool/VendorCmd[@name='SET_WIFI_CONFIG']/Attribute[@name='${name}' and @ID='${id}' and @TYPE='u8'])" \
        build/portrom/images/vendor/etc/wifi/vendor_cmd.xml) == 1 ]]
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
xmlstarlet val build/portrom/images/vendor/etc/wifi/vendor_cmd.xml >/dev/null

[[ $(xmlstarlet sel -t -v \
    'count(/manifest[@type="device"]/hal[@format="aidl"][name="android.se.omapi" and version="1"]/interface[name="ISecureElementService" and instance="default"])' \
    "${repo_dir}/devices/common/secure_element_omapi_service.xml") == 1 ]]
grep -Fqx 'verify_generated_ota=false' "${repo_dir}/bin/port_config"

printf 'Android 17 runtime compatibility tests passed\n'
