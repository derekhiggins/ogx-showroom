# Praxis mode

Praxis mode adds MaaS-authenticated consumer/provider gateways to an existing
Showroom deployment. OpenAI supplies inference, Praxis serves Responses,
Conversations and the agentic tool loop, and OGX supplies files, vector stores,
embeddings and supporting APIs.

The selected model is `gpt-4.1-mini`. Versions and chart checksums are pinned in
[`files/versions.yaml`](files/versions.yaml): Grid charts/operator `0.1.4` and
Praxis AI `0.4.0`. Resource names retain the `praxis-mvp` prefix to reuse existing
registrations, identities and stored data.

## Run it

From the repository root, run after `./provision.sh`:

```bash
CONTEXT=YOUR_CONTEXT
./praxis_mode/pre-flight.sh --context "$CONTEXT"
./praxis_mode/prepare.sh --context "$CONTEXT"
./praxis_mode/install.sh --context "$CONTEXT"
./praxis_mode/test.sh --context "$CONTEXT"
```

| Script | Purpose |
| --- | --- |
| `pre-flight.sh` | Read-only tool, permission, configuration and readiness checks. |
| `prepare.sh` | Prepare storage, TLS, Grid, RHCL/Authorino and MaaS registration. |
| `install.sh` | Install gateways, switch OGX into native Praxis mode and publish authenticated routing. |
| `test.sh` | Verify authenticated APIs, entitlement, ownership and live ingress isolation; remove temporary test resources. |
| `demo.sh` | Create a one-hour key, list vector stores and make a hello-world inference call. |
| `cleanup.sh` | Full destructive teardown of Praxis and the shared Grid/RHCL/MaaS stack. |

Scripts accept `--context`, default to the current context and do not change
kubeconfig's current context. Installation replaces direct public OGX access and
Keycloak client authentication with the Praxis endpoint and MaaS API keys.

For a short demo:

```bash
./praxis_mode/demo.sh --context "$CONTEXT"
```

The demo creates a key directly through the MaaS gateway's advertised address,
then calls vector stores and inference through the public Praxis Route. The key
expires after one hour; the script does not revoke it on exit.

## Resources

### Grid and Praxis gateways: `grid-system`

| Resource | Role |
| --- | --- |
| Helm release `grid-operator` | Deploys the Grid operator, its service account/RBAC and discovery services. Installs Grid CRDs. |
| Helm release `grid-site` | Creates the Grid network, site and OpenAI provider registration below. |
| `GridNetwork/praxis-mvp` | Defines the network, trust references and consumer gateway attachment. |
| `GridSite/mvp` | Registers the local provider site. |
| `InferenceProvider/openai-mvp-provider` | Advertises the OpenAI endpoint and selected model to Grid. |
| `ConfigMap/grid-overlay-praxis-mvp-consumer-gateway` | Operator-generated routing candidates; mounted by the consumer for model routing. |
| Helm releases `consumer-gateway`, `provider-gateway` | Deploy Praxis gateway pods, ClusterIP Services and chart-managed RBAC. |
| `ConfigMap/consumer-praxis-config` | Consumer pipeline: entitlement, model routing and supporting-API dispatch. |
| `ConfigMap/provider-praxis-config` | Provider pipeline: trusted peers, provider-route validation, state APIs and inference/tool processing. |
| `Secret/praxis-model-policy` | Consumer's OPA model-entitlement policy and model-to-reference mapping. |
| `Service/provider-state` | Exposes the provider's separate state/supporting-API listener on port `8444`. |
| `ServiceAccount/praxis-verifier` | Persistent identity used by the demo to obtain a MaaS key. |

The consumer listens on HTTP port `8080`. The provider's inference and state
listeners use mutual TLS on ports `8443` and `8444`. Its agentic listener is
loopback-only at `127.0.0.1:8081`.

### Public routing: `openshift-ingress` and `grid-system`

| Resource | Namespace | Role |
| --- | --- | --- |
| `Route/praxis-mvp` | `openshift-ingress` | Public HTTPS endpoint; edge TLS termination, HTTP-to-HTTPS redirect and 600-second timeout. |
| `Gateway/praxis-mvp` | `openshift-ingress` | Frontend HTTP listener using `data-science-gateway-class`. The gateway controller creates its proxy Deployment and Service. |
| `HTTPRoute/praxis-mvp` | `grid-system` | Routes supported `/v1` APIs to the consumer and canonicalizes inference POST paths. |
| `AuthPolicy/praxis-mvp` | `grid-system` | Kuadrant policy targeting that HTTPRoute; Authorino validates MaaS keys/subscriptions and injects trusted identity headers. |
| `Gateway/maas-default-gateway` | `openshift-ingress` | Separate HTTPS gateway for MaaS API operations, including key creation. |
| `AuthPolicy/maas-gateway-auth` | `openshift-ingress` | MaaS-generated authentication policy for its gateway. |

The MaaS-generated `HTTPRoute/maas-api-route` in `redhat-ai-gateway-infra` attaches
to `maas-default-gateway`. This mode does not create a public OpenShift Route for
that gateway. The demo and verification script use its advertised LoadBalancer
address directly for key management; that address must be reachable from the
machine running the scripts. MaaS requests skip TLS certificate verification
because the gateway uses an internal service certificate. The Praxis public Route
exposes the application APIs, not the MaaS key-management API.

### MaaS registration: `models-as-a-service`

These resources are defined in [`files/maas-registration.yaml`](files/maas-registration.yaml):

| Resource | Role |
| --- | --- |
| `ExternalProvider/praxis-mvp-openai` | Registers OpenAI with MaaS and references its credential Secret. |
| `ExternalModel/praxis-mvp` | Maps the registration to `gpt-4.1-mini` and the provider's Chat Completions API. |
| `MaaSModelRef/praxis-mvp` | References the ExternalModel for subscriptions and MaaS governance. |
| `MaaSSubscription/praxis-mvp` | Lists owners and entitled model references; the default model budget is 10,000 tokens/minute. |
| `MaaSAuthPolicy/praxis-mvp` | Declares subjects authorized for the MaaS model reference. This is distinct from Kuadrant's frontend `AuthPolicy`. |

Preparation adds the setup user and
`system:serviceaccount:grid-system:praxis-verifier` to subscription owners and
MaaSAuthPolicy subjects. Existing users, groups, model references and limits are
retained. The setup user was `cluster-admin` in the verified deployment.

The registration/entitlement chain is:

```text
MaaSSubscription/praxis-mvp
  -> MaaSModelRef/praxis-mvp
    -> ExternalModel/praxis-mvp
      -> ExternalProvider/praxis-mvp-openai
         model: gpt-4.1-mini
```

Grid's `InferenceProvider` is a separate registration used by the Praxis data
path. MaaS supplies identity and subscription information; Grid supplies routing.

### Shared operators, storage and credentials

Preparation reuses RHCL if installed, otherwise bootstraps the pinned RHCL
`v1.4.3` OLM subscription and operator group in `kuadrant-system`. It creates or
reuses `Kuadrant/kuadrant`, configures `Authorino/authorino` with an internal HTTP
listener, and adds OpenShift service-CA trust through
`ConfigMap/openshift-service-ca.crt`.

It enables `spec.components.aigateway` and `aigateway.modelsAsAService` on
`DataScienceCluster/default-dsc`. RHOAI manages the resulting AI gateway/MaaS
controllers and API deployment in `redhat-ai-gateway-infra`.

| Secret | Namespace | Contents/use |
| --- | --- | --- |
| `praxis-ca` | `grid-system` | CA certificate/private key for fresh gateway identities. |
| `grid-ca` | `grid-system` | Public CA certificate. |
| `consumer-tls`, `provider-tls` | `grid-system` | Gateway certificates, private keys and CA trust. |
| `openai-credential` | `grid-system` | Deployed OGX OpenAI key, copied for provider-side credential injection. |
| `praxis-store` | `grid-system` | Deployed Showroom PostgreSQL username/password for Praxis state. |
| `praxis-mvp-openai` | `models-as-a-service` | OpenAI credential for the MaaS registration. |
| `maas-db-config` | `redhat-ai-gateway-infra` | MaaS database connection URL; existing configuration is retained. |

On Showroom's existing PostgreSQL server:

- `praxis_mvp` stores Praxis Responses and Conversations, using the existing
  `openai_responses`, `openai_conversations` and `openai_conversation_items` names.
- `praxis_mvp_maas` stores MaaS API-key data when preparation creates the MaaS
  database configuration. A retained configuration can target another database.
- OGX retains its existing storage services and database. Praxis mode enables SQL
  vector-store metadata for multi-tenant ownership; Milvus, S3 and the deployed
  embedding provider remain OGX's supporting backends.

Preparation creates missing databases and checks their owner. It preserves stored
data and valid TLS identities. If PostgreSQL is rebuilt while `maas-db-config`
survives, the retained URL can contain stale credentials or name a missing
database. Preparation currently checks that the URL exists, not that it works;
functional verification catches API-key creation failures.

## Request flow

```text
Client: Authorization: Bearer <MaaS key>
  |
  | HTTPS
  v
OpenShift Route/praxis-mvp (TLS terminates here)
  |
  | HTTP
  v
Gateway/praxis-mvp proxy
  |-- Authorino: validate key + select subscription through MaaS API (HTTPS)
  |
  | authenticated request + trusted identity/subscription headers
  v
consumer-gateway:8080
  |-- inference POST: OPA entitlement + Grid model routing
  |
  | mutual TLS
  v
provider-gateway:8443           provider-state:8444
  | inference/Responses          | files, vectors, stored state
  v                              v
Praxis loopback pipeline        OGX or Praxis loopback pipeline
  |-- OpenAI inference (HTTPS)    |-- OGX files/vectors (HTTP)
  |-- OGX file/tool calls (HTTP)  |-- Praxis Responses/Conversations state
  `-- Praxis state (PostgreSQL)   `-- PostgreSQL
```

### Chat Completions and Responses

1. The frontend authenticates the key and subscription, then sends the request
   with trusted headers to the consumer.
2. The consumer removes client `Authorization`/`x-api-key` credentials, checks
   inference entitlement and derives `X-Model` from the JSON body. Grid's overlay
   selects the registered provider candidate.
3. The consumer connects to the provider with mutual TLS. The provider validates
   the peer identity and the candidate/model/path against its rendered route.
4. Chat Completions goes to OpenAI with the provider's injected OpenAI credential.
   The client's MaaS key is not forwarded to OpenAI.
5. Responses uses Praxis's local pipeline for validation, state retrieval/storage,
   file resolution and the model-tool-model loop. The configured OpenAI inference
   leg is converted to Chat Completions. File resolution/search calls OGX with the
   same trusted user/tenant headers, then inference continues with the tool result.

### Files, vector stores and stored state

After frontend authentication, supporting APIs use the consumer's state-dispatch
branch and mutual TLS to `provider-state:8444`:

- Files, vector stores, models, prompts and embeddings go to OGX.
- Stored Responses retrieval/deletion and Conversations go to Praxis's loopback
  pipeline and PostgreSQL state stores.

These APIs bypass the consumer's Chat Completions/Responses entitlement checks
and Grid inference routing. OGX/Praxis still validate each API's request fields
and authorize resource access using the authenticated identity and ownership.

## Authorization

### 1. Obtain a subscription-bound MaaS key

The demo obtains an OpenShift token for `praxis-verifier` and uses it to call:

```text
POST /maas-api/v1/api-keys
{"name":"praxis-demo","subscription":"praxis-mvp","expiresIn":"1h"}
```

MaaS authenticates the caller and checks user/group membership against the
subscription owners. It returns a key bound to that identity and subscription.
The OpenShift token is for key management; subsequent Praxis requests use the
MaaS key.

### 2. Authenticate every public application request

[`files/auth.yaml`](files/auth.yaml) configures Authorino to:

- Accept a Bearer MaaS key with the `sk-oai-` prefix and validate it through
  `/internal/v1/api-keys/validate`.
- Select the key's subscription through `/internal/v1/subscriptions/select`, using
  the validated username/groups and bound subscription.
- Require a valid key with nonempty username, tenant and subscription. Require the
  selected subscription's name/namespace to match the key, its phase to be
  `Active` or `Degraded`, and no error or deletion timestamp.
- Reject requests supplying trusted identity, subscription or state-owner headers.

On success, Authorino injects headers into the upstream request:

| Header | Value/use |
| --- | --- |
| `X-User-Id` | MaaS username; OGX principal. |
| `X-Tenant-Id` | `<MaaS tenant>_<subscription>`; OGX tenant scope. |
| `X-MaaS-Username` | MaaS username; Praxis state-owner subject. |
| `X-MaaS-Owner-Tenant` | Same tenant/subscription scope; Praxis state-owner tenant. |
| `X-MaaS-Subscription-Info` | Selected subscription JSON; consumer entitlement input. |

For the demo, the principal is
`system:serviceaccount:grid-system:praxis-verifier` and the tenant scope is
`models-as-a-service_praxis-mvp`.

### 3. Authorize the requested inference model

The consumer's policy applies to `POST /v1/chat/completions` and
`POST /v1/responses`. It requires a body model and a route. Installation renders
this mapping into [`files/model-policy.yaml`](files/model-policy.yaml):

```yaml
model_refs:
  gpt-4.1-mini: praxis-mvp
```

OPA permits the call only if the trusted subscription JSON has namespace
`models-as-a-service` and contains that mapped model reference. Missing models,
unmapped models, missing references and policy errors are denied. A client-supplied
`X-Model` cannot replace the JSON body model.

The HTTPRoute rewrites trailing-slash inference POSTs to canonical paths before
the consumer's exact-path checks. Other Responses paths permit only GET/DELETE,
preventing an alternate inference POST path from bypassing entitlement.

**Scope:** this Praxis policy checks subscription model references. It does not
directly check `MaaSAuthPolicy` subjects, and the Praxis route does not install
MaaS token-rate enforcement. The subscription's 10,000-token/minute budget is
declared for MaaS model routing; it is not enforced by this Praxis pipeline.
`MaaSAuthPolicy` governs MaaS model access, while the custom frontend `AuthPolicy`
and consumer OPA policy enforce the Praxis request path.

### 4. Enforce ownership of stored resources

Installation enables `OGXServer/ogx-distribution.spec.praxisMode` with the provider
pod selector. The operator configures `upstream_header` authentication,
`x-user-id`/`x-tenant-id`, multi-tenancy and SQL vector-store metadata. It disables
OGX's Responses/Conversations APIs because Praxis serves them.

OGX permits authenticated creation, owner-only read/update/delete of owned
resources, and reads of unowned system resources. Tenant scope and ownership
isolate files and vector stores, including listing and search.

Praxis derives stored-state ownership from `X-MaaS-Username`,
`X-MaaS-Owner-Tenant` and the fixed issuer `urn:maas:api-key`. Stored Responses and
Conversations use that owner identity. Different users in the same subscription
have different subjects; the same user in different subscriptions has different
tenant scopes. A new key for the same user/subscription retains the same identity.

### 5. Protect trusted headers with network isolation

OGX trusts the upstream identity headers, so installation also enforces the path
through authenticated gateways:

- `NetworkPolicy/praxis-gateway-isolation` provides persistent default-deny ingress
  for both gateways. Scoped `consumer-gateway`/`provider-gateway` policies allow
  only the frontend proxy to the consumer and consumer pods to the provider.
- Both provider listeners require a certificate signed by the gateway CA and a
  peer with organization `ai-grid`.
- Priority-0 `AdminNetworkPolicy/praxis-mvp-ogx` permits provider pods and operator
  health polling on OGX's API port, permits monitoring on `9464`, then denies
  other pod ingress. The API port defaults to `8321` and is read from the OGX CR.
  AdminNetworkPolicy is needed because ordinary NetworkPolicies are additive and
  the RHOAI namespace has broader ingress grants.
- The Showroom OGX public Route is removed and OGX external access is disabled.
- `praxis-mvp-postgres` and `praxis-mvp-maas-postgres` NetworkPolicies permit the
  provider and MaaS API to reach Showroom PostgreSQL on `5432`.

Installation closes consumer ingress while changing configuration and publishes
the public Route only after frontend authentication is enforced.

## Verification and cleanup

`test.sh` creates temporary users, subscriptions, one-hour keys and probe pods.
It checks authentication/header spoofing, inference entitlement/path restrictions,
Chat Completions, files, Responses, vector indexing/search, agentic file search,
cross-user/cross-tenant ownership and live network isolation. It deletes test API
resources before revoking keys, then removes temporary cluster resources. A passing
run ends with `Praxis verification PASSED.`

```bash
./praxis_mode/cleanup.sh --context "$CONTEXT"
```

**Cleanup is destructive:** it removes the shared Grid/RHCL/Kuadrant/MaaS stack,
all contents of `grid-system`, `kuadrant-system`, `models-as-a-service` and
`redhat-ai-gateway-infra`, and the Grid, MaaS/inference and Kuadrant-family custom
resources/CRDs cluster-wide. It disables RHOAI AI gateway/MaaS and drops
`praxis_mvp` and `praxis_mvp_maas` on Showroom PostgreSQL after checking ownership.
If PostgreSQL is already absent, it reports that database deletion was skipped.

OGX's configuration, databases, PostgreSQL deployment/PVC and the
`praxis-mvp-ogx` isolation policy remain. Cleanup disables OGX external access and
removes its public Route; it does not restore normal OGX access. Use the root
lifecycle scripts to restore or remove OGX separately.

See [`STATUS.md`](STATUS.md) for the latest live results and remaining work.
