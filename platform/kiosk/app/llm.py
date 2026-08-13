"""LLM Dockerfile generation + heal — the heart of the product.

The README is emphatic: "Do not cut the heal-loop quality bar. ZIP→app success
rate is the entire value proposition." So this module is where the effort goes.

All calls go through LiteLLM (never a provider directly), and everything in a
prompt has already been secret-redacted by `redact.py`. A per-provision token
budget is enforced across every call (generation + each heal) — the
denial-of-wallet guard on the platform's own inference.

`KIOSK_LLM_MODE=stub` swaps the LLM for a deterministic template generator so the
skeleton still walks with no API key. That is a dev escape hatch, not the
product path.
"""

from __future__ import annotations

import re

import httpx

from .config import config


class TokenBudgetExceeded(Exception):
    """Raised when a provision exhausts its LLM token budget."""


class LLMError(Exception):
    pass


_SYSTEM = """\
You are the build engine of an internal app platform. You are given a redacted \
snapshot of a user's project (directory tree + key manifest files). Produce a \
SINGLE, production-quality, multi-stage Dockerfile that builds and runs this app.

Hard requirements:
- Base images MUST come only from these families: node, python, nginx, alpine, \
debian, ubuntu, gcr.io/distroless. Pin a concrete major tag (e.g. node:20-slim).
- Run as a non-root user.
- The container MUST listen on the port given as PORT (env), defaulting to the \
suggested port. Bind 0.0.0.0, not localhost.
- Install dependencies from the lockfile/manifest; do not invent dependencies.
- No secrets, no build args carrying secrets, no `COPY .env`.
- Prefer small final images (multi-stage, --production installs).
- Output ONLY the Dockerfile inside a single ```dockerfile fenced block. No prose.
"""

_HEAL_SYSTEM = """\
You are debugging a Docker build/boot that FAILED. You are given the previous \
Dockerfile and the captured error output. Return a corrected Dockerfile that \
fixes the specific failure. Keep all the hard requirements from before \
(allowlisted base image, non-root, listen on $PORT at 0.0.0.0). \
Output ONLY the corrected Dockerfile in a single ```dockerfile fenced block.\
"""

_FENCE = re.compile(r"```(?:dockerfile|Dockerfile)?\s*\n(.*?)```", re.DOTALL)


class LLMSession:
    """One provision's worth of LLM interaction, tracking a shared token budget."""

    def __init__(self) -> None:
        self.tokens_used = 0
        self.budget = config.LLM_TOKEN_BUDGET
        self.mode = config.LLM_MODE

    # ── public API ─────────────────────────────────────────────────────────
    def generate_dockerfile(self, *, detection_summary: str, tree: str,
                            manifests: dict[str, str]) -> str:
        if self.mode == "stub":
            return _stub_dockerfile(detection_summary)
        user = _build_context(detection_summary, tree, manifests)
        raw = self._chat(_SYSTEM, user)
        return _extract_dockerfile(raw)

    def heal_dockerfile(self, *, previous: str, error_log: str) -> str:
        if self.mode == "stub":
            # The stub can't reason about errors; surface that honestly.
            raise LLMError("stub mode cannot heal; set KIOSK_LLM_MODE=llm")
        user = (
            f"Previous Dockerfile:\n```dockerfile\n{previous}\n```\n\n"
            f"Build/boot error output (tail):\n```\n{error_log[-6000:]}\n```\n"
        )
        raw = self._chat(_HEAL_SYSTEM, user)
        return _extract_dockerfile(raw)

    # ── internals ────────────────────────────────────────────────────────────
    def _chat(self, system: str, user: str) -> str:
        if self.tokens_used >= self.budget:
            raise TokenBudgetExceeded(
                f"token budget {self.budget} exhausted before call"
            )
        payload = {
            "model": config.LLM_MODEL,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.1,
        }
        headers = {"Authorization": f"Bearer {config.LITELLM_MASTER_KEY}"}
        url = f"{config.LITELLM_BASE_URL}/v1/chat/completions"
        try:
            resp = httpx.post(url, json=payload, headers=headers, timeout=120)
            resp.raise_for_status()
            data = resp.json()  # a 200 with a non-JSON body must not escape as a raw decode error
        except httpx.HTTPError as e:  # noqa: BLE001
            raise LLMError(f"LiteLLM call failed: {e}") from e
        except ValueError as e:  # json.JSONDecodeError subclasses ValueError
            raise LLMError(f"LiteLLM returned a non-JSON response: {e}") from e
        usage = data.get("usage", {})
        self.tokens_used += int(usage.get("total_tokens", 0))
        if self.tokens_used > self.budget:
            raise TokenBudgetExceeded(
                f"token budget {self.budget} exceeded ({self.tokens_used} used)"
            )
        try:
            return data["choices"][0]["message"]["content"]
        except (KeyError, IndexError) as e:
            raise LLMError(f"unexpected LiteLLM response: {data}") from e


def _build_context(detection_summary: str, tree: str,
                   manifests: dict[str, str]) -> str:
    parts = [f"Detection: {detection_summary}", "", "Directory tree:", tree, ""]
    for name, body in manifests.items():
        parts += [f"--- {name} (redacted) ---", body, ""]
    parts.append(
        "Generate the Dockerfile. Honor $PORT with the suggested port as default."
    )
    return "\n".join(parts)


def _extract_dockerfile(raw: str) -> str:
    m = _FENCE.search(raw)
    content = (m.group(1) if m else raw).strip()
    if "FROM" not in content.upper():
        raise LLMError("LLM response contained no Dockerfile")
    return content + "\n"


def _stub_dockerfile(detection_summary: str) -> str:
    """Deterministic fallback for offline demos (KIOSK_LLM_MODE=stub)."""
    runtime = "python"
    port = 8000
    for tok in detection_summary.split():
        if tok.startswith("runtime="):
            runtime = tok.split("=", 1)[1]
        if tok.startswith("suggested_port="):
            try:
                port = int(tok.split("=", 1)[1])
            except ValueError:
                pass
    if runtime == "node":
        return f"""\
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev || npm install
COPY . .
RUN useradd -m app && chown -R app /app
USER app
ENV PORT={port}
EXPOSE {port}
CMD ["npm", "start"]
"""
    return f"""\
FROM python:3.12-slim
WORKDIR /app
COPY requirements*.txt ./
RUN pip install --no-cache-dir -r requirements.txt || true
COPY . .
RUN useradd -m app && chown -R app /app
USER app
ENV PORT={port}
EXPOSE {port}
CMD ["sh", "-c", "python app.py"]
"""
