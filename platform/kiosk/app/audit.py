"""Append-only audit — actor = the Google identity, never the Coolify token.

Thin wrapper over db.insert_audit so call sites read intently. Every
state-changing action in the pipeline records here.
"""

from __future__ import annotations

from . import db


def record(actor: str, action: str, *, app: str | None = None,
           detail: dict | None = None) -> None:
    try:
        db.insert_audit(actor, action, app, detail)
    except Exception as e:  # noqa: BLE001
        # Audit must never take down the request path; log and continue.
        print(f"[audit] failed to record {action!r}: {e}", flush=True)
