/**
 * provisionLlmApp.ts
 * -----------------------------------------------------------------------------
 * Control-plane routine that makes a dropped ZIP "just work" as an LLM app,
 * without the (non-technical) creator ever handling an API key.
 *
 * On provision it:
 *   1. detectLlmApp()      — scans the bundle; is this app calling an LLM?
 *   2. mintVirtualKey()    — asks LiteLLM for a per-tenant key (budget + limits
 *                            + model allowlist), tagged with { tenant_id }.
 *   3. buildLlmEnv()       — the env vars injected into the tenant container so
 *                            its OpenAI/Anthropic SDK transparently routes through
 *                            the governed LiteLLM gateway.
 *   4. sanitizeHardcodedKeys() — flags/strips keys the creator hard-coded, so no
 *                            tenant ever ships a real upstream key.
 *
 * The master OpenRouter key never leaves the LiteLLM container. Tenants only ever
 * see a scoped virtual key pointing at the internal gateway.
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type Tier = "free" | "standard" | "premium";

export interface BundleFile {
  path: string; // repo-relative, e.g. "requirements.txt" | "src/chat.py"
  text: string; // file contents (text files only)
}

export interface LlmDetection {
  isLlmApp: boolean;
  /** SDKs/frameworks found, e.g. ["openai", "langchain"] */
  signals: string[];
  /** Files that hard-code a key or a direct provider base URL — must be fixed. */
  leaks: Array<{ path: string; kind: "hardcoded-key" | "direct-base-url" }>;
}

export interface VirtualKey {
  key: string; // sk-... (LiteLLM virtual key)
  keyName: string;
}

// ---------------------------------------------------------------------------
// 1. Detection — reuse the analysis already done for Dockerfile generation.
// ---------------------------------------------------------------------------

// Package/import fingerprints across Node and Python LLM ecosystems.
const SDK_SIGNATURES: Record<string, RegExp[]> = {
  openai: [/\bopenai\b/i],
  anthropic: [/\banthropic\b/i],
  langchain: [/\blangchain(_\w+)?\b/i],
  llamaindex: [/\bllama[-_]?index\b/i],
  litellm: [/\blitellm\b/i],
  google: [/google[-_.]generativeai|@google\/generative-ai/i],
  cohere: [/\bcohere\b/i],
  mistral: [/\bmistralai\b/i],
};

// Manifests worth scanning for dependency signals.
const MANIFESTS = /(^|\/)(package\.json|requirements\.txt|pyproject\.toml|Pipfile)$/;

// Hard-coded secret / direct-provider patterns we must not let ship.
const HARDCODED_KEY = /\b(sk-[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9-]{20,})\b/;
const DIRECT_BASE_URL =
  /https?:\/\/(api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com)/i;

export function detectLlmApp(files: BundleFile[]): LlmDetection {
  const signals = new Set<string>();
  const leaks: LlmDetection["leaks"] = [];

  for (const f of files) {
    const inManifest = MANIFESTS.test(f.path);
    for (const [name, patterns] of Object.entries(SDK_SIGNATURES)) {
      // Manifests are authoritative; source imports are corroborating.
      if (patterns.some((p) => p.test(f.text))) {
        if (inManifest || /\.(py|js|ts|jsx|tsx|mjs)$/.test(f.path)) signals.add(name);
      }
    }
    if (HARDCODED_KEY.test(f.text)) leaks.push({ path: f.path, kind: "hardcoded-key" });
    if (DIRECT_BASE_URL.test(f.text)) leaks.push({ path: f.path, kind: "direct-base-url" });
  }

  return { isLlmApp: signals.size > 0, signals: [...signals], leaks };
}

// ---------------------------------------------------------------------------
// 2. Mint a per-tenant virtual key on the LiteLLM gateway.
// ---------------------------------------------------------------------------

// Per-tier defaults — the "freedom within bounds" fence, applied to models.
const TIER_POLICY: Record<
  Tier,
  { models: string[]; maxBudget: number; budgetDuration: string; rpm: number; tpm: number }
> = {
  free: { models: ["chat-small"], maxBudget: 5, budgetDuration: "30d", rpm: 20, tpm: 40_000 },
  standard: {
    models: ["chat-small", "chat-large"],
    maxBudget: 50,
    budgetDuration: "30d",
    rpm: 60,
    tpm: 150_000,
  },
  premium: {
    models: ["chat-small", "chat-large", "reasoning"],
    maxBudget: 500,
    budgetDuration: "30d",
    rpm: 240,
    tpm: 600_000,
  },
};

export interface LiteLlmClientConfig {
  baseUrl: string; // LITELLM_BASE_URL, e.g. http://litellm:4000
  masterKey: string; // LITELLM_MASTER_KEY — only the control-plane holds this
}

export async function mintVirtualKey(
  cfg: LiteLlmClientConfig,
  tenantId: string,
  appId: string,
  tier: Tier,
): Promise<VirtualKey> {
  const policy = TIER_POLICY[tier];
  const keyName = `tenant:${tenantId}:app:${appId}`;

  const res = await fetch(`${cfg.baseUrl}/key/generate`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${cfg.masterKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      key_alias: keyName,
      models: policy.models, // allowlist — requests for other models are rejected
      max_budget: policy.maxBudget, // hard spend cap over the window
      budget_duration: policy.budgetDuration,
      rpm_limit: policy.rpm,
      tpm_limit: policy.tpm,
      // Read back by hooks/tenant_cache.py to scope the cache namespace, and by
      // the control-plane to attribute spend per tenant for billing.
      metadata: { tenant_id: tenantId, app_id: appId, tier },
    }),
  });

  if (!res.ok) {
    throw new Error(`LiteLLM key mint failed (${res.status}): ${await res.text()}`);
  }
  const data = (await res.json()) as { key: string };
  return { key: data.key, keyName };
}

/** Rotate/revoke a tenant key (offboarding, leak response, tier change). */
export async function revokeVirtualKey(cfg: LiteLlmClientConfig, key: string): Promise<void> {
  const res = await fetch(`${cfg.baseUrl}/key/delete`, {
    method: "POST",
    headers: { Authorization: `Bearer ${cfg.masterKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ keys: [key] }),
  });
  if (!res.ok) throw new Error(`LiteLLM key revoke failed (${res.status}): ${await res.text()}`);
}

// ---------------------------------------------------------------------------
// 3. Env injected into the tenant container.
// ---------------------------------------------------------------------------

/**
 * Both the OpenAI and Anthropic SDKs are pointed at the LiteLLM gateway, so
 * whichever the creator's app happens to use, it routes through governance.
 * LiteLLM exposes an OpenAI-compatible surface at /v1 and an Anthropic-compatible
 * one at /anthropic — we set both, keyed by the same virtual key.
 */
export function buildLlmEnv(baseUrl: string, vkey: VirtualKey): Record<string, string> {
  return {
    OPENAI_API_KEY: vkey.key,
    OPENAI_BASE_URL: `${baseUrl}/v1`,
    ANTHROPIC_API_KEY: vkey.key,
    ANTHROPIC_BASE_URL: `${baseUrl}/anthropic`,
    // Convenience for apps that read a generic var:
    LLM_GATEWAY_URL: baseUrl,
  };
}

// ---------------------------------------------------------------------------
// 4. Neutralize hard-coded keys / direct base URLs from vibe-coded apps.
// ---------------------------------------------------------------------------

/**
 * The env vars above already OVERRIDE the SDK's defaults, so a direct base URL
 * in code is superseded at runtime. But a hard-coded *key* is a live secret that
 * must not ship in the image. We strip it to an env reference and surface a
 * plain-English warning the creator sees in the kiosk.
 */
export function sanitizeHardcodedKeys(files: BundleFile[]): {
  files: BundleFile[];
  warnings: string[];
} {
  const warnings: string[] = [];
  const out = files.map((f) => {
    if (!HARDCODED_KEY.test(f.text)) return f;
    warnings.push(
      `Found a hard-coded API key in "${f.path}". It was removed — your app now ` +
        `uses the platform's managed key automatically, so you don't need one.`,
    );
    // Replace the literal with a reference; the injected OPENAI_API_KEY takes over.
    return { ...f, text: f.text.replace(new RegExp(HARDCODED_KEY, "g"), "") };
  });
  return { files: out, warnings };
}

// ---------------------------------------------------------------------------
// Orchestration — called by the provisioning saga after the Dockerfile step.
// ---------------------------------------------------------------------------

export interface ProvisionResult {
  isLlmApp: boolean;
  env: Record<string, string>; // merge into the tenant container's env
  virtualKey?: VirtualKey; // persist (encrypted) → tenant↔key map in Postgres
  warnings: string[]; // shown in the kiosk UI
}

export async function provisionLlmApp(args: {
  litellm: LiteLlmClientConfig;
  tenantId: string;
  appId: string;
  tier: Tier;
  files: BundleFile[];
}): Promise<ProvisionResult> {
  const detection = detectLlmApp(args.files);
  if (!detection.isLlmApp) {
    return { isLlmApp: false, env: {}, warnings: [] };
  }

  const { warnings } = sanitizeHardcodedKeys(args.files);
  const vkey = await mintVirtualKey(args.litellm, args.tenantId, args.appId, args.tier);
  const env = buildLlmEnv(args.litellm.baseUrl, vkey);

  return { isLlmApp: true, env, virtualKey: vkey, warnings };
}
