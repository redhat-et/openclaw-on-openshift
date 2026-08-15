# OpenClaw CSB: zero to hero

This guide starts with a new macOS or Fedora/RHEL workstation: no repository
clone, no OpenShell installation, and no existing sandbox. At the end, you
will have:

- a local OpenShell gateway backed by Podman;
- an OpenClaw sandbox governed by this repository's policy;
- one model credential held by OpenShell rather than stored in the sandbox;
- brokered Gmail read-only access plus Calendar read/write access
  through `gog`;
- the OpenClaw Control UI available only on `http://127.0.0.1:18789`; and
- commands to stop, start, and restart the OpenClaw gateway without deleting
  its state.

The setup uses one OpenAI, Anthropic, or Gemini API key plus the brokered Google
Workspace provider. Before starting Quickstart, complete the Google OAuth client
and `gog` provider steps in
[Mrunal's Gmail setup guide](https://docs.google.com/document/d/1PZUo4BbUtiYXStOOL3bQJgneKDHr0H-st5ow_RaSlXk/edit?usp=sharing).

> This guide follows the `feature/brokered-gmail-openai` branch. Until an image
> built from that branch is published, build the image locally as shown below.

## 1. Install the host prerequisites

You need Git, Podman, OpenSSL, `curl`, a host secret store, and a clipboard
command. You do not need to install OpenClaw or Node.js on the host.

### macOS

Install [Homebrew](https://brew.sh/) if it is not already available, then run:

```bash
brew install git podman openssl
podman machine init --cpus 4 --memory 12288 --disk-size 100 --now
```

If a Podman machine already exists, use `podman machine start` instead of
creating another one. macOS already provides the Keychain `security` command
and `pbcopy`.

### Fedora or RHEL

```bash
sudo dnf install -y git podman openssl curl libsecret wl-clipboard
```

If the Linux desktop does not use Wayland, install `xclip` instead of
`wl-clipboard`.

Verify Podman before continuing:

```bash
podman version
podman info
```

## 2. Install and start OpenShell

Install the version currently required by this branch:

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh \
  | OPENSHELL_VERSION=v0.0.106 sh
```

Configure the local gateway to use Podman explicitly:

```bash
mkdir -p "$HOME/.config/openshell"
printf '%s\n' \
  '[openshell]' \
  'version = 1' \
  '' \
  '[openshell.gateway]' \
  'compute_drivers = ["podman"]' \
  >"$HOME/.config/openshell/gateway.toml"
```

Restart the OpenShell gateway:

```bash
# macOS
brew services restart nvidia/openshell/openshell

# Linux: run this instead of the macOS command
# systemctl --user restart openshell-gateway
```

Verify the connection:

```bash
openshell --version
openshell gateway list
openshell status
```

Do not continue until `openshell status` reports `Connected`.

## 3. Clone this branch

```bash
git clone https://github.com/redhat-et/openclaw-csb.git
cd openclaw-csb
git switch feature/brokered-gmail-openai
```

All remaining commands run from the repository root.

## 4. Build the exact branch image

The build is the slowest one-time step. It compiles OpenClaw and includes the
OpenAI, Codex, Anthropic, Google, and `gog` components used by the optional
provider helpers.

```bash
podman build \
  --file csb/Containerfile \
  --tag localhost/openclaw-demo:readonly-gmail \
  .
```

Verify the image exists:

```bash
podman image inspect localhost/openclaw-demo:readonly-gmail >/dev/null
```

If the team publishes a matching multi-architecture image, this entire build
step can be replaced by `podman pull <published-image>` and that image name can
be used as `OPENCLAW_CSB_IMAGE` below.

## 5. Prepare Google Workspace and one model provider

Complete
[Mrunal's Gmail setup guide](https://docs.google.com/document/d/1PZUo4BbUtiYXStOOL3bQJgneKDHr0H-st5ow_RaSlXk/edit?usp=sharing)
before continuing. It covers the Google Cloud project, Desktop OAuth client,
`gog` authorization, and OpenShell refresh configuration. Enable the Gmail and
Google Calendar APIs, then authorize `gog` with the mixed
access required by this profile:

```bash
gog auth add <your-email> \
  --services gmail,calendar \
  --gmail-scope readonly \
  --force-consent
```

Do not add the global `--readonly` flag: it would also make Calendar read-only.
Create the OpenShell provider instance as `gog-google-workspace` with type
`google-workspace-gog`, using the client ID, client secret, and newly issued
refresh token from the setup flow.

Verify that the provider is ready:

```bash
openshell provider refresh status gog-google-workspace
```

Do not continue until its status is `refreshed` and it has no refresh error.
The OAuth client secret and refresh token must remain at the OpenShell gateway;
do not copy them into this repository or the OpenClaw sandbox.

Choose exactly one of the following paths. OpenShell stores the real API key
at the gateway. The OpenAI path routes through `inference.local`, so its key is
not injected into the sandbox; the other provider paths use scoped credential
placeholders for authorized requests.

First enable provider-profile policy composition:

```bash
openshell settings set --global \
  --key providers_v2_enabled \
  --value true
```

### Option A: OpenAI

The `openai-api-key` helper currently selects `openai/gpt-5.6-sol`. Confirm
that the API key can use that model, or change the helper before deployment.

```bash
printf 'OpenAI API key: '
read -rs OPENAI_API_KEY
printf '\n'
export OPENAI_API_KEY
openshell provider create \
  --name openai \
  --type openai \
  --credential OPENAI_API_KEY
unset OPENAI_API_KEY
```

The corresponding Quickstart option is `--with openai-api-key`. It configures
the workspace route to `openai/gpt-5.6-sol` and points OpenClaw at
`https://inference.local/v1`; it does not attach the provider to the sandbox.

### Option B: Anthropic

The `anthropic-api-key` helper currently selects
`anthropic/claude-opus-4-8`.

```bash
openshell provider profile lint --file csb/providers/anthropic-api-key.yaml
openshell provider profile import --file csb/providers/anthropic-api-key.yaml

printf 'Anthropic API key: '
read -rs ANTHROPIC_API_KEY
printf '\n'
export ANTHROPIC_API_KEY
openshell provider create \
  --name anthropic \
  --type anthropic-api-key \
  --credential ANTHROPIC_API_KEY
unset ANTHROPIC_API_KEY
```

The corresponding Quickstart option is `--with anthropic-api-key`.

### Option C: Gemini

The `gemini` helper currently selects `google/gemini-3.5-flash`.

```bash
openshell provider profile lint --file csb/providers/google-gemini-openclaw.yaml
openshell provider profile import --file csb/providers/google-gemini-openclaw.yaml

printf 'Gemini API key: '
read -rs GEMINI_API_KEY
printf '\n'
export GEMINI_API_KEY
openshell provider create \
  --name gemini \
  --type google-gemini-openclaw \
  --credential GEMINI_API_KEY
unset GEMINI_API_KEY
```

The corresponding Quickstart option is `--with gemini`.

Verify that Google Workspace and the selected model provider both exist without displaying
their secrets:

```bash
openshell provider list
```

## 6. Run Quickstart

Set the image built in step 4 and run Quickstart with Google Workspace plus the model
option selected in step 5. This example uses OpenAI:

```bash
export OPENCLAW_CSB_IMAGE=localhost/openclaw-demo:readonly-gmail
./scripts/openclaw-csb quickstart \
  --with google-workspace \
  --with openai-api-key
```

For another model provider, replace the final option:

```bash
# Anthropic
./scripts/openclaw-csb quickstart \
  --with google-workspace \
  --with anthropic-api-key

# Gemini
./scripts/openclaw-csb quickstart \
  --with google-workspace \
  --with gemini
```

Quickstart performs these actions:

1. creates the Podman network and persistent volume when missing;
2. creates a Control UI token and stores it in the host keyring;
3. creates the policy-backed OpenShell sandbox;
4. attaches Google Workspace and configures the selected model provider;
5. uploads the repository's workspace skills and copies the image-owned `gog`
   and Google Workspace dashboard skills into the workspace;
6. starts the OpenClaw gateway; and
7. starts one background SSH loopback forward for the Control UI on `18789`
   and the native-widget sandbox on `18790`.

It is safe to run the same Quickstart command again. An existing sandbox is
reused rather than recreated.

Verify the result:

```bash
./scripts/openclaw-csb gateway status
curl -fsS http://127.0.0.1:18789/healthz
```

The widget listener starts lazily after the first native HTML widget is
admitted, so the `18790` forward may initially log connection-refused retries.
MCP Apps remain disabled. If `18790` is already occupied, export a free
`OPENCLAW_CSB_WIDGET_PORT` before sandbox creation and later Quickstart runs.

## 7. Open the UI and complete the first conversation

Copy the current gateway token immediately before opening the UI:

```bash
./scripts/openclaw-csb token-copy
```

Open <http://127.0.0.1:18789>, paste the token, and connect. Then send a small
prompt that exercises the model without requiring another service:

```text
Introduce yourself in one sentence, then create a file named hello.txt in the
workspace containing today's date.
```

Success means the assistant answers and `/sandbox/persist/workspace/hello.txt`
is created. At this point the base setup is operational.

## 8. Verify brokered Google Workspace access

Google Workspace is deliberately separate from the model provider. The sandbox receives
only a short-lived `GOG_ACCESS_TOKEN`; the OAuth client secret and refresh
token remain at the OpenShell gateway. The provider permits only the bundled
`/usr/local/bin/gog` binary to access Gmail read-only and Calendar
read/write. Test each boundary with these prompts:

```text
Using gog in read-only mode, summarize my five newest unread emails. Do not
modify, label, archive, delete, draft, reply to, or send anything.
```

```text
Using gog, show today's calendar. Then propose a 15-minute test meeting for
tomorrow, but do not create it until I explicitly confirm the final details.
```

After reviewing the proposed meeting, explicitly confirm it and verify that it
appears on the calendar. Gmail mutations and all Drive access should remain
blocked by OpenShell even if the agent attempts them.

If OpenShell rotates the Google access token but the long-running OpenClaw
process cannot resolve the new credential revision, use the temporary
workaround:

```bash
./scripts/openclaw-csb gateway restart
```

The restart preserves the sandbox, UI forward, conversations, and persistent
workspace.

## 9. Daily operation

Check or restart only the OpenClaw gateway:

```bash
./scripts/openclaw-csb gateway status
./scripts/openclaw-csb gateway restart
```

Put OpenClaw to rest without deleting its state:

```bash
./scripts/openclaw-csb gateway stop
```

Resume it later:

```bash
./scripts/openclaw-csb gateway start
```

If the host or Podman machine was restarted, running the original Quickstart
command is the simplest recovery path. It recreates missing local forwarding
while reusing the existing sandbox and persistent state.

## 10. Change providers, plugins, or sandbox policy

Provider attachments, plugin selection, and sandbox policy are fixed when the
sandbox is created. To change them, delete only the sandbox and rerun
Quickstart with the new options:

```bash
openshell sandbox delete openclaw-csb
./scripts/openclaw-csb quickstart \
  --with google-workspace \
  --with <model-option>
```

The named Podman volume is preserved, so OpenClaw state survives sandbox
recreation. Do not remove `openclaw-csb-data` unless you intentionally want a
complete reset.

## Current onboarding gaps

These are product gaps, not extra steps a new user should be expected to
discover:

- The feature branch does not yet publish a matching ready-to-pull image.
- Each model helper selects one hard-coded model; users need a clearer model
  discovery or override flow when their account cannot access that model.
- Adding a provider after sandbox creation requires sandbox recreation.
