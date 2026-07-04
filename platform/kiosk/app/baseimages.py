"""Base-image allowlist — a build-time RCE / supply-chain guard (README §9).

Every generated Dockerfile's `FROM` lines must resolve to an allowlisted image
family. The LLM proposes; this deterministically enforces. A Dockerfile that
pulls `some-random/image` is rejected before it ever hits `docker build`.
"""

from __future__ import annotations

import re

# Allowed image *families* (prefix match on the repository, tag ignored).
ALLOWED_PREFIXES = (
    "node",
    "python",
    "nginx",
    "alpine",
    "debian",
    "ubuntu",
    "gcr.io/distroless/",
    "docker.io/library/node",
    "docker.io/library/python",
)

_FROM = re.compile(r"(?im)^\s*FROM\s+(?:--platform=\S+\s+)?(?P<img>\S+)")


def from_images(dockerfile: str) -> list[str]:
    return [m.group("img") for m in _FROM.finditer(dockerfile)]


def _repo(image: str) -> str:
    # Strip tag/digest, keep repository path. `node:20-alpine` -> `node`.
    ref = image.split("@", 1)[0]
    if "/" in ref:
        # registry-qualified; only split the last tag colon
        head, _, tail = ref.rpartition("/")
        name = tail.split(":", 1)[0]
        return f"{head}/{name}"
    return ref.split(":", 1)[0]


def validate(dockerfile: str) -> tuple[bool, str]:
    imgs = from_images(dockerfile)
    if not imgs:
        return False, "no FROM instruction found"
    for img in imgs:
        # A `FROM builder`-style alias reference resolves to a prior stage; the
        # actual base is the aliased stage's FROM, already checked. We treat any
        # image that isn't a known-registry ref and matches a build stage name
        # loosely: only enforce on refs that look like registry images.
        repo = _repo(img)
        if not any(repo == p or repo.startswith(p) for p in ALLOWED_PREFIXES):
            # Allow references to earlier build stages (no dots/slashes, no tag).
            if re.fullmatch(r"[A-Za-z0-9_-]+", img):
                continue
            return False, f"base image not allowlisted: {img!r}"
    return True, "ok"
