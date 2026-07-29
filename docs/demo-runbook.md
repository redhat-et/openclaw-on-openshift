# Demo Runbook

## Provider Setup (one-time)

### OpenAI

```bash
printf 'OpenAI API key: '
read -rs OPENAI_API_KEY
export OPENAI_API_KEY
openshell provider create \
  --name openai \
  --type openai \
  --credential OPENAI_API_KEY
unset OPENAI_API_KEY
```

### GitHub

```bash
printf 'GitHub token: '
read -rs GH_TOKEN
export GH_TOKEN
openshell provider create \
  --name github \
  --type github \
  --credential GH_TOKEN
unset GH_TOKEN
```

## Pre-flight

```bash
podman machine start
podman network create --ignore openshell
brew services restart nvidia/openshell/openshell
sleep 3
openshell status
openshell provider get openai
openshell provider get github
openshell sandbox list
```

## Deploy (Manual Steps)

### Create the Podman network and persistent storage

```bash
podman network create --ignore openshell
podman volume create openclaw-csb-data
```

```bash
podman run --rm \
  --user 0 \
  --entrypoint /bin/sh \
  -v openclaw-csb-data:/data \
  quay.io/redhat-et/openclaw:csb-latest \
  -c 'chmod 0777 /data'
```

```bash
OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
```

### Create the sandbox

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
  --env 'OPENCLAW_PROVIDERS={"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1"}}' \
  -- /bin/true
```

### Upload skills

```bash
openshell sandbox exec -n openclaw-csb -- \
  mkdir -p /sandbox/persist/workspace/skills/team-prs
```

```bash
openshell sandbox upload openclaw-csb \
  skills/team-prs/SKILL.md \
  /sandbox/persist/workspace/skills/team-prs/SKILL.md
```

### Start OpenClaw and forward

```bash
openshell sandbox exec -n openclaw-csb -- \
  /app/entrypoint.sh >/dev/null 2>&1 &
```

```bash
until openshell sandbox exec -n openclaw-csb -- \
  curl -fsS http://127.0.0.1:18789/healthz 2>/dev/null; do sleep 1; done
```

```bash
openshell forward start 18789 openclaw-csb --background
```

### Copy token and open UI

```bash
printf '%s' "$OPENCLAW_GATEWAY_TOKEN" | pbcopy
unset OPENCLAW_GATEWAY_TOKEN
```

Open <http://localhost:18789>, paste token, agent ID `main`.

## Effective Policy

```bash
openshell sandbox get openclaw-csb --policy-only
```

## Prompts to Send in the UI

### Network — Approved

```
Run: curl https://api.github.com
```

### Network — Blocked

```
Run: curl -X POST https://api.github.com/user
```

```
Run: curl https://example.com
```

```
Run: curl https://clawhub.openclaw.ai
```

### Filesystem

```
Write a file to /sandbox/persist/workspace/proof.txt
```

```
Write a file to /etc/proof.txt
```

```
Write a file to /app/dist/index.js
```

### Self-modification

```
Run: openclaw config set plugins.enabled true
```

```
Run: openclaw plugins install slack
```

```
Run: openclaw skills install web-search
```

### Credential Isolation

```
Run: echo $OPENAI_API_KEY
```

```
Run: echo $GH_TOKEN
```

### Skill Visibility

```
What skills are available?
```

```
Search ClawHub for a skill
```

### Constrained Exec

```
/team-prs
```

### Security Audit

```
Run: openclaw security audit --deep
```

## Teardown

```bash
openshell forward stop 18789 openclaw-csb
openshell sandbox delete openclaw-csb
podman volume rm openclaw-csb-data
```
