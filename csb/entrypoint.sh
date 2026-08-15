#!/bin/bash
# =============================================================================
# OpenClaw CSB entrypoint — locked-down "naked claw" for Corporate Standard Build
#
# This entrypoint enforces a hardened configuration on every startup:
#   - All plugins disabled (plugins.enabled=false, empty allowlist)
#   - Only explicitly allowlisted workspace skills are visible
#   - Runtime skill and plugin installation blocked by operator policy
#   - Shell execution retained behind OpenClaw approval
#   - Filesystem restricted to workspace
#   - Config immutability via OPENCLAW_NIX_MODE=1
#   - mDNS discovery disabled
#
# The config is written fresh on every startup and cannot be modified
# at runtime. This is intentional — the CSB policy is always restored.
#
# Credentials can be provided via environment variables OR podman secrets:
#
#   Environment variables:
#     OPENCLAW_GATEWAY_TOKEN  — shared secret for the Control UI
#     <PROVIDER>_API_KEY      — the actual AI provider key
#
#   Podman secrets (mounted at /run/secrets/<name>):
#     openclaw-gateway-token  → read into OPENCLAW_GATEWAY_TOKEN
#     openai-api-key          → read into OPENAI_API_KEY
#     anthropic-api-key       → read into ANTHROPIC_API_KEY
#     google-api-key          → read into GOOGLE_API_KEY
#     xai-api-key             → read into XAI_API_KEY
#     mistral-api-key         → read into MISTRAL_API_KEY
#     cohere-api-key          → read into COHERE_API_KEY
#
#   Usage:
#     echo -n "sk-..." | podman secret create openai-api-key -
#     echo -n "$(openssl rand -hex 32)" | podman secret create openclaw-gateway-token -
#     podman run --secret openai-api-key --secret openclaw-gateway-token ...
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Read podman secrets from /run/secrets/ if env vars are not set.
# Podman mounts secrets as files at /run/secrets/<secret-name>.
# ---------------------------------------------------------------------------
read_secret() {
    local env_var="$1"
    local secret_name="$2"
    local secret_file="/run/secrets/${secret_name}"
    if [[ -z "${!env_var:-}" ]] && [[ -f "${secret_file}" ]]; then
        export "${env_var}=$(cat "${secret_file}")"
        echo "[entrypoint] Loaded ${env_var} from podman secret '${secret_name}'"
    fi
}

read_secret OPENCLAW_GATEWAY_TOKEN  openclaw-gateway-token
read_secret OPENAI_API_KEY          openai-api-key
read_secret ANTHROPIC_API_KEY       anthropic-api-key
read_secret GOOGLE_API_KEY          google-api-key
read_secret XAI_API_KEY             xai-api-key
read_secret MISTRAL_API_KEY         mistral-api-key
read_secret COHERE_API_KEY          cohere-api-key

CONFIG_DIR="${OPENCLAW_STATE_DIR:-${OPENCLAW_CONFIG_DIR:-${HOME}/.openclaw}}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-${HOME}/workspace}"
export OPENCLAW_CONFIG_DIR="${CONFIG_DIR}"
export OPENCLAW_STATE_DIR="${CONFIG_DIR}"
export OPENCLAW_CONFIG_PATH="${CONFIG_DIR}/openclaw.json"
export OPENCLAW_WORKSPACE_DIR="${WORKSPACE_DIR}"
# SQLite probes /var/tmp before /tmp when TMPDIR is unset. OpenShell only grants
# this sandbox write access to /tmp, so direct SQLite temporary files there.
export TMPDIR=/tmp

mkdir -p "${CONFIG_DIR}" "${WORKSPACE_DIR}"
chmod 700 "${CONFIG_DIR}" "${WORKSPACE_DIR}"

echo "[entrypoint] Starting OpenClaw gateway (CSB policy)..."
echo "[entrypoint] Config dir:    ${CONFIG_DIR}  (HOME=${HOME})"
echo "[entrypoint] Workspace dir: ${WORKSPACE_DIR}"

if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_TOKEN is required on every startup." >&2
    echo "[entrypoint]        Provide it via -e or --secret openclaw-gateway-token." >&2
    exit 1
fi

echo "[entrypoint] Validating inputs and atomically writing CSB policy config..."
node /app/configure-openclaw.mjs

# ---------------------------------------------------------------------------
# Start the gateway with config immutability
# OPENCLAW_NIX_MODE=1 prevents runtime modification of openclaw.json
# ---------------------------------------------------------------------------
echo "[entrypoint] Launching OpenClaw gateway (NIX_MODE=1, port 18789)..."
export OPENCLAW_NIX_MODE=1
exec openclaw gateway --allow-unconfigured
