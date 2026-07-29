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

This command leaves workspace skills unrestricted. Add
`--env 'OPENCLAW_ALLOWED_SKILLS=["team-prs"]'` to restrict the visible skills.

```bash
openshell sandbox create \
  --name openclaw-csb \
  --from quay.io/redhat-et/openclaw:csb-latest \
  --cpu 2 \
  --memory 4Gi \
  --policy csb/policy.yaml \
  --provider openai \
  --provider github \
  --driver-config-json '{"podman":{"mounts":[{"type":"volume","source":"openclaw-csb-data","target":"/sandbox/persist","read_only":false}]}}' \
  --env OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
  --env OPENCLAW_STATE_DIR=/sandbox/persist/.openclaw \
  --env OPENCLAW_WORKSPACE_DIR=/sandbox/persist/workspace \
  --env OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5 \
  --env OPENCLAW_PROVIDERS='{"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1"}}' \
  -- /bin/true

unset OPENCLAW_GATEWAY_TOKEN
```

If the sandbox name is already in use, remove it with
`openshell sandbox delete openclaw-csb`. The volume remains intact.

## 3. Upload skills

The default demonstration skill must exist in the persistent workspace:

```bash
openshell sandbox exec -n openclaw-csb -- \
  mkdir -p /sandbox/persist/workspace/skills/team-prs
openshell sandbox upload openclaw-csb \
  skills/team-prs/SKILL.md \
  /sandbox/persist/workspace/skills/team-prs/SKILL.md
```

## 4. Start OpenClaw and the loopback forward

```bash
openshell sandbox exec -n openclaw-csb -- \
  /app/entrypoint.sh >/dev/null 2>&1 &
until openshell sandbox exec -n openclaw-csb -- \
  curl -fsS http://127.0.0.1:18789/healthz 2>/dev/null; do sleep 1; done
openshell forward start 18789 openclaw-csb --background
```

The forward binds to loopback only. If port 18789 is occupied, stop the process
using it or choose another local port.

## 5. Access the Control UI

Open `http://localhost:18789` and paste the token saved in step 1.
