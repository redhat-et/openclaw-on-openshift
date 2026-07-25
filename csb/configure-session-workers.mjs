#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function optional(name, fallback) {
  return process.env[name]?.trim() || fallback;
}

function readConfig(configPath) {
  if (!fs.existsSync(configPath)) return {};
  const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${configPath} must contain a JSON object`);
  }
  return parsed;
}

function writeConfig(configPath, config) {
  const temporary = `${configPath}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, configPath);
  fs.chmodSync(configPath, 0o600);
}

if (process.env.OPENAI_API_KEY || process.env.ANTHROPIC_API_KEY) {
  throw new Error("model-provider credentials must stay in the OpenShell workspace provider");
}

const configDir = required("OPENCLAW_CONFIG_DIR");
const configPath = process.env.OPENCLAW_CONFIG_PATH || path.join(configDir, "openclaw.json");
const workspaceDir = required("OPENCLAW_WORKSPACE_DIR");
const gatewayToken = required("OPENCLAW_GATEWAY_TOKEN");
const openShellWorkspace = required("OPENCLAW_OPENSHELL_WORKSPACE");
const workerImage = required("OPENCLAW_OPENSHELL_WORKER_IMAGE");
const controlUiPort = Number.parseInt(process.env.OPENCLAW_OPENSHELL_CONTROL_UI_PORT || "18791", 10);
const provider = optional("OPENCLAW_OPENSHELL_INFERENCE_PROVIDER", "openai");
const openClawProvider = optional("OPENCLAW_OPENSHELL_OPENCLAW_PROVIDER", "openai");
const model = optional("OPENCLAW_OPENSHELL_INFERENCE_MODEL", "gpt-5.5");
const api = optional("OPENCLAW_OPENSHELL_INFERENCE_API", "openai-responses");
const publicUrl = optional("OPENCLAW_PUBLIC_URL", "");

if (api !== "openai-responses" && api !== "openai-completions" && api !== "anthropic-messages") {
  throw new Error("OPENCLAW_OPENSHELL_INFERENCE_API must be an OpenClaw-supported inference API");
}
if (!Number.isInteger(controlUiPort) || controlUiPort < 1 || controlUiPort > 65_535) {
  throw new Error("OPENCLAW_OPENSHELL_CONTROL_UI_PORT must be a valid TCP port");
}

fs.mkdirSync(configDir, { recursive: true, mode: 0o700 });
const config = readConfig(configPath);
const inferenceBaseUrl = api === "anthropic-messages" ? "https://inference.local" : "https://inference.local/v1";
const workerSettings = {
  mode: "remote",
  command: optional("OPENCLAW_OPENSHELL_COMMAND", "openshell"),
  gatewayEndpoint: optional("OPENCLAW_OPENSHELL_GATEWAY_ENDPOINT", process.env.OPENSHELL_ENDPOINT),
  workspace: openShellWorkspace,
  from: workerImage,
  policy: optional("OPENCLAW_OPENSHELL_WORKER_POLICY", undefined),
  autoProviders: false,
  remoteWorkspaceDir: "/sandbox",
  remoteAgentWorkspaceDir: "/sandbox/agent",
  inference: { mode: "local", provider, openclawProvider: openClawProvider, model, api },
};

config.gateway = {
  ...(config.gateway || {}),
  mode: "local",
  bind: "lan",
  port: controlUiPort,
  auth: {
    ...(config.gateway?.auth || {}),
    token: gatewayToken,
    rateLimit: { maxAttempts: 10, windowMs: 60_000, lockoutMs: 300_000 },
  },
  controlUi: {
    ...(config.gateway?.controlUi || {}),
    allowedOrigins: [
      `http://localhost:${controlUiPort}`,
      `http://127.0.0.1:${controlUiPort}`,
      ...(publicUrl ? [publicUrl.replace(/\/$/, "")] : []),
    ],
  },
};
config.models = {
  ...(config.models || {}),
  providers: {
    ...(config.models?.providers || {}),
    [openClawProvider]: {
      api,
      baseUrl: inferenceBaseUrl,
      apiKey: "unused",
      models: [{ id: model, name: model }],
    },
  },
};
config.agents = {
  ...(config.agents || {}),
  defaults: {
    ...(config.agents?.defaults || {}),
    workspace: workspaceDir,
    model: { ...(config.agents?.defaults?.model || {}), primary: `${openClawProvider}/${model}` },
  },
  entries: {
    ...(config.agents?.entries || {}),
    main: { ...(config.agents?.entries?.main || {}), default: true, workspace: workspaceDir },
  },
};
config.plugins = {
  ...(config.plugins || {}),
  allow: ["openshell"],
  entries: {
    ...(config.plugins?.entries || {}),
    openshell: { enabled: true, config: { ...workerSettings, inference: undefined } },
  },
};
config.cloudWorkers = {
  ...(config.cloudWorkers || {}),
  profiles: {
    ...(config.cloudWorkers?.profiles || {}),
    openshell: { provider: "openshell", install: "bundle", settings: workerSettings },
  },
};
config.skills = {
  ...(config.skills || {}),
  allowBundled: [],
  install: { ...(config.skills?.install || {}), allowUploadedArchives: false },
};
config.security = {
  ...(config.security || {}),
  installPolicy: {
    enabled: true,
    targets: ["skill", "plugin"],
    exec: {
      source: "exec",
      command: "/usr/local/bin/openclaw-install-policy",
      timeoutMs: 10_000,
      noOutputTimeoutMs: 10_000,
      maxOutputBytes: 4096,
      trustedDirs: ["/usr/local/bin"],
    },
  },
};
config.tools = {
  ...(config.tools || {}),
  deny: ["browser", "canvas", "web_fetch", "web_search"],
  exec: { ...(config.tools?.exec || {}), mode: "full" },
  elevated: { ...(config.tools?.elevated || {}), enabled: false },
  fs: { ...(config.tools?.fs || {}), workspaceOnly: true },
};
config.hooks = { ...(config.hooks || {}), enabled: false };
config.discovery = { ...(config.discovery || {}), mdns: { ...(config.discovery?.mdns || {}), mode: "off" } };

writeConfig(configPath, config);
console.log(`[entrypoint] wrote ${configPath}; OpenShell worker profile targets ${openShellWorkspace}`);
