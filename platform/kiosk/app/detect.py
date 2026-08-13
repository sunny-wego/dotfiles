"""Deterministic stack detection.

The LLM *proposes* the Dockerfile; detection *anchors* it with a structural read
of the project (runtime, framework, shape, likely port). This is the
"LLM proposes, structure guarantees" principle applied at M1 scale: the summary
here is deterministic and feeds the prompt so generation isn't guessing blind.

Never modifies source — read-only inspection (README §8: "No source
modification").
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

# Key files we surface (redacted) to the LLM. Small, high-signal.
MANIFEST_FILES = [
    "package.json", "requirements.txt", "pyproject.toml", "Pipfile",
    "go.mod", "next.config.js", "next.config.mjs", "next.config.ts",
    "vite.config.js", "vite.config.ts", "server.js", "index.js", "app.py",
    "main.py", "manage.py", "streamlit_app.py", "Procfile",
]


@dataclass
class Detection:
    runtime: str = "unknown"        # node | python | unknown
    framework: str = "unknown"      # next, express, fastapi, streamlit, ...
    shape: str = "unknown"          # fullstack | backend | static | worker
    suggested_port: int = 8080
    notes: list[str] = field(default_factory=list)

    def summary(self) -> str:
        return (
            f"runtime={self.runtime} framework={self.framework} "
            f"shape={self.shape} suggested_port={self.suggested_port}"
        )


def detect(root: str) -> Detection:
    p = Path(root)
    if (p / "package.json").exists():
        return _detect_node(p)
    if any((p / f).exists() for f in ("requirements.txt", "pyproject.toml", "Pipfile")) \
            or list(p.glob("*.py")):
        return _detect_python(p)
    return Detection(notes=["no package.json or Python markers found"])


def _detect_node(p: Path) -> Detection:
    d = Detection(runtime="node", suggested_port=3000)
    try:
        pkg = json.loads((p / "package.json").read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        d.notes.append(f"package.json unreadable: {e}")
        return d
    deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
    scripts = pkg.get("scripts", {})

    if "next" in deps:
        d.framework, d.shape = "next", "fullstack"
    elif "nuxt" in deps:
        d.framework, d.shape = "nuxt", "fullstack"
    elif {"@remix-run/react", "@remix-run/node"} & set(deps):
        d.framework, d.shape = "remix", "fullstack"
    elif any(k in deps for k in ("express", "fastify", "@nestjs/core", "hono", "koa")):
        d.framework = next(k for k in ("express", "fastify", "@nestjs/core", "hono", "koa") if k in deps)
        d.shape = "backend"
    elif any(k in deps for k in ("react", "vue", "svelte", "astro")) and "start" not in scripts:
        d.framework = next(k for k in ("astro", "svelte", "vue", "react") if k in deps)
        d.shape = "static"
    elif "start" in scripts or "main" in pkg:
        d.shape = "worker" if "start" not in scripts else "backend"

    d.notes.append(f"scripts: {', '.join(sorted(scripts)) or 'none'}")
    return d


def _detect_python(p: Path) -> Detection:
    d = Detection(runtime="python", suggested_port=8000)
    blob = ""
    for f in ("requirements.txt", "pyproject.toml", "Pipfile"):
        fp = p / f
        if fp.exists():
            try:
                blob += fp.read_text(encoding="utf-8").lower()
            except Exception:  # noqa: BLE001
                pass
    names = {q.name.lower() for q in p.glob("*.py")}

    if "streamlit" in blob or "streamlit_app.py" in names:
        d.framework, d.shape, d.suggested_port = "streamlit", "fullstack", 8501
    elif "gradio" in blob:
        d.framework, d.shape, d.suggested_port = "gradio", "fullstack", 7860
    elif "dash" in blob:
        d.framework, d.shape = "dash", "fullstack"
    elif "fastapi" in blob:
        d.framework, d.shape = "fastapi", "backend"
    elif "flask" in blob:
        d.framework, d.shape = "flask", "backend"
    elif "django" in blob or "manage.py" in names:
        d.framework, d.shape = "django", "backend"
    elif names:
        d.shape = "worker"

    if not blob:
        d.notes.append("no dependency manifest; inferring from *.py")
    return d


def collect_manifests(root: str, redactor) -> dict[str, str]:
    """Return {relpath: redacted_contents} for the small set of key files."""
    p = Path(root)
    out: dict[str, str] = {}
    for name in MANIFEST_FILES:
        fp = p / name
        if fp.exists() and fp.is_file():
            try:
                text = fp.read_text(encoding="utf-8", errors="replace")
            except Exception:  # noqa: BLE001
                continue
            out[name] = redactor(text[:8000])
    return out


def tree(root: str, max_entries: int = 120) -> str:
    """A compact, redaction-free (paths only) directory listing for the prompt."""
    p = Path(root)
    lines: list[str] = []
    skip = {"node_modules", ".git", ".next", "dist", "build", "__pycache__", ".venv"}
    for path in sorted(p.rglob("*")):
        rel = path.relative_to(p)
        if any(part in skip for part in rel.parts):
            continue
        lines.append(str(rel) + ("/" if path.is_dir() else ""))
        if len(lines) >= max_entries:
            lines.append("… (truncated)")
            break
    return "\n".join(lines)
