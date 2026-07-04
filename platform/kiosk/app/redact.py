"""Secret redaction — applied to EVERYTHING before it reaches the LLM.

README §9 makes this load-bearing: the Kiosk's LLM pipeline is a governed
egress path, so a hard-coded key or a PNR sample must never leave in a prompt.
This runs before any bytes are handed to `llm.py`.

Redaction is deliberately fail-safe: high-recall patterns plus a `KEY=value`
heuristic for `.env`-style assignments. Precision loss (redacting a harmless
value) only costs the LLM a little context; a miss could ship a real secret, so
we bias hard toward over-redaction.
"""

from __future__ import annotations

import re

_PLACEHOLDER = "«REDACTED»"

# High-signal token shapes.
_PATTERNS = [
    # PEM private keys (whole block).
    re.compile(
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
        re.DOTALL,
    ),
    re.compile(r"AKIA[0-9A-Z]{16}"),                       # AWS access key id
    re.compile(r"ASIA[0-9A-Z]{16}"),                       # AWS temp key id
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),             # GitHub tokens
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),           # Slack tokens
    re.compile(r"sk-[A-Za-z0-9_-]{16,}"),                  # OpenAI/LiteLLM-style
    re.compile(r"sk-ant-[A-Za-z0-9_-]{16,}"),              # Anthropic
    re.compile(r"AIza[0-9A-Za-z_-]{35}"),                  # Google API key
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),  # JWT
    # Connection strings with inline credentials.
    re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s:@/]+:[^\s:@/]+@[^\s]+", re.IGNORECASE),
]

# `SECRET_KEY = "value"` / `password: value` style assignments in config/env.
_ASSIGN = re.compile(
    r"(?im)^(?P<key>[A-Z0-9_.-]*"
    r"(?:SECRET|TOKEN|PASSWORD|PASSWD|API[_-]?KEY|PRIVATE[_-]?KEY|"
    r"CREDENTIAL|ACCESS[_-]?KEY|CLIENT[_-]?SECRET|DSN|CONN)"
    r"[A-Z0-9_.-]*)\s*[:=]\s*(?P<q>[\"']?)(?P<val>[^\"'\r\n]+)(?P=q)"
)


def redact(text: str) -> str:
    if not text:
        return text
    for pat in _PATTERNS:
        text = pat.sub(_PLACEHOLDER, text)
    text = _ASSIGN.sub(lambda m: f"{m.group('key')}={_PLACEHOLDER}", text)
    return text
