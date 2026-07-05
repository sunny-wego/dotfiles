"""Promise: uploading a ZIP can't harm the platform.

A normal app archive extracts and its project root is found; a hostile archive
(path traversal, absolute paths, symlinks, zip bombs) is refused before any file
is written outside the sandbox.
"""
import zipfile

import pytest

from app import zipsafe

BIG = 64 * 1024 * 1024  # generous per-extract byte budget for the happy path


def _zip(path, entries):
    """entries: list of (name, bytes) or (ZipInfo, bytes)."""
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries:
            zf.writestr(name, data)


def test_a_normal_app_zip_extracts_and_its_root_is_found(tmp_path):
    src = tmp_path / "app.zip"
    _zip(src, [("myapp/package.json", b'{"name":"x"}'),
               ("myapp/server.js", b"console.log('hi')")])
    dest = tmp_path / "out"
    zipsafe.safe_extract(str(src), str(dest), BIG)

    root = zipsafe.find_project_root(str(dest))
    assert (dest / "myapp" / "package.json").exists()
    # A single wrapper folder is descended into, so detection sees the real root.
    assert root.endswith("myapp")


def test_path_traversal_is_refused(tmp_path):
    src = tmp_path / "evil.zip"
    _zip(src, [("../escape.txt", b"pwned")])
    with pytest.raises(zipsafe.UnsafeArchive):
        zipsafe.safe_extract(str(src), str(tmp_path / "out"), BIG)


def test_absolute_paths_are_refused(tmp_path):
    src = tmp_path / "abs.zip"
    _zip(src, [("/etc/cron.d/x", b"pwned")])
    with pytest.raises(zipsafe.UnsafeArchive):
        zipsafe.safe_extract(str(src), str(tmp_path / "out"), BIG)


def test_symlinks_are_refused(tmp_path):
    src = tmp_path / "link.zip"
    info = zipfile.ZipInfo("link")
    info.external_attr = (0o120777) << 16  # S_IFLNK
    with zipfile.ZipFile(src, "w") as zf:
        zf.writestr(info, "/etc/passwd")
    with pytest.raises(zipsafe.UnsafeArchive):
        zipsafe.safe_extract(str(src), str(tmp_path / "out"), BIG)


def test_a_zip_bomb_over_the_size_budget_is_refused(tmp_path):
    src = tmp_path / "bomb.zip"
    _zip(src, [("big.bin", b"\0" * (2 * 1024 * 1024))])  # 2 MB uncompressed
    with pytest.raises(zipsafe.UnsafeArchive):
        zipsafe.safe_extract(str(src), str(tmp_path / "out"), max_total_bytes=1024)
