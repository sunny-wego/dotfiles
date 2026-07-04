"""Thin wrapper over the docker CLI (docker-out-of-docker via mounted socket).

Kept tiny and subprocess-based so the build/deploy code reads like the commands
an operator would run by hand.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass


@dataclass
class Run:
    code: int
    out: str

    @property
    def ok(self) -> bool:
        return self.code == 0


def run(args: list[str], *, timeout: int = 900, cwd: str | None = None) -> Run:
    try:
        proc = subprocess.run(
            ["docker", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        return Run(124, f"timeout after {timeout}s\n{e.stdout or ''}{e.stderr or ''}")
    return Run(proc.returncode, (proc.stdout or "") + (proc.stderr or ""))


def build(tag: str, context: str, dockerfile: str = "Dockerfile",
          timeout: int = 1200) -> Run:
    return run(
        ["build", "--pull", "-t", tag, "-f", f"{context}/{dockerfile}", context],
        timeout=timeout,
    )


def rm_force(name: str) -> None:
    run(["rm", "-f", name], timeout=30)


def logs(name: str, tail: int = 200) -> str:
    return run(["logs", "--tail", str(tail), name], timeout=30).out
