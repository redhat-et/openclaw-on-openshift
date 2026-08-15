# Manual OpenShell setup

Use this guide when you want to inspect or run each deployment action yourself.
For the shorter supported path, use the [README Quickstart](../README.md#quickstart).

Run commands from the repository root after completing the README prerequisites
and [creating credential providers](../README.md#1-create-credential-providers).

## 1. Create persistent storage and a gateway token

The named Podman volume survives sandbox recreation and keeps OpenClaw state,
device pairing, conversations, and workspace skills.

```bash
podman network create --ignore openshell
podman volume create openclaw-csb-data
podman run --rm \
  --user 0 \
  --entrypoint /bin/sh \
  -v openclaw-csb-data:/data \
  quay.io/redhat-et/openclaw:csb-latest \
  -c 'chmod 0777 /data'

OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
printf 'Save this OpenClaw gateway token in an approved secret store: %s\n' \
  "$OPENCLAW_GATEWAY_TOKEN"
```

## 2. Create the policy-backed sandbox

This example starts without a model or data provider. Add only the `--provider`
flags and non-secret model configuration needed for your setup. It leaves
workspace skills unrestricted; add
`--env 'OPENCLAW_ALLOWED_SKILLS=["team-prs"]'` to restrict the visible skills.

```bash
openshell sandbox create \
  --name openclaw-csb \
  --from quay.io/redhat-et/openclaw:csb-latest \
  --cpu 2 \
  --memory 4Gi \
  --policy csb/policy.yaml \
  --driver-config-json '{"podman":{"mounts":[{"type":"volume","source":"openclaw-csb-data","target":"/sandbox/persist","read_only":false}]}}' \
  --env OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
  --env OPENCLAW_STATE_DIR=/sandbox/persist/.openclaw \
  --env OPENCLAW_WORKSPACE_DIR=/sandbox/persist/workspace \
  --env OPENCLAW_WIDGET_PORT=18790 \
  -- /bin/true

unset OPENCLAW_GATEWAY_TOKEN
```

If the sandbox name is already in use, remove it with
`openshell sandbox delete openclaw-csb`. The volume remains intact.

## 3. Upload skills

The default demonstration skill must exist in the persistent workspace:

```bash
openshell sandbox exec -n openclaw-csb -- \
  mkdir -p /sandbox/persist/workspace/skills
openshell sandbox upload openclaw-csb \
  skills/team-prs \
  /sandbox/persist/workspace/skills
```

If the sandbox uses the brokered Google Workspace provider, copy the image-owned `gog`
and Google Workspace dashboard skills into the workspace so workspace-scoped
agent readers can load them:

```bash
openshell sandbox exec -n openclaw-csb --no-tty -- \
  rm -rf /sandbox/persist/workspace/skills/gog
openshell sandbox exec -n openclaw-csb --no-tty -- \
  cp -R /app/skills/gog /sandbox/persist/workspace/skills
openshell sandbox exec -n openclaw-csb --no-tty -- \
  rm -rf /sandbox/persist/workspace/skills/google-workspace-dashboard
openshell sandbox exec -n openclaw-csb --no-tty -- \
  cp -R /app/skills/google-workspace-dashboard /sandbox/persist/workspace/skills
```

## 4. Start OpenClaw and the loopback forward

```bash
openshell sandbox exec -n openclaw-csb -- \
  /app/entrypoint.sh >/dev/null 2>&1 &
until openshell sandbox exec -n openclaw-csb -- \
  curl -fsS http://127.0.0.1:18789/healthz 2>/dev/null; do sleep 1; done
OPENSHELL_GATEWAY_NAME="${OPENSHELL_GATEWAY:-openshell}"
OPENSHELL_WORKSPACE_NAME="${OPENSHELL_WORKSPACE:-default}"
ssh -f -N -M -S /tmp/openclaw-csb-${UID}-openclaw-csb.sock \
  -o "ProxyCommand=$(command -v openshell) ssh-proxy --gateway-name ${OPENSHELL_GATEWAY_NAME} --name openclaw-csb --workspace ${OPENSHELL_WORKSPACE_NAME}" \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -L 127.0.0.1:18789:127.0.0.1:18789 \
  -L 127.0.0.1:18790:127.0.0.1:18790 \
  sandbox >/tmp/openclaw-csb-forward.log 2>&1 </dev/null
```

The SSH forward binds both ports to loopback only and uses OpenShell's
credential-safe `ssh-proxy` name mode; no session token is written to the
command line or repository. The native-widget listener starts lazily
when the first HTML widget is admitted, so its forward may initially report
connection-refused retries. Native widgets do not require MCP Apps to be
enabled. If either local port is occupied, stop the process using it or choose
another local port and configure the matching sandbox port.

Stop this forward with:

```bash
ssh -S /tmp/openclaw-csb-${UID}-openclaw-csb.sock -O exit sandbox
```

## 5. Access the Control UI

Open `http://localhost:18789` and paste the token saved in step 1.
