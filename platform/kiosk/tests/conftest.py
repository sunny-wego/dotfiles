"""Make `import app.<module>` work when pytest runs from anywhere.

These are fast, no-infrastructure tests (no Docker, no Postgres) that pin the
platform's *user-facing guarantees* — what a person uploading an app or opening
one is promised — not internal implementation details.
"""
import pathlib
import sys

# kiosk/ (parent of this tests/ dir) holds the `app` package.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
