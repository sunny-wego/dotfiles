#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const VALID_AGENTS = ["codex", "claude", "gemini"];
const VALID_TRANSPORTS = ["stdio", "http", "sse"];
const VALID_CLAUDE_SCOPES = ["local", "user", "project"];
const VALID_GEMINI_SCOPES = ["user", "project"];

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = path.dirname(scriptPath);
const repoRoot = path.resolve(scriptDir, "..");
const defaultManifestPath = path.join(repoRoot, "mcp", "manifest.yaml");
const defaultStatePath = path.join(repoRoot, "mcp", ".sync-state.json");
let requireEnvValues = true;

function usage() {
  console.log(`Usage: node scripts/mcp-sync.mjs <plan|apply> [options]

Options:
  --agent <codex|claude|gemini|all>   Limit sync to one agent (default: all)
  --manifest <path>                   Override the manifest path
  --state <path>                      Override the sync state path
  -h, --help                          Show this help text`);
}

function fail(message) {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = [...argv];
  const mode = args.shift();

  if (!mode || mode === "--help" || mode === "-h") {
    usage();
    process.exit(mode ? 0 : 1);
  }

  if (mode !== "plan" && mode !== "apply") {
    fail(`Unsupported mode "${mode}". Use "plan" or "apply".`);
  }

  const options = {
    mode,
    agent: "all",
    manifestPath: defaultManifestPath,
    statePath: defaultStatePath,
  };

  while (args.length > 0) {
    const current = args.shift();

    if (current === "--agent") {
      options.agent = args.shift() ?? fail("Missing value for --agent.");
      if (options.agent !== "all" && !VALID_AGENTS.includes(options.agent)) {
        fail(`Unsupported agent "${options.agent}".`);
      }
      continue;
    }

    if (current === "--manifest") {
      options.manifestPath = path.resolve(args.shift() ?? fail("Missing value for --manifest."));
      continue;
    }

    if (current === "--state") {
      options.statePath = path.resolve(args.shift() ?? fail("Missing value for --state."));
      continue;
    }

    if (current === "--help" || current === "-h") {
      usage();
      process.exit(0);
    }

    fail(`Unknown option "${current}".`);
  }

  return options;
}

function runCommand(argv, { allowFailure = false } = {}) {
  const result = spawnSync(argv[0], argv.slice(1), {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0 && !allowFailure) {
    const stderr = result.stderr?.trim();
    const stdout = result.stdout?.trim();
    const details = [stderr, stdout].filter(Boolean).join("\n");
    throw new Error(details || `${argv[0]} exited with status ${result.status}`);
  }

  return result;
}

function loadManifest(manifestPath) {
  if (!existsSync(manifestPath)) {
    fail(`Manifest not found at ${manifestPath}`);
  }

  const result = runCommand(["yq", "eval", "-o=json", ".", manifestPath]);
  const manifest = JSON.parse(result.stdout || "{}");

  if (manifest.schemaVersion !== 1) {
    fail(`Unsupported schemaVersion "${manifest.schemaVersion}".`);
  }

  if (!manifest.servers || typeof manifest.servers !== "object") {
    fail("Manifest must contain a top-level servers map.");
  }

  return manifest;
}

function loadState(statePath) {
  if (!existsSync(statePath)) {
    return { version: 1, agents: {} };
  }

  const state = JSON.parse(readFileSync(statePath, "utf8"));
  if (state.version !== 1 || typeof state.agents !== "object") {
    return { version: 1, agents: {} };
  }

  return state;
}

function saveState(statePath, state) {
  mkdirSync(path.dirname(statePath), { recursive: true });
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
}

function normalizeScope(agent, manifest) {
  const scope = manifest.defaultScope?.[agent] ?? "user";

  if (agent === "codex") {
    if (scope !== "user") {
      fail(`Codex only supports user-scoped sync in this workflow. Invalid scope "${scope}".`);
    }
    return scope;
  }

  if (agent === "claude" && !VALID_CLAUDE_SCOPES.includes(scope)) {
    fail(`Invalid Claude scope "${scope}".`);
  }

  if (agent === "gemini" && !VALID_GEMINI_SCOPES.includes(scope)) {
    fail(`Invalid Gemini scope "${scope}".`);
  }

  return scope;
}

function resolveEnvValue(sourceEnv, context) {
  const value = process.env[sourceEnv];
  if (!value) {
    if (!requireEnvValues) {
      return `__MISSING_ENV_${sourceEnv}__`;
    }
    fail(`${context} requires environment variable ${sourceEnv}`);
  }
  return value;
}

function resolveEnvFlags(envMap = {}, context) {
  const entries = [];

  for (const [targetEnv, sourceEnv] of Object.entries(envMap)) {
    if (typeof sourceEnv !== "string" || !sourceEnv) {
      fail(`${context} env.${targetEnv} must be a source environment variable name.`);
    }

    entries.push({
      actual: `${targetEnv}=${resolveEnvValue(sourceEnv, `${context} env.${targetEnv}`)}`,
      display: `${targetEnv}=<env:${sourceEnv}>`,
    });
  }

  return entries;
}

function resolveArgValue(arg, context) {
  if (typeof arg === "string") {
    return { actual: arg, display: arg };
  }

  if (!arg || typeof arg !== "object" || typeof arg.fromEnv !== "string") {
    fail(`${context} args entries must be strings or { fromEnv, prefix?, suffix? } objects.`);
  }

  const prefix = typeof arg.prefix === "string" ? arg.prefix : "";
  const suffix = typeof arg.suffix === "string" ? arg.suffix : "";

  return {
    actual: `${prefix}${resolveEnvValue(arg.fromEnv, `${context} args.fromEnv`)}${suffix}`,
    display: `${prefix}<env:${arg.fromEnv}>${suffix}`,
  };
}

function resolveArgs(args = [], context) {
  if (!Array.isArray(args)) {
    fail(`${context} args must be an array.`);
  }

  const actual = [];
  const display = [];

  for (const arg of args) {
    const resolved = resolveArgValue(arg, context);
    actual.push(resolved.actual);
    display.push(resolved.display);
  }

  return { actual, display };
}

function resolveHeaderValue(headerName, spec, context) {
  if (typeof spec === "string") {
    return { actual: spec, display: spec };
  }

  if (!spec || typeof spec !== "object" || typeof spec.fromEnv !== "string") {
    fail(`${context} headers.${headerName} must be a string or { fromEnv, prefix? }.`);
  }

  const prefix = typeof spec.prefix === "string" ? spec.prefix : "";
  return {
    actual: `${prefix}${resolveEnvValue(spec.fromEnv, `${context} headers.${headerName}`)}`,
    display: `${prefix}<env:${spec.fromEnv}>`,
  };
}

function resolveHeaders(headerMap = {}, context) {
  return Object.entries(headerMap).map(([headerName, spec]) => {
    const value = resolveHeaderValue(headerName, spec, context);
    return {
      actual: `${headerName}: ${value.actual}`,
      display: `${headerName}: ${value.display}`,
    };
  });
}

function resolveAuth(authConfig, context) {
  if (authConfig === undefined) {
    return null;
  }

  if (!authConfig || typeof authConfig !== "object") {
    fail(`${context} auth must be an object.`);
  }

  const type = authConfig.type ?? "bearer";
  if (!["bearer", "header"].includes(type)) {
    fail(`${context} auth.type must be "bearer" or "header".`);
  }

  if (typeof authConfig.fromEnv !== "string" || !authConfig.fromEnv) {
    fail(`${context} auth.fromEnv must be a source environment variable name.`);
  }

  let header = authConfig.header;
  if (header === undefined && type === "bearer") {
    header = "Authorization";
  }
  if (typeof header !== "string" || !header) {
    fail(`${context} auth.header must be a non-empty string.`);
  }

  let prefix = authConfig.prefix;
  if (prefix === undefined && type === "bearer") {
    prefix = "Bearer ";
  }
  if (prefix === undefined && type === "header") {
    prefix = "";
  }
  if (typeof prefix !== "string") {
    fail(`${context} auth.prefix must be a string.`);
  }

  return { type, fromEnv: authConfig.fromEnv, header, prefix };
}

function resolveAuthHeader(auth, context) {
  if (!auth) {
    return null;
  }

  const value = resolveEnvValue(auth.fromEnv, `${context} auth.fromEnv`);
  return {
    name: auth.header,
    actual: `${auth.header}: ${auth.prefix}${value}`,
    display: `${auth.header}: ${auth.prefix}<env:${auth.fromEnv}>`,
  };
}

function getHeaderName(headerLine) {
  return String(headerLine).split(":", 1)[0].trim().toLowerCase();
}

function getStdioCommand(serverConfig, context) {
  if (typeof serverConfig.command !== "string" || !serverConfig.command) {
    fail(`${context} requires a stdio command.`);
  }
  return serverConfig.command;
}

function getRemoteUrl(serverConfig, context, transport) {
  if (typeof serverConfig.url !== "string" || !serverConfig.url) {
    fail(`${context} requires a url for ${transport}.`);
  }
  return serverConfig.url;
}

function buildManagedName(namespace, serverKey, serverConfig) {
  if (typeof serverConfig.name === "string" && serverConfig.name) {
    return serverConfig.name;
  }
  return `${namespace}__${serverKey}`;
}

function buildEffectiveConfig(serverConfig) {
  return {
    ...serverConfig,
    env: serverConfig.env ? { ...serverConfig.env } : undefined,
    headers: serverConfig.headers ? { ...serverConfig.headers } : undefined,
  };
}

function buildDesiredEntries(manifest, selectedAgent) {
  const namespace = manifest.namespace || "mcp";
  const desired = Object.fromEntries(VALID_AGENTS.map((agent) => [agent, []]));

  for (const [serverKey, serverConfig] of Object.entries(manifest.servers)) {
    if (!serverConfig || typeof serverConfig !== "object") {
      fail(`servers.${serverKey} must be an object.`);
    }

    const transport = serverConfig.transport;
    if (!VALID_TRANSPORTS.includes(transport)) {
      fail(`servers.${serverKey} has unsupported transport "${transport}".`);
    }

    const excludeAgents = Array.isArray(serverConfig.excludeAgents) ? serverConfig.excludeAgents : [];
    for (const excludedAgent of excludeAgents) {
      if (!VALID_AGENTS.includes(excludedAgent)) {
        fail(`servers.${serverKey} has unsupported excluded agent "${excludedAgent}".`);
      }
    }

    if (serverConfig.agents !== undefined) {
      fail(
        `servers.${serverKey} uses legacy agents overrides, which are no longer supported. Use excludeAgents/defaultScope/auth instead.`,
      );
    }

    for (const agent of VALID_AGENTS) {
      if (selectedAgent !== "all" && selectedAgent !== agent) {
        continue;
      }

      if (excludeAgents.includes(agent)) {
        continue;
      }

      const effectiveConfig = buildEffectiveConfig(serverConfig);
      const transport = effectiveConfig.transport;

      if (!VALID_TRANSPORTS.includes(transport)) {
        fail(`servers.${serverKey} has unsupported transport "${transport}".`);
      }

      const scope = normalizeScope(agent, manifest);
      const name = buildManagedName(namespace, serverKey, effectiveConfig);
      desired[agent].push({
        agent,
        key: `${scope}:${name}`,
        managedName: name,
        scope,
        transport,
        serverKey,
        effectiveConfig,
      });
    }
  }

  return desired;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function buildAddCommand(entry) {
  const { agent, managedName, scope, transport, effectiveConfig, serverKey } = entry;
  const context = `${agent}.${serverKey}`;
  const envFlags = resolveEnvFlags(effectiveConfig.env, context);
  const displayEnvFlags = envFlags.flatMap((pair) => ["-e", pair.display]);
  const actualEnvFlags = envFlags.flatMap((pair) => ["-e", pair.actual]);
  const resolvedArgs = resolveArgs(effectiveConfig.args, context);
  const auth = resolveAuth(effectiveConfig.auth, context);

  const command = [];
  const display = [];

  if (agent === "codex") {
    if (transport === "sse") {
      fail(`${context} uses SSE, which is not supported by codex mcp add.`);
    }

    command.push("codex", "mcp", "add", managedName);
    display.push("codex", "mcp", "add", managedName);

    if (transport === "stdio") {
      if (auth) {
        fail(`${context} defines auth for stdio transport. Use env/args for local process auth.`);
      }
      for (const pair of envFlags) {
        command.push("--env", pair.actual);
        display.push("--env", pair.display);
      }

      const stdioCommand = getStdioCommand(effectiveConfig, context);
      command.push("--", stdioCommand, ...resolvedArgs.actual);
      display.push("--", stdioCommand, ...resolvedArgs.display);
      return { command, display };
    }

    if (effectiveConfig.headers) {
      fail(`${context} declares HTTP headers, which Codex cannot configure declaratively.`);
    }

    const remoteUrl = getRemoteUrl(effectiveConfig, context, transport);

    if (auth && auth.type === "header") {
      // `codex mcp add` has no flag for custom headers, but config.toml supports
      // env_http_headers (header name -> env var name, resolved at runtime). Add the
      // base URL entry via the CLI, then append the env_http_headers table so the
      // credential stays in the environment instead of being baked into config.toml.
      if (auth.prefix !== "") {
        fail(
          `${context} Codex header auth cannot apply a prefix; store the full header value (e.g. "Basic <token>") in env var ${auth.fromEnv} and omit prefix.`,
        );
      }
      const addArgs = ["codex", "mcp", "add", managedName, "--url", remoteUrl];
      const configPath = '"${CODEX_HOME:-$HOME/.codex}/config.toml"';
      const headerBlock =
        `\n[mcp_servers.${managedName}.env_http_headers]\n` + `${auth.header} = "${auth.fromEnv}"\n`;
      const shellScript =
        `${addArgs.map(shellQuote).join(" ")} && cat >> ${configPath} <<'CODEX_MCP_EOF'\n` +
        `${headerBlock}CODEX_MCP_EOF`;
      return {
        command: ["sh", "-c", shellScript],
        display: [
          "codex",
          "mcp",
          "add",
          managedName,
          "--url",
          remoteUrl,
          "+env_http_headers",
          `${auth.header}=<env:${auth.fromEnv}>`,
        ],
      };
    }

    command.push("--url", remoteUrl);
    display.push("--url", remoteUrl);

    if (auth) {
      if (auth.type !== "bearer") {
        fail(`${context} auth.type=header is not supported by codex remote transport.`);
      }
      if (auth.header !== "Authorization" || auth.prefix !== "Bearer ") {
        fail(`${context} Codex bearer auth must use header "Authorization" and prefix "Bearer ".`);
      }
      command.push("--bearer-token-env-var", auth.fromEnv);
      display.push("--bearer-token-env-var", auth.fromEnv);
    }

    return { command, display };
  }

  if (agent === "claude") {
    command.push("claude", "mcp", "add", "--scope", scope, "--transport", transport);
    display.push("claude", "mcp", "add", "--scope", scope, "--transport", transport);

    if (transport === "stdio") {
      if (auth) {
        fail(`${context} defines auth for stdio transport. Use env/args for local process auth.`);
      }
      const stdioCommand = getStdioCommand(effectiveConfig, context);
      command.push(managedName, ...actualEnvFlags, "--", stdioCommand, ...resolvedArgs.actual);
      display.push(managedName, ...displayEnvFlags, "--", stdioCommand, ...resolvedArgs.display);
      return { command, display };
    }

    const headers = resolveHeaders(effectiveConfig.headers, context);
    const authHeader = resolveAuthHeader(auth, context);
    if (
      authHeader &&
      headers.some((headerPair) => getHeaderName(headerPair.display) === getHeaderName(authHeader.display))
    ) {
      fail(`${context} auth header "${authHeader.name}" duplicates headers.${authHeader.name}.`);
    }

    const remoteUrl = getRemoteUrl(effectiveConfig, context, transport);
    command.push(managedName, remoteUrl);
    display.push(managedName, remoteUrl);

    for (const header of headers) {
      command.push("-H", header.actual);
      display.push("-H", header.display);
    }
    if (authHeader) {
      command.push("-H", authHeader.actual);
      display.push("-H", authHeader.display);
    }

    return { command, display };
  }

  if (agent === "gemini") {
    command.push("gemini", "mcp", "add", "--scope", scope, "--transport", transport);
    display.push("gemini", "mcp", "add", "--scope", scope, "--transport", transport);

    if (transport === "stdio") {
      if (auth) {
        fail(`${context} defines auth for stdio transport. Use env/args for local process auth.`);
      }
      const stdioCommand = getStdioCommand(effectiveConfig, context);
      command.push(managedName, ...actualEnvFlags, stdioCommand, ...resolvedArgs.actual);
      display.push(managedName, ...displayEnvFlags, stdioCommand, ...resolvedArgs.display);
      return { command, display };
    }

    const headers = resolveHeaders(effectiveConfig.headers, context);
    const authHeader = resolveAuthHeader(auth, context);
    if (
      authHeader &&
      headers.some((headerPair) => getHeaderName(headerPair.display) === getHeaderName(authHeader.display))
    ) {
      fail(`${context} auth header "${authHeader.name}" duplicates headers.${authHeader.name}.`);
    }
    const remoteUrl = getRemoteUrl(effectiveConfig, context, transport);
    command.push(managedName, remoteUrl);
    display.push(managedName, remoteUrl);

    for (const header of headers) {
      command.push("-H", header.actual);
      display.push("-H", header.display);
    }
    if (authHeader) {
      command.push("-H", authHeader.actual);
      display.push("-H", authHeader.display);
    }

    return { command, display };
  }

  fail(`Unsupported agent "${agent}".`);
}

function buildEntryFingerprint(entry) {
  return JSON.stringify({
    name: entry.managedName,
    scope: entry.scope,
    transport: entry.transport,
    effectiveConfig: entry.effectiveConfig,
  });
}

function buildRemoveCommand(agent, managedName, scope) {
  if (agent === "codex") {
    return {
      command: ["codex", "mcp", "remove", managedName],
      display: ["codex", "mcp", "remove", managedName],
      allowFailure: true,
      canIgnoreFailure: (result) => result.status === 0,
    };
  }

  if (agent === "claude") {
    return {
      command: ["claude", "mcp", "remove", "--scope", scope, managedName],
      display: ["claude", "mcp", "remove", "--scope", scope, managedName],
      allowFailure: true,
      canIgnoreFailure: (result) =>
        result.status === 0 || /No .* MCP server found/i.test(`${result.stderr}\n${result.stdout}`),
    };
  }

  if (agent === "gemini") {
    return {
      command: ["gemini", "mcp", "remove", "--scope", scope, managedName],
      display: ["gemini", "mcp", "remove", "--scope", scope, managedName],
      allowFailure: true,
      canIgnoreFailure: (result) => result.status === 0,
    };
  }

  fail(`Unsupported agent "${agent}".`);
}

function buildActions(manifest, state, selectedAgent) {
  const desired = buildDesiredEntries(manifest, selectedAgent);
  const actions = [];
  const nextState = structuredClone(state);

  for (const agent of VALID_AGENTS) {
    if (selectedAgent !== "all" && selectedAgent !== agent) {
      continue;
    }

    const desiredEntries = desired[agent];
    const desiredKeys = new Set(desiredEntries.map((entry) => entry.key));
    const previousEntries = Array.isArray(state.agents?.[agent]) ? state.agents[agent] : [];
    const previousEntriesByKey = new Map(
      previousEntries.map((entry) => [`${entry.scope}:${entry.name}`, entry]),
    );

    for (const previous of previousEntries) {
      const previousKey = `${previous.scope}:${previous.name}`;
      if (desiredKeys.has(previousKey)) {
        continue;
      }

      const remove = buildRemoveCommand(agent, previous.name, previous.scope);
      actions.push({
        type: "remove",
        reason: "prune stale managed entry",
        agent,
        managedName: previous.name,
        scope: previous.scope,
        ...remove,
      });
    }

    for (const entry of desiredEntries) {
      const fingerprint = buildEntryFingerprint(entry);
      const previous = previousEntriesByKey.get(entry.key);

      if (previous?.fingerprint === fingerprint) {
        continue;
      }

      const remove = buildRemoveCommand(agent, entry.managedName, entry.scope);
      const add = buildAddCommand(entry);

      actions.push({
        type: "remove",
        reason: "replace managed entry",
        agent,
        managedName: entry.managedName,
        scope: entry.scope,
        ...remove,
      });
      actions.push({
        type: "add",
        reason: "apply desired definition",
        agent,
        managedName: entry.managedName,
        scope: entry.scope,
        command: add.command,
        display: add.display,
      });
    }

    nextState.agents[agent] = desiredEntries.map((entry) => ({
      name: entry.managedName,
      scope: entry.scope,
      fingerprint: buildEntryFingerprint(entry),
    }));
  }

  return { actions, nextState };
}

function formatCommand(display) {
  return display
    .map((part) => (/\s/.test(part) ? JSON.stringify(part) : part))
    .join(" ");
}

function printPlan(actions) {
  if (actions.length === 0) {
    console.log("No changes planned.");
    return;
  }

  for (const action of actions) {
    console.log(`[${action.agent}] ${action.reason}: ${action.type} ${action.scope}:${action.managedName}`);
    console.log(`  ${formatCommand(action.display)}`);
  }
}

function applyActions(actions) {
  for (const action of actions) {
    console.log(`[${action.agent}] ${action.type} ${action.scope}:${action.managedName}`);
    const result = runCommand(action.command, { allowFailure: action.allowFailure });

    if (action.allowFailure && action.canIgnoreFailure && action.canIgnoreFailure(result)) {
      continue;
    }

    if (result.status !== 0) {
      const stderr = result.stderr?.trim();
      const stdout = result.stdout?.trim();
      const details = [stderr, stdout].filter(Boolean).join("\n");
      fail(details || `${action.command[0]} exited with status ${result.status}`);
    }
  }
}

const options = parseArgs(process.argv.slice(2));
requireEnvValues = options.mode === "apply";
const manifest = loadManifest(options.manifestPath);
const state = loadState(options.statePath);
const { actions, nextState } = buildActions(manifest, state, options.agent);

if (options.mode === "plan") {
  printPlan(actions);
  process.exit(0);
}

applyActions(actions);
saveState(options.statePath, nextState);
