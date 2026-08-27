#!/usr/bin/env python3
"""Inspect and rebuild ZIP/JAR archives containing DEX files.

Android 16 introduced DEX version 041 containers.  A single physical
``classes.dex`` ZIP entry can contain several logical DEX files.  Treating
that entry as an ordinary single DEX silently drops every logical file after
the first one when it is passed through tools without container support.

This utility deliberately does not split a 041 container byte-for-byte:
offsets in every logical DEX are relative to the start of the whole physical
container.  Instead, callers can use ``selectors`` with a container-aware
baksmali and then use ``repack`` to put independently assembled DEX files back
into the archive as conventional classes.dex/classes2.dex/... entries.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import struct
import sys
import tempfile
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path


DEX_ENTRY_RE = re.compile(r"^classes(?:(\d+))?\.dex$")
DEX_MAGIC_RE = re.compile(br"^dex\n(\d{3})\x00$")
DEX_HEADER_SIZE = 0x70
DEX_CONTAINER_HEADER_SIZE = 0x78
DEX_ENDIAN_CONSTANT = 0x12345678


class DexArchiveError(ValueError):
    pass


@dataclass(frozen=True)
class LogicalDex:
    entry: str
    logical_index: int
    offset: int
    file_size: int
    version: int

    @property
    def selector(self) -> str:
        if self.logical_index == 1:
            return self.entry
        return f"{self.entry}/{self.logical_index}"


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _physical_dex_entries(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    entries: list[tuple[int, zipfile.ZipInfo]] = []
    for info in archive.infolist():
        match = DEX_ENTRY_RE.fullmatch(info.filename)
        if match:
            index = int(match.group(1) or "1")
            entries.append((index, info))
    entries.sort(key=lambda item: item[0])
    if not entries:
        raise DexArchiveError("archive has no root classes*.dex entries")
    actual = [index for index, _ in entries]
    expected = list(range(1, len(entries) + 1))
    if actual != expected:
        raise DexArchiveError(
            f"physical DEX entries are not consecutive: {actual} (expected {expected})"
        )
    return [info for _, info in entries]


def _inspect_blob(entry: str, data: bytes, verify_checksums: bool = True) -> list[LogicalDex]:
    result: list[LogicalDex] = []
    offset = 0
    logical_index = 1

    while offset < len(data):
        remaining = len(data) - offset
        if remaining < DEX_HEADER_SIZE:
            raise DexArchiveError(f"{entry}: truncated DEX header at {offset:#x}")
        magic = data[offset : offset + 8]
        match = DEX_MAGIC_RE.fullmatch(magic)
        if not match:
            raise DexArchiveError(f"{entry}: invalid DEX magic at {offset:#x}")
        version = int(match.group(1))
        if not 35 <= version <= 42:
            raise DexArchiveError(f"{entry}: unsupported DEX version {version:03d}")

        file_size = _u32(data, offset + 0x20)
        header_size = _u32(data, offset + 0x24)
        endian_tag = _u32(data, offset + 0x28)
        expected_header = DEX_CONTAINER_HEADER_SIZE if version >= 41 else DEX_HEADER_SIZE
        if header_size != expected_header:
            raise DexArchiveError(
                f"{entry}: DEX {version:03d} at {offset:#x} has header_size "
                f"{header_size:#x}, expected {expected_header:#x}"
            )
        if endian_tag != DEX_ENDIAN_CONSTANT:
            raise DexArchiveError(f"{entry}: unsupported endian tag {endian_tag:#x}")
        if file_size < header_size or offset + file_size > len(data):
            raise DexArchiveError(
                f"{entry}: invalid file_size {file_size} at {offset:#x} "
                f"for {len(data)}-byte entry"
            )

        if version >= 41:
            container_size = _u32(data, offset + 0x70)
            header_offset = _u32(data, offset + 0x74)
            if container_size != len(data):
                raise DexArchiveError(
                    f"{entry}: container_size {container_size} != entry size {len(data)}"
                )
            if header_offset != offset:
                raise DexArchiveError(
                    f"{entry}: header_offset {header_offset:#x} != actual {offset:#x}"
                )
            if _u32(data, offset + 0x68) != 0 or _u32(data, offset + 0x6C) != 0:
                raise DexArchiveError(f"{entry}: DEX 041 data_size/data_off must be zero")
        elif offset != 0 or file_size != len(data):
            raise DexArchiveError(
                f"{entry}: DEX {version:03d} cannot contain concatenated logical DEX files"
            )

        if verify_checksums:
            logical = data[offset : offset + file_size]
            stored_signature = logical[0x0C:0x20]
            calculated_signature = hashlib.sha1(logical[0x20:]).digest()
            if stored_signature != calculated_signature:
                raise DexArchiveError(
                    f"{entry}: SHA-1 signature mismatch in logical DEX {logical_index}"
                )
            stored_checksum = _u32(logical, 0x08)
            calculated_checksum = zlib.adler32(logical[0x0C:]) & 0xFFFFFFFF
            if stored_checksum != calculated_checksum:
                raise DexArchiveError(
                    f"{entry}: Adler-32 mismatch in logical DEX {logical_index}"
                )

        result.append(LogicalDex(entry, logical_index, offset, file_size, version))
        offset += file_size
        logical_index += 1
        if version < 41:
            break

    if offset != len(data):
        raise DexArchiveError(f"{entry}: {len(data) - offset} trailing bytes after DEX data")
    return result


def inspect_archive(path: Path, verify_checksums: bool = True) -> tuple[list[LogicalDex], int]:
    try:
        with zipfile.ZipFile(path) as archive:
            bad_entry = archive.testzip()
            if bad_entry is not None:
                raise DexArchiveError(f"ZIP CRC mismatch: {bad_entry}")
            physical = _physical_dex_entries(archive)
            logical: list[LogicalDex] = []
            dex_bytes = 0
            for info in physical:
                data = archive.read(info)
                dex_bytes += len(data)
                logical.extend(_inspect_blob(info.filename, data, verify_checksums))
            return logical, dex_bytes
    except (OSError, zipfile.BadZipFile) as exc:
        raise DexArchiveError(f"invalid ZIP archive: {exc}") from exc


def command_validate(args: argparse.Namespace) -> None:
    logical, dex_bytes = inspect_archive(args.archive)
    physical_count = len({item.entry for item in logical})
    print(
        f"logical_dexes={len(logical)} physical_dexes={physical_count} "
        f"dex_bytes={dex_bytes}"
    )


def command_selectors(args: argparse.Namespace) -> None:
    logical, _ = inspect_archive(args.archive)
    for item in logical:
        print(item.selector)


def command_count(args: argparse.Namespace) -> None:
    logical, _ = inspect_archive(args.archive)
    print(len(logical))


def command_versions(args: argparse.Namespace) -> None:
    logical, _ = inspect_archive(args.archive)
    for version in sorted({item.version for item in logical}):
        print(f"{version:03d}")


def command_repack(args: argparse.Namespace) -> None:
    if not args.dex:
        raise DexArchiveError("at least one rebuilt DEX file is required")
    dex_data: list[bytes] = []
    for index, path in enumerate(args.dex, start=1):
        data = path.read_bytes()
        name = "classes.dex" if index == 1 else f"classes{index}.dex"
        logical = _inspect_blob(name, data)
        if len(logical) != 1:
            raise DexArchiveError(f"rebuilt {path} must contain exactly one logical DEX")
        dex_data.append(data)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=f".{args.output.name}.", suffix=".tmp", dir=args.output.parent, delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with zipfile.ZipFile(args.reference) as source, zipfile.ZipFile(
            temporary_path, "w", allowZip64=True
        ) as destination:
            original_dex_info = next(
                (info for info in source.infolist() if info.filename == "classes.dex"), None
            )
            for info in source.infolist():
                if DEX_ENTRY_RE.fullmatch(info.filename):
                    continue
                destination.writestr(info, source.read(info))

            for index, data in enumerate(dex_data, start=1):
                name = "classes.dex" if index == 1 else f"classes{index}.dex"
                info = zipfile.ZipInfo(name)
                if original_dex_info is not None:
                    info.date_time = original_dex_info.date_time
                    info.external_attr = original_dex_info.external_attr
                    info.create_system = original_dex_info.create_system
                info.compress_type = zipfile.ZIP_STORED
                destination.writestr(info, data)
        temporary_path.replace(args.output)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise

    inspect_archive(args.output)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="validate ZIP and DEX container headers")
    validate.add_argument("archive", type=Path)
    validate.set_defaults(func=command_validate)

    selectors = subparsers.add_parser(
        "selectors", help="print baksmali selectors for every logical DEX"
    )
    selectors.add_argument("archive", type=Path)
    selectors.set_defaults(func=command_selectors)

    count = subparsers.add_parser("count", help="print the logical DEX count")
    count.add_argument("archive", type=Path)
    count.set_defaults(func=command_count)

    versions = subparsers.add_parser("versions", help="print logical DEX format versions")
    versions.add_argument("archive", type=Path)
    versions.set_defaults(func=command_versions)

    repack = subparsers.add_parser(
        "repack", help="copy non-DEX ZIP entries and install rebuilt conventional multidex"
    )
    repack.add_argument("reference", type=Path)
    repack.add_argument("output", type=Path)
    repack.add_argument("dex", type=Path, nargs="+")
    repack.set_defaults(func=command_repack)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except (DexArchiveError, OSError, zipfile.BadZipFile) as exc:
        print(f"dex_archive.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
