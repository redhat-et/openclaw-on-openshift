#!/bin/bash
# =============================================================================
# CSB Threat Model Validation
#
# Runs against a running openclaw-csb container to verify all security
# controls documented in the threat model are enforced.
#
# Usage:
#   ./scripts/validate-threat-model.sh [container-name]
#
# Default container name: openclaw-csb
# =============================================================================

set -uo pipefail

CONTAINER="${1:-openclaw-csb}"
# Detect config path — supports both /sandbox/.openclaw and /sandbox/persist/.openclaw
CONFIG_PATH=$(podman exec "$CONTAINER" bash -c 'for p in /sandbox/persist/.openclaw/openclaw.json ${CONFIG_PATH}; do [ -f "$p" ] && echo "$p" && exit; done' 2>/dev/null)
if [ -z "$CONFIG_PATH" ]; then
    echo "ERROR: Cannot find openclaw.json in container $CONTAINER"
    exit 1
fi
# Detect if running under OpenShell (podman exec enters as root)
EXEC_USER=$(podman exec "$CONTAINER" id -u 2>/dev/null)
IS_OPENSHELL=false
if [ "$EXEC_USER" = "0" ]; then
    IS_OPENSHELL=true
fi
PASS=0
FAIL=0
WARN=0

check() {
    local label="$1"
    local result="$2"
    local expected="$3"

    if echo "$result" | grep -qi "$expected"; then
        echo "PASS  $label"
        ((PASS++))
    else
        echo "FAIL  $label (got: $result)"
        ((FAIL++))
    fi
}

warn() {
    local label="$1"
    local detail="$2"
    echo "WARN  $label — $detail"
    ((WARN++))
}

info() {
    local label="$1"
    local detail="$2"
    echo "INFO  $label — $detail"
}

echo "============================================="
echo "CSB Threat Model Validation"
echo "Container: ${CONTAINER}"
echo "============================================="
echo ""

# Derive state dir from config path
STATE_DIR=$(dirname "$CONFIG_PATH")

# 1. Config immutability
echo "--- Config immutability (NIX_MODE) ---"
RESULT=$(podman exec -e OPENCLAW_STATE_DIR="$STATE_DIR" -e OPENCLAW_NIX_MODE=1 "$CONTAINER" node /app/dist/index.js config set plugins.enabled true 2>&1)
check "Config mutation blocked" "$RESULT" "immutable\|NixMode\|Nix\|readonly"

# 2. Plugins — disabled unless the container was started with a non-empty
# OPENCLAW_ALLOWED_PLUGINS array, in which case only the listed IDs may be
# enabled. Mirrors configure-openclaw.mjs's own rule exactly (unset or "[]"
# both mean disabled) so this check can't drift out of sync with it.
echo "--- Plugins ---"
ALLOWED_PLUGINS_ENV=$(podman exec "$CONTAINER" printenv OPENCLAW_ALLOWED_PLUGINS 2>/dev/null || echo "")
HAS_ALLOWED_PLUGINS=$(podman exec -e ALLOWED_PLUGINS_ENV="$ALLOWED_PLUGINS_ENV" "$CONTAINER" node -e "
const raw = process.env.ALLOWED_PLUGINS_ENV || '';
const parsed = raw ? JSON.parse(raw) : null;
console.log(parsed !== null && Array.isArray(parsed) && parsed.length > 0);
")
RESULT=$(podman exec "$CONTAINER" node -e "const c=JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));console.log(c.plugins?.enabled)")
if [ "$HAS_ALLOWED_PLUGINS" = "true" ]; then
    check "Plugins enabled (OPENCLAW_ALLOWED_PLUGINS set)" "$RESULT" "true"
    RESULT=$(podman exec -e ALLOWED_PLUGINS_ENV="$ALLOWED_PLUGINS_ENV" "$CONTAINER" node -e "
const c = JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));
const allowed = JSON.parse(process.env.ALLOWED_PLUGINS_ENV);
const entries = c.plugins?.entries || {};
const allEnabled = allowed.every((n) => entries[n]?.enabled === true);
const noExtra = Object.keys(entries).every((n) => entries[n].enabled !== true || allowed.includes(n));
console.log('allowedEnabled:' + allEnabled + ' noExtra:' + noExtra);
")
    check "Only allowlisted plugins enabled" "$RESULT" "allowedEnabled:true noExtra:true"
else
    check "Plugins disabled (no allowlist set)" "$RESULT" "false"
fi

# 3. Runtime install blocked
echo "--- Runtime install ---"
RESULT=$(podman exec -e OPENCLAW_STATE_DIR="$STATE_DIR" -e OPENCLAW_NIX_MODE=1 "$CONTAINER" node /app/dist/index.js plugins install slack 2>&1)
check "Plugin install blocked" "$RESULT" "immutable\|NixMode\|Nix\|readonly"

# 4. Install policy script
echo "--- Install policy ---"
RESULT=$(podman exec "$CONTAINER" /usr/local/bin/openclaw-install-policy 2>&1 | head -1)
check "Install policy returns block" "$RESULT" "block"

# 5. Exec mode
echo "--- Exec mode ---"
RESULT=$(podman exec "$CONTAINER" node -e "const c=JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));console.log(c.tools?.exec?.mode)")
check "Exec mode is full" "$RESULT" "full"

# 6. Denied tools
echo "--- Denied tools ---"
RESULT=$(podman exec "$CONTAINER" node -e "const c=JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));console.log(c.tools?.deny?.join(','))")
check "browser denied" "$RESULT" "browser"
check "canvas denied" "$RESULT" "canvas"
check "web_fetch denied" "$RESULT" "web_fetch"
check "web_search denied" "$RESULT" "web_search"

# 7. Filesystem
echo "--- Filesystem ---"
RESULT=$(podman exec "$CONTAINER" node -e "const c=JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));console.log(c.tools?.fs?.workspaceOnly)")
check "Filesystem workspace-only" "$RESULT" "true"

# 8. Elevated mode
echo "--- Elevated mode ---"
RESULT=$(podman exec "$CONTAINER" node -e "const c=JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));console.log(c.tools?.elevated?.enabled)")
check "Elevated disabled" "$RESULT" "false"

# 9. Non-root user (check the gateway process, not the exec shell)
echo "--- User identity ---"
if [ "$IS_OPENSHELL" = "true" ]; then
    RESULT=$(podman exec "$CONTAINER" bash -c 'stat -c %U /sandbox/.openclaw/openclaw.json 2>/dev/null || stat -c %U /sandbox/persist/.openclaw/openclaw.json 2>/dev/null || echo unknown')
    check "Config owned by sandbox user" "$RESULT" "sandbox"
    RESULT=$(podman exec "$CONTAINER" grep sandbox /etc/group)
    check "Sandbox group exists" "$RESULT" "sandbox"
else
    RESULT=$(podman exec "$CONTAINER" id)
    check "Non-root user (uid 1001)" "$RESULT" "uid=1001"
    # csb/Containerfile's base creates a "sandbox" group; the OpenClaw-only
    # variant (csb/Containerfile.openclaw) creates an "openclaw" group instead.
    check "Runtime group present (sandbox or openclaw)" "$RESULT" "sandbox\|openclaw"
fi

# 10. Config permissions
echo "--- Config file permissions ---"
RESULT=$(podman exec "$CONTAINER" stat -c '%a' ${CONFIG_PATH} 2>/dev/null || echo "unknown")
check "openclaw.json mode 600" "$RESULT" "600"

# 11. Hooks and cron
echo "--- Hooks and cron ---"
RESULT=$(podman exec "$CONTAINER" node -e "const c=JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));console.log('hooks:'+c.hooks?.enabled+' cron_denied:'+c.tools?.deny?.includes('cron'))")
check "Hooks disabled" "$RESULT" "hooks:false"
check "Cron available (not denied)" "$RESULT" "cron_denied:false"

# 12. mDNS
echo "--- mDNS ---"
RESULT=$(podman exec "$CONTAINER" node -e "const c=JSON.parse(require('fs').readFileSync('${CONFIG_PATH}'));console.log(c.discovery?.mdns?.mode)")
check "mDNS disabled" "$RESULT" "off"

# 13. Bundled skills disabled
echo "--- Skills visibility ---"
RESULT=$(podman exec -e OPENCLAW_STATE_DIR="$STATE_DIR" "$CONTAINER" node /app/dist/index.js skills list --json 2>/dev/null | grep -v "^Config \|^\\[" | node -e "
const data=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const visible=(data.skills||[]).filter(s=>s.modelVisible);
const bundled=visible.filter(s=>s.bundled);
const workspace=visible.filter(s=>!s.bundled);
console.log('bundled:'+bundled.length+' workspace:'+workspace.length);
")
check "Zero bundled skills visible" "$RESULT" "bundled:0"

# 14. Write outside workspace
echo "--- Filesystem write restrictions ---"
if [ "$IS_OPENSHELL" = "true" ]; then
    # Under OpenShell, podman exec enters as root. Test as sandbox user instead.
    RESULT=$(podman exec "$CONTAINER" bash -c 'su -s /bin/sh sandbox -c "touch /etc/test 2>&1" && echo writable || echo denied')
    check "/etc not writable (as sandbox)" "$RESULT" "denied"
    RESULT=$(podman exec "$CONTAINER" bash -c 'su -s /bin/sh sandbox -c "touch /app/test 2>&1" && echo writable || echo denied')
    check "/app not writable (as sandbox)" "$RESULT" "denied"
else
    RESULT=$(podman exec "$CONTAINER" bash -c 'touch /etc/test 2>&1 && echo writable || echo denied')
    check "/etc not writable" "$RESULT" "denied"
    RESULT=$(podman exec "$CONTAINER" bash -c 'touch /app/test 2>&1 && echo writable || echo denied')
    check "/app not writable" "$RESULT" "denied"
fi

# 15. Network egress (bare podman)
echo "--- Network egress (bare podman) ---"
RESULT=$(podman exec "$CONTAINER" bash -c 'curl -sf --max-time 5 https://example.com >/dev/null 2>&1 && echo reachable || echo blocked')
if [ "$RESULT" = "reachable" ]; then
    info "Egress reachable" "expected without OpenShell; csb/policy.yaml enforces deny-by-default with OpenShell"
else
    info "Egress blocked" "network may already be restricted"
fi

# 16. Gateway health
echo "--- Gateway ---"
RESULT=$(curl -sf http://localhost:18789/healthz 2>&1 || echo "not responding")
check "Gateway healthy" "$RESULT" "ok"

echo ""
echo "============================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
