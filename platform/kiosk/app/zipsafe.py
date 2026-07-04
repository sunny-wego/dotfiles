"""Safe ZIP extraction — cheap hygiene the README insists we keep.

Guards against the classic malicious-archive tricks that turn "unzip an upload"
into host compromise or a disk-fill DoS:

  * zip-slip     — entry names that escape the target dir (../, absolute paths)
  * symlinks     — entries that would plant a symlink pointing outside the tree
  * zip-bomb     — total uncompressed size / entry count blow-ups
"""

from __future__ import annotations

import os
import zipfile
from pathlib import Path


class UnsafeArchive(Exception):
    """Raised when an archive violates an extraction guard."""


MAX_ENTRIES = 20_000

_S_IFDIR = 0o040000
_S_IFREG = 0o100000
_S_IFLNK = 0o120000


def safe_extract(zip_path: str, dest_dir: str, max_total_bytes: int) -> None:
    dest = Path(dest_dir).resolve()
    dest.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path) as zf:
        infos = zf.infolist()
        if len(infos) > MAX_ENTRIES:
            raise UnsafeArchive(f"too many entries ({len(infos)} > {MAX_ENTRIES})")

        total = sum(i.file_size for i in infos)
        if total > max_total_bytes:
            raise UnsafeArchive(
                f"uncompressed size {total} exceeds limit {max_total_bytes}"
            )

        for info in infos:
            name = info.filename
            if name.startswith("/") or os.path.isabs(name):
                raise UnsafeArchive(f"absolute path in archive: {name!r}")

            target = (dest / name).resolve()
            if not _within(dest, target):
                raise UnsafeArchive(f"path escapes extraction dir: {name!r}")

            # Reject symlinks and special files (device/fifo/socket). The type
            # is the top nibble of the unix mode. A zero nibble means the type
            # wasn't recorded (common — e.g. Python's own writestr), which we
            # treat as a plain file.
            ftype = (info.external_attr >> 16) & 0o170000
            if ftype == _S_IFLNK:
                raise UnsafeArchive(f"symlink in archive: {name!r}")
            if ftype not in (0, _S_IFDIR, _S_IFREG):
                raise UnsafeArchive(f"non-regular file in archive: {name!r}")

            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info) as src, open(target, "wb") as out:
                    out.write(src.read())


def _within(base: Path, target: Path) -> bool:
    try:
        target.relative_to(base)
        return True
    except ValueError:
        return False


def find_project_root(extract_dir: str) -> str:
    """A ZIP often wraps everything in a single top folder. Descend into it so
    detection sees the real project root, not a wrapper dir."""
    root = Path(extract_dir)
    entries = [p for p in root.iterdir() if not p.name.startswith("__MACOSX")]
    if len(entries) == 1 and entries[0].is_dir():
        return str(entries[0])
    return str(root)
