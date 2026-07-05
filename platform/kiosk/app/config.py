"""Runtime configuration, read once from the environment."""

import os


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


class Config:
    PLATFORM_DOMAIN = os.environ.get("PLATFORM_DOMAIN", "apps.localhost")
    AUTH_MODE = os.environ.get("AUTH_MODE", "dev")
    COMPANY_EMAIL_DOMAIN = os.environ.get("COMPANY_EMAIL_DOMAIN", "wego.com")
    DEV_USER_EMAIL = os.environ.get("DEV_USER_EMAIL", "dev@wego.com")

    DATABASE_URL = os.environ.get(
        "DATABASE_URL", "postgresql://kiosk:kiosk@postgres:5432/kiosk"
    )

    LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://litellm:4000")
    LITELLM_MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "sk-kiosk-local-dev")
    LLM_MODEL = os.environ.get("KIOSK_LLM_MODEL", "dockerfile-gen")
    # "llm" (the product) or "stub" (deterministic, offline demos only).
    LLM_MODE = os.environ.get("KIOSK_LLM_MODE", "llm")

    HEAL_MAX_ITERATIONS = _int("KIOSK_HEAL_MAX_ITERATIONS", 4)
    LLM_TOKEN_BUDGET = _int("KIOSK_LLM_TOKEN_BUDGET", 120_000)

    MAX_UNZIP_MB = _int("KIOSK_MAX_UNZIP_MB", 512)
    VERIFY_TIMEOUT_S = _int("KIOSK_VERIFY_TIMEOUT_S", 40)

    # Test affordance: poison the FIRST build so the heal loop must recover on a
    # later attempt. Used to demonstrate the M1 "heal recovers ≥1 induced
    # failure" done-when deterministically. Default off.
    INDUCE_BUILD_FAILURE = os.environ.get("KIOSK_INDUCE_BUILD_FAILURE", "") == "1"

    SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")

    # ── v1: secrets, DB, egress, LLM, networks ──────────────────────────────
    # Encryption key for secrets at rest. MUST be stable across restarts, and
    # MUST NOT be the shipped default in production (enforced at startup).
    INSECURE_SECRET_KEY = "kiosk-insecure-dev-key-change-me"
    SECRET_KEY = os.environ.get("KIOSK_SECRET_KEY", "")

    # Shared postgres cluster admin URL (kiosk connects as superuser to create
    # per-tenant databases/roles). Defaults to the metadata DATABASE_URL's admin.
    PG_ADMIN_URL = os.environ.get("PG_ADMIN_URL", "") or os.environ.get(
        "DATABASE_URL", "postgresql://kiosk:kiosk@postgres:5432/kiosk"
    )
    # Host tenants use to reach the cluster (the DATABASE_URL we inject).
    PG_TENANT_HOST = os.environ.get("PG_TENANT_HOST", "postgres")
    PG_TENANT_PORT = _int("PG_TENANT_PORT", 5432)
    # Shared-cluster guards.
    TENANT_DB_CONN_LIMIT = _int("KIOSK_TENANT_DB_CONN_LIMIT", 20)
    TENANT_DB_STATEMENT_TIMEOUT = os.environ.get(
        "KIOSK_TENANT_DB_STATEMENT_TIMEOUT", "30s")
    TENANT_DB_QUOTA_MB = _int("KIOSK_TENANT_DB_QUOTA_MB", 1024)

    # Egress proxy (squid) tenants use for allowlisted outbound; empty disables.
    EGRESS_PROXY = os.environ.get("EGRESS_PROXY", "egress-proxy:3128")
    # File the kiosk regenerates with the union of app outbound allowlists.
    EGRESS_ALLOWLIST_FILE = os.environ.get(
        "EGRESS_ALLOWLIST_FILE", "/egress/allowlist.txt")

    # LiteLLM admin (per-tenant virtual keys).
    LITELLM_MAX_BUDGET = float(os.environ.get("KIOSK_LLM_TENANT_BUDGET", "5"))

    # Object storage for off-box backup copies (local MinIO / real S3).
    MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "http://minio:9000")
    MINIO_ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "")
    MINIO_SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "")
    MINIO_BUCKET = os.environ.get("MINIO_BUCKET", "platform-backups")

    REGISTRY_HOST = os.environ.get("REGISTRY_HOST", "registry:5000")

    # ── Coolify — the deploy engine (README §3) ───────────────────────────────
    # The kiosk drives Coolify through its REST API (deploy-from-image, encrypted
    # env store, cron as Scheduled Tasks, CPU/mem limits, TLS/domains, rollback);
    # operators use the Coolify dashboard as the admin plane.
    COOLIFY_BASE_URL = os.environ.get("COOLIFY_BASE_URL", "").rstrip("/")
    COOLIFY_API_TOKEN = os.environ.get("COOLIFY_API_TOKEN", "")
    # Where tenant apps are created: a project + environment + server, and a
    # Destination = the isolated tenant Docker network (README: "Destination
    # (isolated net)"). These are created once by an operator; the kiosk only
    # references their UUIDs.
    COOLIFY_PROJECT_UUID = os.environ.get("COOLIFY_PROJECT_UUID", "")
    COOLIFY_ENVIRONMENT = os.environ.get("COOLIFY_ENVIRONMENT", "production")
    # Coolify's create-from-image API requires the environment UUID (not just the
    # name); sent alongside the name when set.
    COOLIFY_ENVIRONMENT_UUID = os.environ.get("COOLIFY_ENVIRONMENT_UUID", "")
    COOLIFY_SERVER_UUID = os.environ.get("COOLIFY_SERVER_UUID", "")
    COOLIFY_DESTINATION_UUID = os.environ.get("COOLIFY_DESTINATION_UUID", "")
    # The Docker network name that the Coolify Destination is backed by. Tenant
    # app Traefik labels reference it, and the kiosk / postgres / litellm /
    # egress-proxy must be reachable on it. Defaults to the same tenant network
    # name as the plain-Docker variant so the auth chain + DB wiring are shared.
    COOLIFY_TENANT_NETWORK = os.environ.get(
        "COOLIFY_TENANT_NETWORK", os.environ.get("TENANT_NETWORK", "platform_tenant"))
    # Per-app resource ceilings Coolify enforces (README: "per-app CPU/mem
    # limits"). Empty = don't set (Coolify default / unlimited).
    COOLIFY_CPU_LIMIT = os.environ.get("COOLIFY_CPU_LIMIT", "")
    COOLIFY_MEMORY_LIMIT = os.environ.get("COOLIFY_MEMORY_LIMIT", "")
    # HTTP timeout for Coolify API calls (deploys are async; we only trigger).
    COOLIFY_TIMEOUT_S = _int("COOLIFY_TIMEOUT_S", 30)
    # How long an app may sit in "deploying" before the reconciler gives up and
    # marks it failed — so an async deploy that never reports running/failed
    # (unmapped status, Coolify unreachable) can't hang in "deploying" forever.
    DEPLOY_TIMEOUT_S = _int("KIOSK_DEPLOY_TIMEOUT_S", 900)

    # Device-authorization flow (the `kiosk login` browserless path).
    DEVICE_CODE_TTL_S = _int("KIOSK_DEVICE_CODE_TTL_S", 600)
    DEVICE_POLL_INTERVAL_S = _int("KIOSK_DEVICE_POLL_INTERVAL_S", 5)
    # Optional docker network for tenant builds (e.g. "host"). Some corporate
    # networks require builds to run on the host network to reach an egress
    # proxy / internal mirrors. Empty = docker's default build network.
    BUILD_NETWORK = os.environ.get("KIOSK_BUILD_NETWORK", "")

    WORK_DIR = os.environ.get("KIOSK_WORK_DIR", "/work")

    def app_host(self, slug: str) -> str:
        return f"{slug}.{self.PLATFORM_DOMAIN}"


config = Config()
