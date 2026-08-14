#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function resolveConfigDir() {
  const configured = process.env.OPENCLAW_STATE_DIR || process.env.OPENCLAW_CONFIG_DIR;
  if (configured) {
    return configured;
  }
  if (typeof process.env.HOME !== "string" || process.env.HOME.trim().length === 0) {
    throw new Error("OPENCLAW_STATE_DIR or HOME is required to locate OpenClaw state");
  }
  return path.join(process.env.HOME, ".openclaw");
}

const configDir = resolveConfigDir();
const configPath = process.env.OPENCLAW_CONFIG_PATH || path.join(configDir, "openclaw.json");
const envPath = path.join(configDir, ".env");

function requireNonEmptyString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  return value;
}

function parseJson(value, name) {
  try {
    return JSON.parse(value);
  } catch (error) {
    throw new Error(`${name} must contain valid JSON: ${error.message}`);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function ensurePlainObject(parent, key, name) {
  if (parent[key] === undefined || parent[key] === null) {
    parent[key] = {};
  }
  if (!isPlainObject(parent[key])) {
    throw new Error(`${name} must be a JSON object`);
  }
  return parent[key];
}

function validateHttpUrl(value, name, originOnly = false) {
  requireNonEmptyString(value, name);
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${name} must be an absolute HTTP or HTTPS URL`);
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new Error(`${name} must use HTTP or HTTPS`);
  }
  if (parsed.username || parsed.password) {
    throw new Error(`${name} must not contain credentials`);
  }
  if (parsed.search || parsed.hash) {
    throw new Error(`${name} must not contain a query or fragment`);
  }
  if (originOnly && parsed.pathname !== "/") {
    throw new Error(`${name} must be an origin without a path`);
  }
  return originOnly ? parsed.origin : value;
}

function loadProviders() {
  const providerPaths = [
    path.join(configDir, "providers.json"),
    "/run/secrets/openclaw-providers",
  ];
  let raw = null;
  let source = null;
  for (const candidate of providerPaths) {
    if (fs.existsSync(candidate)) {
      raw = fs.readFileSync(candidate, "utf8");
      source = candidate;
      break;
    }
  }
  if (raw === null && process.env.OPENCLAW_PROVIDERS) {
    raw = process.env.OPENCLAW_PROVIDERS;
    source = "OPENCLAW_PROVIDERS";
  }
  if (raw === null) {
    return {};
  }

  const providers = parseJson(raw, source);
  if (!isPlainObject(providers)) {
    throw new Error("OPENCLAW_PROVIDERS must be a JSON object");
  }

  const cleanProviders = {};
  const reservedNames = new Set(["__proto__", "prototype", "constructor"]);
  for (const [name, provider] of Object.entries(providers)) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) || reservedNames.has(name)) {
      throw new Error(`Provider name '${name}' is invalid`);
    }
    if (!isPlainObject(provider)) {
      throw new Error(`Provider '${name}' must be a JSON object`);
    }
    const api = requireNonEmptyString(provider.api, `Provider '${name}' api`);
    const baseUrl = validateHttpUrl(provider.baseUrl, `Provider '${name}' baseUrl`);
    if (provider.apiKey !== undefined && typeof provider.apiKey !== "string") {
      throw new Error(`Provider '${name}' apiKey must be a string`);
    }
    if (provider.models !== undefined && (
      !Array.isArray(provider.models)
      || !provider.models.every((model) => isPlainObject(model)
        && typeof model.id === "string" && model.id.trim().length > 0)
    )) {
      throw new Error(`Provider '${name}' models must be an array of objects with non-empty ids`);
    }

    cleanProviders[name] = { api, baseUrl };
    if (provider.apiKey !== undefined) {
      cleanProviders[name].apiKey = provider.apiKey;
    }
    if (provider.models !== undefined) {
      cleanProviders[name].models = provider.models;
    }
  }
  console.log(`[entrypoint] Loaded ${Object.keys(cleanProviders).length} provider(s) from ${source}`);
  return cleanProviders;
}

function loadExistingConfig() {
  if (!fs.existsSync(configPath)) {
    return {};
  }
  const config = parseJson(fs.readFileSync(configPath, "utf8"), configPath);
  if (!isPlainObject(config)) {
    throw new Error(`${configPath} must contain a JSON object`);
  }
  return config;
}

function atomicWrite(destination, contents, mode) {
  const temporary = path.join(
    path.dirname(destination),
    `.${path.basename(destination)}.${process.pid}.${Date.now()}.tmp`,
  );
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, "wx", mode);
    fs.writeFileSync(descriptor, contents, "utf8");
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, destination);
    fs.chmodSync(destination, mode);
    const directory = fs.openSync(path.dirname(destination), "r");
    try {
      fs.fsyncSync(directory);
    } finally {
      fs.closeSync(directory);
    }
  } catch (error) {
    if (descriptor !== undefined) {
      fs.closeSync(descriptor);
    }
    try {
      fs.unlinkSync(temporary);
    } catch {
      // Nothing to clean up after a successful rename or failed creation.
    }
    throw error;
  }
}

function removeLegacyTokenFromEnv() {
  if (!fs.existsSync(envPath)) {
    return;
  }
  const original = fs.readFileSync(envPath, "utf8");
  const sanitized = original
    .split(/(?<=\n)/)
    .filter((line) => !/^\s*(?:export\s+)?OPENCLAW_GATEWAY_TOKEN=/.test(line))
    .join("");
  if (sanitized !== original) {
    const existingMode = fs.statSync(envPath).mode & 0o777;
    atomicWrite(envPath, sanitized, existingMode || 0o600);
    console.log(`[entrypoint] Removed legacy gateway token assignment from ${envPath}`);
  }
}

if (typeof process.env.OPENCLAW_GATEWAY_TOKEN !== "string"
    || process.env.OPENCLAW_GATEWAY_TOKEN.trim().length === 0) {
  throw new Error("OPENCLAW_GATEWAY_TOKEN is required on every startup");
}
const gatewayToken = process.env.OPENCLAW_GATEWAY_TOKEN;
const allowedSkillsRaw = process.env.OPENCLAW_ALLOWED_SKILLS || "";
const allowedSkills = allowedSkillsRaw
  ? parseJson(allowedSkillsRaw, "OPENCLAW_ALLOWED_SKILLS")
  : null;
if (allowedSkills !== null && (!Array.isArray(allowedSkills) || !allowedSkills.every(
  (name) => typeof name === "string" && name.trim().length > 0,
))) {
  throw new Error("OPENCLAW_ALLOWED_SKILLS must be a JSON array of non-empty strings");
}

const allowedPluginsRaw = process.env.OPENCLAW_ALLOWED_PLUGINS || "";
const allowedPlugins = allowedPluginsRaw
  ? parseJson(allowedPluginsRaw, "OPENCLAW_ALLOWED_PLUGINS")
  : null;
if (allowedPlugins !== null && (!Array.isArray(allowedPlugins) || !allowedPlugins.every(
  (name) => typeof name === "string" && name.trim().length > 0,
))) {
  throw new Error("OPENCLAW_ALLOWED_PLUGINS must be a JSON array of non-empty strings");
}

const allowedOrigins = ["http://localhost:18789", "http://127.0.0.1:18789"];
if (process.env.OPENCLAW_PUBLIC_URL) {
  allowedOrigins.push(validateHttpUrl(process.env.OPENCLAW_PUBLIC_URL, "OPENCLAW_PUBLIC_URL", true));
}

fs.mkdirSync(configDir, { recursive: true, mode: 0o700 });
fs.mkdirSync(path.dirname(configPath), { recursive: true, mode: 0o700 });
const cfg = loadExistingConfig();

const gateway = ensurePlainObject(cfg, "gateway", "gateway");
gateway.mode = "local";
gateway.bind = "lan";
const gatewayAuth = ensurePlainObject(gateway, "auth", "gateway.auth");
gatewayAuth.token = gatewayToken;
gatewayAuth.rateLimit = {
  maxAttempts: 10,
  windowMs: 60000,
  lockoutMs: 300000,
};
const controlUi = ensurePlainObject(gateway, "controlUi", "gateway.controlUi");
controlUi.allowedOrigins = allowedOrigins;

const models = ensurePlainObject(cfg, "models", "models");
models.providers = loadProviders();

const agents = ensurePlainObject(cfg, "agents", "agents");
const agentDefaults = ensurePlainObject(agents, "defaults", "agents.defaults");

const defaultModel = process.env.OPENCLAW_DEFAULT_MODEL || "";
if (defaultModel) {
  const defaultModelConfig = ensurePlainObject(agentDefaults, "model", "agents.defaults.model");
  defaultModelConfig.primary = defaultModel;
  const defaultModels = ensurePlainObject(agentDefaults, "models", "agents.defaults.models");
  if (defaultModels[defaultModel] !== undefined && !isPlainObject(defaultModels[defaultModel])) {
    throw new Error(`agents.defaults.models['${defaultModel}'] must be a JSON object`);
  }
  defaultModels[defaultModel] = defaultModels[defaultModel] || {};
}

// When OPENCLAW_ALLOWED_PLUGINS is set, enable exactly that list.
// When unset, plugins stay disabled -- unchanged from prior CSB behavior.
// plugins.allow gates installed/global plugins; stock bundled plugins (like
// openshell) are gated per-id via plugins.entries, same as skills.entries
// below -- confirmed empirically, `openclaw plugins list` still showed a
// stock plugin as "disabled" with only plugins.allow set.
const plugins = ensurePlainObject(cfg, "plugins", "plugins");
plugins.enabled = allowedPlugins !== null && allowedPlugins.length > 0;
plugins.allow = allowedPlugins || [];
plugins.deny = [];
const pluginEntries = ensurePlainObject(plugins, "entries", "plugins.entries");
for (const name of allowedPlugins || []) {
  pluginEntries[name] = { enabled: true };
}

const skills = ensurePlainObject(cfg, "skills", "skills");
skills.allowBundled = [];
const skillInstall = ensurePlainObject(skills, "install", "skills.install");
skillInstall.allowUploadedArchives = false;

// Disable all known bundled skills by name. allowBundled:[] is not enforced
// by this OpenClaw version, so we must disable each one explicitly.
// User-created workspace skills are unaffected by this list.
const skillEntries = ensurePlainObject(skills, "entries", "skills.entries");
const bundledSkillsToDisable = [
  "clawhub", "diagram-maker", "healthcheck", "meme-maker",
  "node-connect", "node-inspect-debugger", "notion",
  "openai-whisper-api", "skill-creator", "spike",
  "taskflow", "taskflow-inbox-triage", "weather",
];
for (const name of bundledSkillsToDisable) {
  skillEntries[name] = { enabled: false };
}

// When OPENCLAW_ALLOWED_SKILLS is set, restrict to that list.
// When unset, all workspace skills are available.
if (allowedSkills !== null) {
  agentDefaults.skills = allowedSkills;
}

const security = ensurePlainObject(cfg, "security", "security");
security.installPolicy = {
  enabled: true,
  targets: ["skill", "plugin"],
  exec: {
    source: "exec",
    command: "/usr/local/bin/openclaw-install-policy",
    timeoutMs: 10000,
    noOutputTimeoutMs: 10000,
    maxOutputBytes: 4096,
    trustedDirs: ["/usr/local/bin"],
  },
};

const tools = ensurePlainObject(cfg, "tools", "tools");
tools.deny = ["browser", "canvas", "web_fetch", "web_search"];
const execTools = ensurePlainObject(tools, "exec", "tools.exec");
execTools.mode = "full";
const elevatedTools = ensurePlainObject(tools, "elevated", "tools.elevated");
elevatedTools.enabled = false;
const filesystemTools = ensurePlainObject(tools, "fs", "tools.fs");
filesystemTools.workspaceOnly = true;

const gatewayHttp = ensurePlainObject(gateway, "http", "gateway.http");
const endpoints = ensurePlainObject(gatewayHttp, "endpoints", "gateway.http.endpoints");
const responses = ensurePlainObject(endpoints, "responses", "gateway.http.endpoints.responses");
const responseFiles = ensurePlainObject(responses, "files", "gateway.http.endpoints.responses.files");
responseFiles.allowUrl = true;
responseFiles.urlAllowlist = [
  "github.com", "*.github.com", "*.githubusercontent.com", "redhat.com", "*.redhat.com",
];
const responseImages = ensurePlainObject(responses, "images", "gateway.http.endpoints.responses.images");
responseImages.allowUrl = true;
responseImages.urlAllowlist = [
  "github.com", "*.github.com", "*.githubusercontent.com", "redhat.com", "*.redhat.com",
];

const hooks = ensurePlainObject(cfg, "hooks", "hooks");
hooks.enabled = false;
const cron = ensurePlainObject(cfg, "cron", "cron");
cron.enabled = true;
const discovery = ensurePlainObject(cfg, "discovery", "discovery");
const mdns = ensurePlainObject(discovery, "mdns", "discovery.mdns");
mdns.mode = "off";

atomicWrite(configPath, `${JSON.stringify(cfg, null, 2)}\n`, 0o600);
removeLegacyTokenFromEnv();
console.log(`[entrypoint] ${configPath} written atomically (CSB policy applied, mode 0600).`);
console.log(JSON.stringify({
  gateway: { mode: cfg.gateway.mode, bind: cfg.gateway.bind },
  plugins: cfg.plugins,
  agents: { skills: cfg.agents.defaults.skills },
  security: { installPolicy: cfg.security.installPolicy },
  tools: {
    deny: cfg.tools.deny,
    "exec.mode": cfg.tools.exec.mode,
    "elevated.enabled": cfg.tools.elevated.enabled,
    "fs.workspaceOnly": cfg.tools.fs.workspaceOnly,
  },
  "url.allowlist": cfg.gateway.http.endpoints.responses.files.urlAllowlist,
  skills: cfg.skills,
  hooks: cfg.hooks,
  cron: cfg.cron,
  discovery: cfg.discovery,
}, null, 2));
