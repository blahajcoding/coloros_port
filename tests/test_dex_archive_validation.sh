#!/bin/bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d /tmp/coloros-dex-validation.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT

error() { :; }
yellow() { :; }
green() { :; }

source "${repo_dir}/lib/compat_fixes.sh"

python3 - "$test_dir" <<'PY'
import hashlib
import struct
import sys
import zipfile
import zlib
from pathlib import Path

root = Path(sys.argv[1])


def dex(size, version=40, *, container_size=None, header_offset=0, bad_header=False):
    header_size = 0x78 if version >= 41 else 0x70
    data = bytearray(size)
    data[:8] = f"dex\n{version:03d}\0".encode()
    struct.pack_into("<I", data, 0x20, size)
    struct.pack_into("<I", data, 0x24, 0x70 if bad_header else header_size)
    struct.pack_into("<I", data, 0x28, 0x12345678)
    if version >= 41 and not bad_header:
        struct.pack_into("<I", data, 0x70, container_size if container_size else size)
        struct.pack_into("<I", data, 0x74, header_offset)
    data[0x0C:0x20] = hashlib.sha1(data[0x20:]).digest()
    struct.pack_into("<I", data, 0x08, zlib.adler32(data[0x0C:]) & 0xFFFFFFFF)
    return bytes(data)


def archive(name, entries):
    with zipfile.ZipFile(root / f"{name}.jar", "w") as output:
        for entry, data in entries.items():
            output.writestr(entry, data, compress_type=zipfile.ZIP_STORED)


archive("source", {"classes.dex": dex(4096)})
archive("valid", {"classes.dex": dex(4080)})
archive("tiny", {"classes.dex": dex(140)})
archive("shrunken", {"classes.dex": dex(1500)})
archive("bad_magic", {"classes.dex": b"not-a-dex" + bytes(4087)})
archive("bad_041_header", {"classes.dex": dex(4096, 41, bad_header=True)})
archive(
    "container",
    {
        "classes.dex": (
            dex(2048, 41, container_size=4096, header_offset=0)
            + dex(2048, 41, container_size=4096, header_offset=2048)
        )
    },
)
archive("gap", {"classes.dex": dex(2048), "classes3.dex": dex(2048)})
PY

expect_rejected() {
    if validate_dex_archive "$@" >/dev/null 2>&1; then
        printf 'expected rejection: %s\n' "$1" >&2
        exit 1
    fi
}

validate_dex_archive "${test_dir}/valid.jar" "${test_dir}/source.jar" 1024
validate_dex_archive "${test_dir}/container.jar" "" 1024
expect_rejected "${test_dir}/tiny.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/bad_magic.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/bad_041_header.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/shrunken.jar" "${test_dir}/source.jar" 1024
expect_rejected "${test_dir}/gap.jar" "" 1024
expect_rejected "${test_dir}/missing.jar" "${test_dir}/source.jar" 1024

mapfile -t selectors < <(
    python3 "${repo_dir}/bin/dex_archive.py" selectors "${test_dir}/container.jar"
)
[[ ${#selectors[@]} -eq 2 ]]
[[ ${selectors[0]} == classes.dex ]]
[[ ${selectors[1]} == classes.dex/2 ]]
[[ $(python3 "${repo_dir}/bin/dex_archive.py" versions \
    "${test_dir}/container.jar") == 041 ]]

printf 'DEX archive validation tests passed\n'
