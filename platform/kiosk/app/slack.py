"""Slack escalation — the minimal human surface M1 requires.

On heal-loop exhaustion or an unrecoverable provision failure, the kiosk posts a
plain-English message here (never a raw stack trace to the creator) and always
mirrors the escalation into the append-only audit table, so the surface exists
even with no webhook configured.
"""

from __future__ import annotations

import httpx

from . import audit
from .config import config


def escalate(actor: str, app: str, reason: str, detail: dict | None = None) -> None:
    audit.record(actor, "escalation", app=app,
                 detail={"reason": reason, **(detail or {})})
    if not config.SLACK_WEBHOOK_URL:
        print(f"[escalation] app={app} actor={actor} reason={reason}", flush=True)
        return
    text = (
        f":rotating_light: *Kiosk escalation* — app `{app}`\n"
        f"> {reason}\n"
        f"requested by {actor}"
    )
    try:
        httpx.post(config.SLACK_WEBHOOK_URL, json={"text": text}, timeout=10)
    except httpx.HTTPError as e:  # noqa: BLE001
        print(f"[escalation] slack post failed: {e}", flush=True)
