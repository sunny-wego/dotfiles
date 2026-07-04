"""
Tenant-scoped cache isolation for the LiteLLM proxy.

Why this exists
---------------
LiteLLM's default cache key is a hash of the request payload (model + messages +
params). It does NOT include the calling key. So if tenant A and tenant B send
an identical prompt, B would receive A's cached completion — a cross-tenant data
leak. This hook forces the cache namespace to include the caller's tenant id, so
cache hits can only ever occur *within* a single tenant.

How it works
------------
Every virtual key is minted with metadata `{"tenant_id": "<id>"}` (see the
control-plane's provisionLlmApp.ts / mintVirtualKey). On each request we read
that id off the authenticated key and set a per-tenant cache namespace.

Verification note
-----------------
Per-request `cache.namespace` is honored by current LiteLLM proxy builds. If you
pin an older version that ignores it, the guaranteed-safe fallback is to mint
tenant keys with caching DISABLED (cache only the kiosk's own key) — see README.
Validate once against your pinned image with two tenants + one identical prompt.
"""

from litellm.integrations.custom_logger import CustomLogger


class TenantCacheIsolation(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # Metadata was attached when the virtual key was created.
        metadata = getattr(user_api_key_dict, "metadata", None) or {}
        tenant_id = metadata.get("tenant_id")

        if tenant_id:
            # Scope this request's cache reads/writes to the tenant.
            cache_control = data.get("cache") or {}
            cache_control["namespace"] = f"tenant:{tenant_id}"
            data["cache"] = cache_control
        else:
            # No tenant id (e.g. a misconfigured key) → never serve from a shared
            # cache. Disabling is strictly safer than risking a cross-tenant hit.
            data["cache"] = {"no-cache": True}

        return data


# Referenced by config.yaml -> litellm_settings.callbacks
tenant_cache_isolation = TenantCacheIsolation()
