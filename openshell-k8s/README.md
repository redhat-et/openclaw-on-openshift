# OpenShell Kubernetes provider setup

This directory contains the temporary Kubernetes-side provisioning step for the
OpenShell/OpenClaw proof of concept. It imports a provider credential from a
namespace Secret into OpenShell; the Secret is never mounted into OpenClaw or
any worker sandbox.

The provisioning Job uses a small CLI-only image. The image must contain a
Linux amd64 `openshell` binary built from the delegated OpenShell branch; it
does not contain the gateway server or OpenClaw.

Build it from the OpenShell checkout (replace the source path as needed):

```sh
cp ../OpenShell/target/release/openshell openshell-k8s/openshell
podman build \
  -f openshell-k8s/Containerfile.cli \
  -t quay.io/sallyom/openshell-cli:amd64-delegated \
  openshell-k8s
podman push quay.io/sallyom/openshell-cli:amd64-delegated
rm openshell-k8s/openshell
```

Update `provider-provision-job.yaml` to use that image before applying the Job.

## Keycloak authorization

The Kubernetes compute driver does not support mTLS as user authorization.
Configure OpenShell OIDC instead. This cluster has Keycloak at:

```text
https://<keycloak-host>/realms/agentic
```

The example values file targets the existing `agentic` realm. Create a
confidential Keycloak client named `openshell-cli`, enable service accounts,
and configure its access-token audience to include `openshell-cli`. The client
must be allowed to call OpenShell administration APIs. Store a short-lived
client-credentials access token in the target namespace:

```sh
oc create secret generic openshell-oidc-token \
  -n sallyom-openshell-remote \
  --from-literal=token="$OPENSHELL_OIDC_TOKEN"
```

Upgrade the gateway with the OIDC settings as the cluster deployment
administrator:

```sh
helm upgrade sallyom-openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.0.0-dev \
  -n sallyom-openshell-remote \
  --reuse-values \
  -f openshell-k8s/values-keycloak.yaml
```

Then run the provider Job as `sallyom`. The Job uses the OIDC token only for
OpenShell control-plane authorization and reads `OPENAI_API_KEY` from the
separate `openai-api` Secret. Neither value is mounted into OpenClaw or worker
sandboxes.

## OpenClaw CSB remote-gateway test

The session-worker quickstart can mount the Route CA and a short-lived
Keycloak token into the Gateway sandbox. These files are mounted read-only and
are not baked into an image:

```sh
export OPENCLAW_CSB_GATEWAY_ENDPOINT=https://<openshell-route-host>
export OPENCLAW_CSB_OPENSHELL_CA_FILE=$PWD/openshell-ca.crt
export OPENCLAW_CSB_OPENSHELL_TOKEN_FILE=$PWD/openshell-oidc-token
export OPENCLAW_CSB_OPENSHELL_COMMAND=/path/to/openshell

./scripts/openclaw-csb-workers quickstart
```

The token file must contain a current Keycloak access token with the
`openshell-admin` role. Rotate it when it expires and recreate the Gateway
sandbox so the new file is mounted.

## Prerequisites

Run these commands as the namespace user (`sallyom`), in
`sallyom-openshell-remote`:

```sh
oc project sallyom-openshell-remote
oc whoami
oc get secret openai-api
oc get secret openshell-client-tls
```

The `openai-api` Secret must contain an `OPENAI_API_KEY` key. The OpenShell
Helm deployment must already have created `openshell-client-tls`.

## Provision the provider

```sh
oc apply -f openshell-k8s/provider-provision-job.yaml
oc logs -f job/openshell-provider-provision
oc delete job openshell-provider-provision
```

The Job uses the OpenShell client certificate and the in-cluster gateway
endpoint. It exits after creating the `openai` provider. Do not print the
Secret, copy it into a ConfigMap, or mount it into an OpenClaw/sandbox Pod.

If the provider already exists, update it using the corresponding
`openshell provider update` command rather than creating a duplicate.
