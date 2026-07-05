"""Cron target: send the daily report to REPORT_WEBHOOK (stub prints it)."""
import os
print("[adm-tracker] sending report to", os.environ.get("REPORT_WEBHOOK", "<unset>"))
