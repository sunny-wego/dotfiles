# Vercel Handler

Fix Vercel deployment/build failures.

See `references/handler-contract.md` for shared rules.

## Fix

### 1. Locate the failed deployment

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/find-failed-vercel-checks.sh <PR> [<owner/repo>]
```

Returns a JSON array of `{name, state, link, completedAt}`. Empty array → no failed Vercel/Preview checks; the handler is a no-op.

Fetch build logs via Vercel MCP (preferred) or the deployment link (fallback):

- **MCP**: `mcp__plugin_vercel_vercel__list_deployments` → `get_deployment(id)` → `get_deployment_build_logs(id)`.
- **Fallback**: the `link` field opens the Vercel deployment page; ask the user to paste logs if MCP is unavailable.

### 2. Fix each error

Common categories:

- **Type errors** (`tsc` during `next build`) — fix the type.
- **Missing imports/modules** — add import or install dependency.
- **Build config** (`next.config.mjs`) — fix invalid configuration.
- **Edge-runtime incompatibilities** — move to serverless or add `export const runtime = "nodejs"`.
- **Dynamic server usage** — add `export const dynamic = "force-dynamic"` or restructure data fetching.
- **Image/font optimization** — fix `next/image` / `next/font` config.
- **CSS/Tailwind** — fix invalid utility classes or missing config.

**SKIP** infrastructure errors (deployment timeouts, function size limits, DNS/env on Vercel side) — flag in outcome.

Append outcome:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append vercel \
  '{"fixed":N,"declined":0,"skipped":N,"unresolved":[…]}'
```

## Standalone mode

`/zeus:address-pr vercel`: exit when the Vercel deployment check passes.
