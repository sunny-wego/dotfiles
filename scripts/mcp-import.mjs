#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const VALID_CLIENTS = ["codex", "claude", "gemini"];
const VALID_TRANSPORTS = ["stdio", "http", "sse"];

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = path.dirname(scriptPath);
const repoRoot = path.resolve(scriptDir, "..");
const defaultManifestPath = path.join(repoRoot, "mcp", "manifest.yaml");

function usage() {
  console.log(`Usage:
  node scripts/mcp-import.mjs <parse|apply> --instruction "<mcp add command>" [options]
  node scripts/mcp-import.mjs remove --key <serverKey> [options]

Options:
  --instruction <string>             MCP add instruction to parse
  --key <serverKey>                  Override manifest server key (default: parsed name)
  --manifest <path>                  Override manifest path (default: mcp/manifest.yaml)
  --dry-run                          Show what apply would write without modifying files
  -h, --help                         Show this help text

Examples:
  node scripts/mcp-import.mjs parse --instruction 'codex mcp add posthog --url https://mcp.posthog.com/mcp'
  node scripts/mcp-import.mjs apply --instruction 'claude mcp add --transport http braintrust https://api.braintrust.dev/mcp --header "Authorization: Bearer $BRAINTRUST_API_KEY"'
  node scripts/mcp-import.mjs remove --key braintrust
`);
}

function fail(message) {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function runCommand(argv, { env, input } = {}) {
  const result = spawnSync(argv[0], argv.slice(1), {
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"],
    env: env ?? process.env,
    input: input ?? undefined,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const stderr = result.stderr?.trim();
    const stdout = result.stdout?.trim();
    fail([stderr, stdout].filter(Boolean).join("\n") || `${argv[0]} exited with status ${result.status}`);
  }

  return result;
}

function parseArgs(argv) {
  const args = [...argv];
  const mode = args.shift();

  if (!mode || mode === "--help" || mode === "-h") {
    usage();
    process.exit(mode ? 0 : 1);
  }

  if (!["parse", "apply", "remove"].includes(mode)) {
    fail(`Unsupported mode "${mode}". Use "parse", "apply", or "remove".`);
  }

  const options = {
    mode,
    instruction: "",
    key: "",
    manifestPath: defaultManifestPath,
    dryRun: false,
  };

  while (args.length > 0) {
    const current = args.shift();

    if (current === "--instruction") {
      options.instruction = args.shift() ?? fail("Missing value for --instruction.");
      continue;
    }

    if (current === "--key") {
      options.key = args.shift() ?? fail("Missing value for --key.");
      continue;
    }

    if (current === "--manifest") {
      options.manifestPath = path.resolve(args.shift() ?? fail("Missing value for --manifest."));
      continue;
    }

    if (current === "--dry-run") {
      options.dryRun = true;
      continue;
    }

    if (current === "--help" || current === "-h") {
      usage();
      process.exit(0);
    }

    fail(`Unknown option "${current}".`);
  }

  if (options.mode !== "remove" && !options.instruction) {
    fail("--instruction is required.");
  }
  if (options.mode === "remove" && !options.key) {
    fail("--key is required for remove mode.");
  }

  return options;
}

function shellSplit(input) {
  const tokens = [];
  let current = "";
  let quote = null;
  let escaped = false;

  for (let i = 0; i < input.length; i += 1) {
    const ch = input[i];

    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }

    if (ch === "\\") {
      escaped = true;
      continue;
    }

    if (quote) {
      if (ch === quote) {
        quote = null;
      } else {
        current += ch;
      }
      continue;
    }

    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }

    if (/\s/.test(ch)) {
      if (current) {
        tokens.push(current);
        current = "";
      }
      continue;
    }

    current += ch;
  }

  if (escaped) {
    fail("Invalid instruction: trailing escape character.");
  }
  if (quote) {
    fail(`Invalid instruction: unmatched ${quote} quote.`);
  }
  if (current) {
    tokens.push(current);
  }

  return tokens;
}

function parseEnvReference(value) {
  let match = value.match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
  if (match) {
    return match[1];
  }

  match = value.match(/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/);
  if (match) {
    return match[1];
  }

  match = value.match(/^<env:([A-Za-z_][A-Za-z0-9_]*)>$/);
  if (match) {
    return match[1];
  }

  return null;
}

function parseEnvAssignment(input, context) {
  const eq = input.indexOf("=");
  if (eq <= 0) {
    fail(`${context} env value must be KEY=VALUE.`);
  }

  const key = input.slice(0, eq);
  const value = input.slice(eq + 1);

  const ref = parseEnvReference(value);
  if (!ref) {
    fail(`${context} env "${input}" must reference an env var (e.g. KEY=$KEY or KEY=\${KEY}).`);
  }

  return { target: key, source: ref };
}

function parseHeaderValue(value, context) {
  const envOnly = parseEnvReference(value);
  if (envOnly) {
    return { fromEnv: envOnly };
  }

  const embedded = value.match(/^(.*?)(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)(.*)$/);
  if (embedded) {
    const envName = parseEnvReference(embedded[2]);
    if (!envName) {
      fail(`${context} could not parse env reference in header value.`);
    }
    if (embedded[3]) {
      fail(`${context} header value with env ref cannot include suffix.`);
    }
    return { fromEnv: envName, prefix: embedded[1] };
  }

  return value;
}

function parseHeaderSpec(input, context) {
  const idx = input.indexOf(":");
  if (idx <= 0) {
    fail(`${context} header must be "Name: Value".`);
  }

  const name = input.slice(0, idx).trim();
  const value = input.slice(idx + 1).trim();
  if (!name || !value) {
    fail(`${context} header must be "Name: Value".`);
  }

  const bearer = value.match(/^Bearer\s+(.+)$/i);
  if (name.toLowerCase() === "authorization" && bearer) {
    const ref = parseEnvReference(bearer[1].trim());
    if (ref) {
      return {
        auth: {
          type: "bearer",
          fromEnv: ref,
        },
      };
    }
  }

  return {
    headerName: name,
    headerValue: parseHeaderValue(value, context),
  };
}

function tokensToArgs(tokens) {
  return tokens.map((token) => {
    const ref = parseEnvReference(token);
    if (!ref) {
      return token;
    }
    return { fromEnv: ref };
  });
}

function parseCodexAdd(tokens) {
  if (tokens.length < 5) {
    fail("Instruction is too short for codex mcp add.");
  }

  const name = tokens[3];
  let transport = "stdio";
  let url = "";
  let command = "";
  let commandArgs = [];
  const env = {};
  let auth = null;

  let i = 4;
  while (i < tokens.length) {
    const token = tokens[i];

    if (token === "--url") {
      url = tokens[i + 1] ?? fail("Missing value for --url.");
      transport = "http";
      i += 2;
      continue;
    }

    if (token === "--bearer-token-env-var") {
      const envVar = tokens[i + 1] ?? fail("Missing value for --bearer-token-env-var.");
      auth = { type: "bearer", fromEnv: envVar };
      i += 2;
      continue;
    }

    if (token === "--env") {
      const pair = tokens[i + 1] ?? fail("Missing value for --env.");
      const parsed = parseEnvAssignment(pair, "codex");
      env[parsed.target] = parsed.source;
      i += 2;
      continue;
    }

    if (token === "--") {
      command = tokens[i + 1] ?? fail("Missing stdio command after --.");
      commandArgs = tokens.slice(i + 2);
      i = tokens.length;
      continue;
    }

    fail(`Unsupported codex argument "${token}".`);
  }

  if (transport !== "stdio" && command) {
    fail("Codex instruction cannot include both --url and stdio command.");
  }

  if (transport === "stdio" && !command) {
    fail("Codex stdio instruction must include a command after --.");
  }

  if (transport !== "stdio" && Object.keys(env).length > 0) {
    fail("Codex remote instruction cannot include --env in manifest import.");
  }

  const entry = {
    name,
    transport,
  };

  if (transport === "stdio") {
    entry.command = command;
    if (commandArgs.length > 0) {
      entry.args = tokensToArgs(commandArgs);
    }
    if (Object.keys(env).length > 0) {
      entry.env = env;
    }
  } else {
    entry.url = url;
    if (auth) {
      entry.auth = auth;
    }
  }

  return { key: name, entry };
}

function parseClaudeOrGeminiAdd(tokens, client) {
  const delimiter = tokens.indexOf("--");
  const main = delimiter === -1 ? tokens.slice(3) : tokens.slice(3, delimiter);
  const stdioTail = delimiter === -1 ? [] : tokens.slice(delimiter + 1);

  let transport = "";
  let name = "";
  let commandOrUrl = "";
  const extraPositionals = [];
  const env = {};
  const headers = {};
  let auth = null;

  for (let i = 0; i < main.length; i += 1) {
    const token = main[i];

    if (token === "--transport" || token === "-t") {
      transport = main[i + 1] ?? fail(`Missing value for ${token}.`);
      i += 1;
      continue;
    }

    if (token === "--scope" || token === "-s") {
      i += 1;
      continue;
    }

    if (token === "-e" || token === "--env") {
      const pair = main[i + 1] ?? fail(`Missing value for ${token}.`);
      const parsed = parseEnvAssignment(pair, client);
      env[parsed.target] = parsed.source;
      i += 1;
      continue;
    }

    if (token === "-H" || token === "--header") {
      const spec = main[i + 1] ?? fail(`Missing value for ${token}.`);
      const parsed = parseHeaderSpec(spec, client);
      if (parsed.auth) {
        auth = parsed.auth;
      } else {
        headers[parsed.headerName] = parsed.headerValue;
      }
      i += 1;
      continue;
    }

    if (token === "--description" || token === "--include-tools" || token === "--exclude-tools") {
      fail(
        `${client} option "${token}" is client-specific and not supported in the unified manifest model.`,
      );
    }

    if (token === "--trust") {
      fail(`${client} option "--trust" is client-specific and not supported in the unified manifest model.`);
    }

    if (token.startsWith("-")) {
      fail(`Unsupported ${client} option "${token}".`);
    }

    if (!name) {
      name = token;
      continue;
    }

    if (!commandOrUrl) {
      commandOrUrl = token;
      continue;
    }

    extraPositionals.push(token);
  }

  if (!name) {
    fail(`${client} instruction is missing server name.`);
  }

  if (!transport) {
    if (stdioTail.length > 0) {
      transport = "stdio";
    } else if (commandOrUrl.startsWith("http://") || commandOrUrl.startsWith("https://")) {
      transport = "http";
    } else {
      transport = "stdio";
    }
  }

  if (!VALID_TRANSPORTS.includes(transport)) {
    fail(`${client} transport "${transport}" is not supported by manifest.`);
  }

  const entry = {
    name,
    transport,
  };

  if (transport === "stdio") {
    if (auth || Object.keys(headers).length > 0) {
      fail(`${client} stdio instruction cannot include remote headers/auth.`);
    }

    let commandTokens = [];
    if (stdioTail.length > 0) {
      commandTokens = [...stdioTail];
    } else if (commandOrUrl) {
      commandTokens = [commandOrUrl, ...extraPositionals];
    }

    if (commandTokens.length === 0) {
      fail(`${client} stdio instruction is missing command.`);
    }

    entry.command = commandTokens[0];
    if (commandTokens.length > 1) {
      entry.args = tokensToArgs(commandTokens.slice(1));
    }
    if (Object.keys(env).length > 0) {
      entry.env = env;
    }

    return { key: name, entry };
  }

  if (stdioTail.length > 0) {
    fail(`${client} remote instruction cannot include stdio command after --.`);
  }

  if (!commandOrUrl) {
    fail(`${client} remote instruction is missing URL.`);
  }

  entry.url = commandOrUrl;
  if (Object.keys(headers).length > 0) {
    entry.headers = headers;
  }
  if (auth) {
    entry.auth = auth;
  }

  return { key: name, entry };
}

function parseInstruction(instruction) {
  const tokens = shellSplit(instruction);
  if (tokens.length < 4) {
    fail("Instruction is too short.");
  }

  const client = tokens[0];
  if (!VALID_CLIENTS.includes(client)) {
    fail(`Unsupported client "${client}". Expected one of: ${VALID_CLIENTS.join(", ")}.`);
  }

  if (tokens[1] !== "mcp" || tokens[2] !== "add") {
    fail('Instruction must start with "<client> mcp add ...".');
  }

  if (client === "codex") {
    return parseCodexAdd(tokens);
  }

  return parseClaudeOrGeminiAdd(tokens, client);
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

function printParsed(serverKey, entry) {
  const payload = { [serverKey]: entry };
  const yaml = runCommand(["yq", "eval", "-P", "-"], { input: JSON.stringify(payload) }).stdout.trim();
  console.log(`serverKey: ${serverKey}`);
  console.log("manifestEntry:");
  console.log(yaml);
}

function toYaml(value) {
  return runCommand(["yq", "eval", "-P", "-"], { input: JSON.stringify(value) }).stdout;
}

function applyToManifest(manifestPath, serverKey, entry, { dryRun }) {
  const expression = `.servers[${JSON.stringify(serverKey)}] = (strenv(ENTRY_YAML) | from_yaml)`;

  if (dryRun) {
    console.log(`[dry-run] Would write ${serverKey} to ${manifestPath}`);
    printParsed(serverKey, entry);
    return;
  }

  const entryYaml = toYaml(entry);
  runCommand(["yq", "eval", "-i", expression, manifestPath], {
    env: {
      ...process.env,
      ENTRY_YAML: entryYaml,
    },
  });

  console.log(`Updated ${manifestPath}`);
  printParsed(serverKey, entry);
}

function removeFromManifest(manifestPath, serverKey, { dryRun }) {
  const expression = `del(.servers[${JSON.stringify(serverKey)}])`;

  if (dryRun) {
    console.log(`[dry-run] Would remove ${serverKey} from ${manifestPath}`);
    return;
  }

  runCommand(["yq", "eval", "-i", expression, manifestPath]);
  console.log(`Removed ${serverKey} from ${manifestPath}`);
}

const options = parseArgs(process.argv.slice(2));
loadManifest(options.manifestPath);
if (options.mode === "remove") {
  removeFromManifest(options.manifestPath, options.key, { dryRun: options.dryRun });
  process.exit(0);
}

const parsed = parseInstruction(options.instruction);
const serverKey = options.key || parsed.key;

if (options.mode === "parse") {
  printParsed(serverKey, parsed.entry);
  process.exit(0);
}

applyToManifest(options.manifestPath, serverKey, parsed.entry, { dryRun: options.dryRun });
