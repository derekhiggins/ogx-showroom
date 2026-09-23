# Praxis ExternalModel MVP

This flow tests the RHOAI 3.6 Praxis ExternalModel integration without changing
the existing OGXServer or its Helm releases.

For a cold run, use `cleanup-all.sh`, then reinstall with `./setup.sh` and
`./provision.sh` before running the commands below.

```bash
export OPENAI_API_KEY="your-openai-api-key"
podman login quay.io
./praxis-mvp/build-images.sh
./praxis-mvp/create-workload.sh
./praxis-mvp/test.sh
```

`build-images.sh` always uses unique Quay tags and refuses a tag that already
exists. It builds the AI Gateway controller, MaaS controller, OGX Kubernetes
operator, and Praxis images. It also checks out the AI Gateway operator for the
manifests applied by `create-workload.sh`. Override a source revision with
`CONTROLLER_REF`, `MAAS_REF`, `AI_GATEWAY_OPERATOR_REF`,
`OGX_K8S_OPERATOR_REF`, or `PRAXIS_REF`.

Images go to your own registry namespace: by default
`quay.io/<your quay login>/praxis-mvp`, using the account you logged in to with
`podman login quay.io`. That repository must exist and be writable by you.
Override the pieces with `PRAXIS_MVP_REGISTRY_HOST`,
`PRAXIS_MVP_REGISTRY_NAMESPACE`, and `PRAXIS_MVP_REGISTRY_REPOSITORY`, or set
the whole untagged repository at once:

```bash
PRAXIS_MVP_REGISTRY=quay.io/yourname/imagehost ./praxis-mvp/build-images.sh
```

The workload opts the default MaaS tenant into Praxis and adds an OpenAI
ExternalProvider for `gpt-4o-mini`. A second tenant is not used
because multi-tenant MaaS callback routing remains unqualified. The test
verifies authenticated OpenAI routing using `gpt-4o-mini`,
unknown-model handling, the locally built ExtProc image, and preservation and
availability of the pre-existing OGXServer.

The client-facing model name and provider target model are both `gpt-4o-mini`.

The cleanup is intentionally destructive:

```bash
./praxis-mvp/cleanup-all.sh --confirm-delete-all
```

It removes OGX, AI Gateway, RHOAI, Kyverno, RHCL/cert-manager operands, test
resources, and related CRDs so the cluster can be reinstalled from scratch.
