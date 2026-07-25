#!/bin/sh
set -eu

for name in OPENAI_API_KEY ANTHROPIC_API_KEY; do
    eval "value=\${${name}:-}"
    if [ -n "${value}" ]; then
        echo "[entrypoint] ${name} must not be present in the OpenClaw Gateway sandbox" >&2
        exit 1
    fi
done

: "${OPENCLAW_GATEWAY_TOKEN:?OPENCLAW_GATEWAY_TOKEN is required}"
: "${OPENCLAW_OPENSHELL_WORKSPACE:?OPENCLAW_OPENSHELL_WORKSPACE is required}"
: "${OPENCLAW_OPENSHELL_WORKER_IMAGE:?OPENCLAW_OPENSHELL_WORKER_IMAGE is required}"

# OpenShell injects the sandbox-scoped client identity; keep it outside the
# image and make the CLI use the supervisor-mounted files directly.
if [ -n "${OPENCLAW_OPENSHELL_CA_FILE:-}" ] && [ -f "${OPENCLAW_OPENSHELL_CA_FILE}" ]; then
    export OPENSHELL_TLS_CA="${OPENCLAW_OPENSHELL_CA_FILE}"
elif [ -f /etc/openshell-tls/client/ca.crt ]; then
    export OPENSHELL_TLS_CA=/etc/openshell-tls/client/ca.crt
else
    export OPENSHELL_TLS_CA="${OPENSHELL_TLS_CA:-/etc/openshell/tls/client/ca.crt}"
fi
if [ -f /etc/openshell-tls/client/tls.crt ]; then
    export OPENSHELL_TLS_CERT=/etc/openshell-tls/client/tls.crt
else
    export OPENSHELL_TLS_CERT="${OPENSHELL_TLS_CERT:-/etc/openshell/tls/client/tls.crt}"
fi
if [ -f /etc/openshell-tls/client/tls.key ]; then
    export OPENSHELL_TLS_KEY=/etc/openshell-tls/client/tls.key
else
    export OPENSHELL_TLS_KEY="${OPENSHELL_TLS_KEY:-/etc/openshell/tls/client/tls.key}"
fi
if [ -n "${OPENCLAW_OPENSHELL_TOKEN_FILE:-}" ] && [ -f "${OPENCLAW_OPENSHELL_TOKEN_FILE}" ]; then
    export OPENSHELL_SANDBOX_TOKEN_FILE="${OPENCLAW_OPENSHELL_TOKEN_FILE}"
elif [ -f /var/run/secrets/openshell/token ]; then
    export OPENSHELL_SANDBOX_TOKEN_FILE=/var/run/secrets/openshell/token
elif [ -n "${OPENSHELL_SANDBOX_TOKEN_FILE:-}" ] && [ -f "${OPENSHELL_SANDBOX_TOKEN_FILE}" ]; then
    export OPENSHELL_SANDBOX_TOKEN_FILE
else
    unset OPENSHELL_SANDBOX_TOKEN_FILE OPENSHELL_SANDBOX_TOKEN
fi
export NO_PROXY="${NO_PROXY:-host.containers.internal,127.0.0.1,localhost}"
export no_proxy="${no_proxy:-${NO_PROXY}}"

export OPENCLAW_CONFIG_DIR="${OPENCLAW_STATE_DIR:-/sandbox/persist/.openclaw}"
export OPENCLAW_STATE_DIR="${OPENCLAW_CONFIG_DIR}"
export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_DIR}/openclaw.json"
export OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/sandbox/persist/workspace-main}"
# SQLite creates FTS shadow tables inside an immediate transaction during first
# Gateway startup. Keep its temporary files within the policy-approved /tmp.
export SQLITE_TMPDIR="${SQLITE_TMPDIR:-/tmp}"

mkdir -p "${OPENCLAW_CONFIG_DIR}" "${OPENCLAW_WORKSPACE_DIR}"
chmod 700 "${OPENCLAW_CONFIG_DIR}" "${OPENCLAW_WORKSPACE_DIR}"

node /app/csb/configure-session-workers.mjs

# The worker synchronizer requires a Git-backed Gateway workspace. This is
# created once, after skill upload but before the first Cloud session.
if ! git -C "${OPENCLAW_WORKSPACE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${OPENCLAW_WORKSPACE_DIR}" init -q
    git -C "${OPENCLAW_WORKSPACE_DIR}" add -A
    git -C "${OPENCLAW_WORKSPACE_DIR}" -c user.name=OpenClaw -c user.email=openshell-csb@localhost \
        commit --allow-empty -qm 'Initialize OpenClaw worker workspace'
fi

exec openclaw gateway --allow-unconfigured
