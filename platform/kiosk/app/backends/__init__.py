"""Deploy engine — Coolify.

`coolify/` holds the engine: `client.py` (the REST wrapper) and `backend.py`
(`CoolifyBackend`, the deploy/cron/rollback/logs operations). `labels.py` builds
the auth-chain Traefik labels the deploy attaches. `deployer.py` (one level up)
is the seam the orchestrator and web layer call; it holds the single lazily-built
`CoolifyBackend`.
"""
