"""Cron target: send the daily report to REPORT_WEBHOOK.

Never log the secret itself — a webhook URL often carries a token. Read it into
a local and log only whether it is configured.
"""
import os

webhook = os.environ.get("REPORT_WEBHOOK", "")
print("[adm-tracker] sending report:", "configured" if webhook else "<unset>")
# real impl: POST the report to `webhook` here; keep it out of logs/exceptions.
