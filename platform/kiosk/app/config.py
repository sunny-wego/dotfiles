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

    REGISTRY_HOST = os.environ.get("REGISTRY_HOST", "registry:5000")
    PROXY_NETWORK = os.environ.get("PROXY_NETWORK", "platform_proxy")

    WORK_DIR = os.environ.get("KIOSK_WORK_DIR", "/work")

    def app_host(self, slug: str) -> str:
        return f"{slug}.{self.PLATFORM_DOMAIN}"


config = Config()
