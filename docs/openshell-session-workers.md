# OpenShell session-worker CSB (WIP)

This proof uses the OpenClaw `WorkerProvider` from
[`sallyom/openclaw:openshell-session-workers`](https://github.com/sallyom/openclaw/tree/openshell-session-workers)
with the delegated child-sandbox capability from
[`sallyom/OpenShell:openshell-openclaw-worker-delegation`](https://github.com/sallyom/OpenShell/tree/openshell-openclaw-worker-delegation).
(tested at `50db19ff`)

The OpenClaw Gateway is an operator-created OpenShell sandbox. Each selected
Cloud/OpenShell session is a separate child sandbox in the same workspace.
OpenShell owns policy, workspace inference, and provider credentials; the
Gateway and workers receive only their sandbox-scoped identity. This path has
no standalone broker and no shared client mTLS volume.

## Prerequisites

- Build the OpenShell delegation branch and run its gateway with the Podman
  driver.
- Build/push the OpenClaw image from the `openshell-session-workers` branch.
- The current compatibility implementation still needs the OpenShell CLI in
  the Gateway image. It reads the mounted `OPENSHELL_SANDBOX_TOKEN_FILE`; do
  not add a client mTLS key to the image.
- Create a workspace provider and its `inference.local` route before running
  the helper. The preserved default is `openai` / `gpt-5.5`.

## Build the Gateway image

```sh
cp ../OpenShell/target/debug/openshell csb/openshell-cli
podman build -t quay.io/sallyom/openclaw-openshell-csb-gateway:workers-wip \
  --build-arg OPENCLAW_IMAGE=quay.io/sallyom/openclaw-openshell:latest \
  --build-arg OPENCLAW_OPENSHELL_CLI=csb/openshell-cli \
  -f csb/Containerfile.session-workers-gateway .
```

The image must contain the delegation-branch `openshell` CLI at the command
configured by `OPENCLAW_OPENSHELL_COMMAND` (default `openshell`).

## Reviewer smoke test

```sh
# Use the delegation-branch CLI and gateway.
export OPENCLAW_CSB_OPENSHELL_COMMAND=/path/to/OpenShell/target/debug/openshell
export OPENCLAW_CSB_GATEWAY_IMAGE=quay.io/sallyom/openclaw-openshell-csb-gateway:workers-wip
export OPENCLAW_CSB_WORKER_IMAGE=quay.io/sallyom/openclaw-openshell:latest

# Creates/reuses the workspace, provider, Gateway sandbox, and UI forward.
./scripts/openclaw-csb-workers quickstart
```

Then select `Cloud · openshell` in the OpenClaw Control UI and start a test
thread. Verify:

```sh
$OPENCLAW_CSB_OPENSHELL_COMMAND --workspace openclaw-csb sandbox list
```

The list must contain the long-lived Gateway sandbox and one additional worker
sandbox per selected session. The child must carry the server-managed
`openshell.nvidia.com/parent-sandbox-id` label. Reclaiming the session must
remove only its child sandbox. A worker relay probe should return the child SSH
banner when authenticated with the Gateway sandbox JWT; a different parent or
workspace must be denied.

The ordinary `./scripts/openclaw-csb quickstart` remains the original single-
sandbox CSB demo and is independent of this WIP.
