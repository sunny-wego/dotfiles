"""Base-image allowlist — a build-time RCE / supply-chain guard (README §9).

Every generated Dockerfile's `FROM` lines must resolve to an allowlisted image
family. The LLM proposes; this deterministically enforces. A Dockerfile that
pulls `some-random/image` is rejected before it ever hits `docker build`.
"""

from __future__ import annotations

import re

# Allowed image *families*. An entry matches a repository only by EXACT equality,
# or — for entries ending in "/" — as a path-boundary namespace prefix. It is NOT
# a bare substring/startswith match: `node` allows `node` but NOT `node-pwn/x` or
# `node.evil.com/backdoor`; `gcr.io/distroless/` allows anything under it.
ALLOWED_FAMILIES = (
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

_FROM = re.compile(
    r"(?im)^\s*FROM\s+(?:--platform=\S+\s+)?(?P<img>\S+)(?:\s+AS\s+(?P<alias>\S+))?")


def _parse(dockerfile: str) -> tuple[list[str], set[str]]:
    """Return (all FROM images, set of build-stage aliases declared via `AS`)."""
    imgs: list[str] = []
    aliases: set[str] = set()
    for m in _FROM.finditer(dockerfile):
        imgs.append(m.group("img"))
        if m.group("alias"):
            aliases.add(m.group("alias").lower())
    return imgs, aliases


def _repo(image: str) -> str:
    # Strip tag/digest, keep repository path. `node:20-alpine` -> `node`.
    ref = image.split("@", 1)[0]
    if "/" in ref:
        # registry-qualified; only split the last tag colon
        head, _, tail = ref.rpartition("/")
        name = tail.split(":", 1)[0]
        return f"{head}/{name}"
    return ref.split(":", 1)[0]


def _allowed_family(repo: str) -> bool:
    return any(repo == p or (p.endswith("/") and repo.startswith(p))
               for p in ALLOWED_FAMILIES)


def validate(dockerfile: str) -> tuple[bool, str]:
    imgs, aliases = _parse(dockerfile)
    if not imgs:
        return False, "no FROM instruction found"
    for img in imgs:
        if _allowed_family(_repo(img)):
            continue
        # A bare reference to an EARLIER build stage (declared `FROM x AS name`)
        # resolves to that stage's base, which is itself validated above. Only a
        # name actually declared as a stage in THIS Dockerfile qualifies — never
        # an arbitrary bare image like `FROM redis`.
        if "/" not in img and ":" not in img and img.lower() in aliases:
            continue
        return False, f"base image not allowlisted: {img!r}"
    return True, "ok"
