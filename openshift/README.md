# OpenShift-native OpenClaw/OpenShell PoC

This layout separates cluster-admin work from an ordinary project deployment.

| Namespace | Owner | Purpose |
|---|---|---|
| `sallyom-openshell-remote` | cluster administrator | OpenShell gateway and its cluster-scoped RBAC/SCC |
| `sallyom-openshell-openclaw` | project user | OpenClaw Gateway, worker configuration, Service, and Route |

The administrator installs OpenShell and grants the OpenClaw ServiceAccount access
to the OpenShell client identity. The project user applies `namespace.yaml`, creates
the provider Secret, and applies `gateway.yaml` and `route.yaml`.

The administrator must also make the OpenShell client TLS Secret available in the
OpenClaw namespace (or provide an equivalent namespace-scoped Secret) because
Secrets cannot be mounted across namespaces:

```sh
oc get secret openshell-client-tls -n sallyom-openshell-remote -o yaml \
  | sed 's/namespace: sallyom-openshell-remote/namespace: sallyom-openshell-openclaw/' \
  | oc apply -f -
```

Use a reviewed Secret-copy mechanism in production; the command above is only a
short-lived PoC convenience.

The manifests deliberately contain no provider key or gateway token. Create those
as Secrets before applying the Deployment. `gateway.yaml` uses the current
temporary OIDC token file; the next iteration should replace it with a durable
workload mTLS identity.

## Admin phase

Install OpenShell in `sallyom-openshell-remote` using the chart and values in
`../openshell-k8s`. Configure the OpenShell workspace/provider/inference route,
then create the application project if the user cannot self-provision projects:

```sh
oc new-project sallyom-openshell-openclaw
oc adm policy add-role-to-user edit sallyom -n sallyom-openshell-openclaw
```

The admin must copy `openshell-client-tls` into the application project as shown
above. The OpenShell gateway's own cluster-scoped RBAC and SCC remain confined to
the infrastructure project; the OpenClaw user does not need cluster-admin.

## Project-user phase

```sh
# Only run this if the user is allowed to self-provision projects. Otherwise the
# administrator creates the project and grants the user edit in the admin phase.
oc apply -f openshift/namespace.yaml
oc -n sallyom-openshell-openclaw create secret generic openclaw-gateway-token \
  --from-literal=token="$(openssl rand -hex 32)"
oc -n sallyom-openshell-openclaw create secret generic openshell-worker-oidc \
  --from-file=token=/path/to/current/access-token
oc apply -f openshift/gateway.yaml
oc apply -f openshift/route.yaml
export OPENCLAW_ROUTE_HOST="$(oc get route openclaw -n sallyom-openshell-openclaw -o jsonpath='{.spec.host}')"
oc -n sallyom-openshell-openclaw set env deployment/openclaw-gateway \
  OPENCLAW_PUBLIC_URL="https://${OPENCLAW_ROUTE_HOST}"
oc get route openclaw -n sallyom-openshell-openclaw
```

If the project was pre-created by an administrator, skip `namespace.yaml` and
run the remaining commands as the project owner. Set the image in
`gateway.yaml` to the immutable AMD64 overlay tag that your team built before
applying it.

The OpenClaw image must be the OpenShift-compatible AMD64 overlay image (the
`amd64-ocp` image includes the runtime token bridge). The
OpenShell worker image remains multi-architecture and is selected by the remote
OpenShell gateway.

Build the overlay on an AMD64 builder:

```sh
cp ../OpenShell/target/release/openshell csb/openshell-cli
podman build --platform linux/amd64 \
  -f csb/Containerfile.session-workers-gateway \
  -t quay.io/sallyom/openclaw-openshell-csb:amd64-ocp \
  --build-arg OPENCLAW_IMAGE=quay.io/sallyom/openclaw-openshell:latest \
  --build-arg OPENCLAW_OPENSHELL_CLI=csb/openshell-cli .
podman push quay.io/sallyom/openclaw-openshell-csb:amd64-ocp
rm csb/openshell-cli
```
