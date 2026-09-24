#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT=""
usage() {
  echo "Usage: $0 [--context CONTEXT]"
  echo "Verify installed Praxis APIs, entitlement, ownership and network isolation."
  echo "Makes small OpenAI requests and cleans up temporary test resources."
}
while (($#)); do
  case "$1" in
    --context)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { usage >&2; exit 1; }
      CONTEXT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
command -v oc >/dev/null || { echo "ERROR: oc is required" >&2; exit 1; }
if [[ -z "$CONTEXT" ]]; then
  CONTEXT="$(oc config current-context 2>/dev/null)" || { echo "ERROR: Pass --context CONTEXT" >&2; exit 1; }
fi
"${SCRIPT_DIR}/pre-flight.sh" --context "$CONTEXT"

uv run --locked --project "${SCRIPT_DIR}/.." python - "$CONTEXT" "${SCRIPT_DIR}/files" <<'PY'
import base64
import copy
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid
import warnings

import requests
from urllib3.exceptions import InsecureRequestWarning
import yaml

context, files = sys.argv[1], Path(sys.argv[2])
run = "praxis-test-" + uuid.uuid4().hex[:16]
label = "showroom-praxis/test-run"
namespace = "redhat-ods-applications"
cluster_resources, api_resources, keys, sessions = [], [], [], []
stage = "installation prerequisites"


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def oc(*args, input=None, timeout=60):
    result = subprocess.run(
        ["oc", "--context", context, "--request-timeout=30s", *args],
        input=input, text=True, capture_output=True, timeout=timeout,
    )
    require(result.returncode == 0, "Cluster command failed during " + stage)
    return result.stdout.strip()


def get(ns, resource, name, optional=False):
    args = ["-n", ns, "get", resource, name, "-o", "json"]
    if optional:
        args.append("--ignore-not-found")
    output = oc(*args)
    return json.loads(output) if output else None


def create(obj):
    obj["metadata"].setdefault("labels", {})[label] = run
    group = obj["apiVersion"].split("/")[0]
    resource = obj["kind"].lower() + ("." + group if "/" in obj["apiVersion"] else "")
    entry = (obj["metadata"]["namespace"], resource, obj["metadata"]["name"])
    require(get(*entry, optional=True) is None, "A test resource name already exists")
    cluster_resources.append(entry)
    oc("create", "-f", "-", input=json.dumps(obj))


def session(key=None, maas=False):
    client = requests.Session()
    # Do not send MaaS keys through environment-configured HTTP proxies.
    client.trust_env = False
    if key:
        client.headers["Authorization"] = "Bearer " + key
    if maas:
        # The gateway's internal service certificate does not match its external address.
        client.verify = False
    sessions.append(client)
    return client


def call(client, method, url, description, checked=True, **kwargs):
    try:
        response = client.request(method, url, timeout=(15, 600), allow_redirects=False, **kwargs)
    except requests.RequestException:
        raise Failure(description + ": transport failure") from None
    if checked:
        require(200 <= response.status_code < 300, description + f": HTTP {response.status_code}")
    return response


def hidden(response, resource_id):
    # OGX can return 400 for an inaccessible vector store.
    require(response.status_code in (403, 404) or (
        response.status_code == 400 and resource_id in response.text and "not found" in response.text.lower()
    ), "Ownership isolation failed: HTTP " + str(response.status_code))


def track(client, collection, data):
    resource_id = data.get("id", "")
    require(isinstance(resource_id, str) and re.fullmatch(r"[A-Za-z0-9_.:-]+", resource_id),
            "API returned an invalid resource ID")
    url = endpoint + "/v1/" + collection + "/" + resource_id
    api_resources.append((client, url))
    return url


def maas_gateway():
    gateway = get("openshift-ingress", "gateway", "maas-default-gateway")
    addresses = gateway.get("status", {}).get("addresses", [])
    host = addresses[0].get("value", "") if addresses else ""
    require(re.fullmatch(r"[A-Za-z0-9.-]+", host), "MaaS gateway has no valid address")
    return "https://" + host + "/maas-api/v1/api-keys"


def cleanup_api(admin, key_url):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    errors = []
    for client, url in reversed(api_resources):
        try:
            call(client, "DELETE", url, "Delete test API resource")
        except Exception:
            errors.append("API resource deletion")
    for token, key_id in reversed(keys):
        try:
            call(admin, "DELETE", key_url + "/" + key_id, "Revoke test MaaS key",
                 headers={"Authorization": "Bearer " + token})
        except Exception:
            errors.append("MaaS key revocation")
    if errors:
        raise Failure("Cleanup failed: " + ", ".join(sorted(set(errors))))
    print("PASS: Test API resources deleted and MaaS keys revoked", flush=True)


def cleanup_cluster():
    errors = []
    for ns, resource, name in reversed(cluster_resources):
        try:
            obj = get(ns, resource, name, optional=True)
            if obj is None:
                continue
            require(obj["metadata"].get("labels", {}).get(label) == run, "Test resource ownership changed")
            oc("-n", ns, "delete", resource, name, "--ignore-not-found", "--timeout=120s", timeout=150)
        except Exception:
            errors.append(resource)
    for client in sessions:
        client.close()
    if errors:
        raise Failure("Cluster cleanup failed for " + ", ".join(sorted(set(errors))))
    if cluster_resources:
        print("PASS: Temporary identities, subscriptions and probe pods removed", flush=True)


def network_checks(deployment, port):
    pod_spec = deployment["spec"]["template"]["spec"]
    image = next(c["image"] for c in pod_spec["containers"] if c["name"] == "ogx")
    probes = {}
    for role, ns in (("untrusted", namespace), ("local", "grid-system"),
                     ("provider", "grid-system"), ("consumer", "grid-system")):
        obj = yaml.safe_load((files / "test-probe.yaml").read_text())
        obj["metadata"].update(name=run + "-" + role, namespace=ns)
        if role in ("provider", "consumer"):
            obj["metadata"]["labels"] = {"app.kubernetes.io/name": "praxis-gateway",
                                         "app.kubernetes.io/instance": role + "-gateway"}
        obj["spec"]["containers"][0]["image"] = image
        if ns == namespace and pod_spec.get("imagePullSecrets"):
            obj["spec"]["imagePullSecrets"] = copy.deepcopy(pod_spec["imagePullSecrets"])
        create(obj)
        name = obj["metadata"]["name"]
        oc("-n", ns, "wait", "pod/" + name, "--for=jsonpath={.status.phase}=Running",
           "--timeout=120s", "--request-timeout=0", timeout=150)
        probes[role] = (ns, name)

    ogx = f"ogx-distribution-service.{namespace}.svc.cluster.local"
    consumer = "consumer-gateway.grid-system.svc.cluster.local"
    provider = "provider-gateway.grid-system.svc.cluster.local"
    checks = {
        "untrusted": [(ogx, port, False),
                      (consumer, 8080, False), (provider, 8443, False), ("provider-state.grid-system.svc.cluster.local", 8444, False)],
        "local": [(ogx, port, False),
                  (consumer, 8080, False), (provider, 8443, False), ("provider-state.grid-system.svc.cluster.local", 8444, False)],
        "provider": [(ogx, port, True)],
        "consumer": [(provider, 8443, True), ("provider-state.grid-system.svc.cluster.local", 8444, True)],
    }
    code = '''import json, socket, sys
results = []
for host, port, expected in json.load(sys.stdin):
    address = socket.gethostbyname(host)
    try:
        with socket.create_connection((address, port), timeout=3):
            connected = True
    except (TimeoutError, ConnectionRefusedError):
        connected = False
    results.append(connected == expected)
print(json.dumps(results))
'''
    for role, entries in checks.items():
        ns, name = probes[role]
        output = oc("-n", ns, "exec", "-i", name, "--", "python3", "-c", code,
                    input=json.dumps(entries))
        results = json.loads(output)
        require(len(results) == len(entries) and all(value is True for value in results),
                "Live network isolation failed for " + role + " probe")
    print("PASS: Live OGX/gateway ingress isolation and trusted-source connectivity", flush=True)


def text(response):
    return "\n".join(part.get("text", "") for item in response.get("output", []) if item.get("type") == "message"
                     for part in item.get("content", []) if part.get("type") == "output_text")


def source_id(result):
    return (result.get("attributes") or {}).get("file_id") or result.get("file_id")


def ownership(clients, owner, url, resource_id, collection=None, content=False, search=False):
    for client in clients:
        hidden(call(client, "GET", url, "Cross-owner read", checked=False), resource_id)
        if content:
            hidden(call(client, "GET", url + "/content", "Cross-owner file content", checked=False), resource_id)
        if search:
            hidden(call(client, "POST", url + "/search", "Cross-owner vector search", checked=False,
                        json={"query": "verification code"}), resource_id)
        hidden(call(client, "DELETE", url, "Cross-owner delete", checked=False), resource_id)
        if collection:
            after = None
            for _ in range(100):
                params = {"limit": 100, **({"after": after} if after else {})}
                page = call(client, "GET", endpoint + "/v1/" + collection, "Cross-owner list", params=params).json()
                require(all(item["id"] != resource_id for item in page["data"]), "Cross-owner listing exposed a resource")
                if not page.get("has_more", False):
                    break
                cursor = page.get("last_id")
                require(cursor and cursor != after, "Invalid list pagination")
                after = cursor
            else:
                raise Failure("Ownership list verification exceeded its pagination limit")
    call(owner, "GET", url, "Owner read after denied deletion")


def functional_tests(clients):
    owner, other_user, other_tenant, excluded = clients
    anonymous = session()
    for headers in ({}, {"Authorization": "Bearer sk-oai-invalid"}):
        denied = call(anonymous, "GET", endpoint + "/v1/models", "Missing/invalid key", checked=False, headers=headers)
        require(denied.status_code in (401, 403), "Missing/invalid key was accepted")
    for name in ("x-user-id", "x-tenant-id", "x-maas-username", "x-maas-owner-tenant",
                 "x-maas-subscription-info", "x-authenticated-state-owner"):
        denied = call(owner, "GET", endpoint + "/v1/models", "Spoofed identity", checked=False, headers={name: "forged"})
        require(denied.status_code in (401, 403), "Spoofed identity header was accepted")
    for client in clients:
        call(client, "GET", endpoint + "/v1/models", "Authenticated model discovery")
    print("PASS: MaaS authentication and spoofed-identity rejection", flush=True)

    for path, payload in (("chat/completions", {"messages": [{"role": "user", "content": "Reply hello."}]}),
                          ("responses", {"input": "Reply hello."})):
        for suffix in ("", "/"):
            url = endpoint + "/v1/" + path + suffix
            denied = call(excluded, "POST", url, "Excluded model", checked=False, json={"model": model, **payload})
            require(denied.status_code == 403 and denied.headers.get("X-Policy-Violation") == "opa",
                    "Subscription-excluded model was not rejected by entitlement policy")
            for value in ({}, {"model": "unsubscribed-model"}, {"model": ""}, {"model": None}, {"model": 42}):
                denied = call(owner, "POST", url, "Invalid model entitlement", checked=False,
                              json={**payload, **value}, headers={"X-Model": model})
                require(denied.status_code == 403 and denied.headers.get("X-Policy-Violation"),
                        "Missing/invalid model bypassed entitlement policy")
    denied = call(excluded, "POST", endpoint + "/v1/responses/bypass", "Responses path bypass", checked=False,
                  json={"model": model, "input": "Reply hello."})
    require(denied.status_code in (403, 404, 405), "An alternate Responses POST path was accepted")
    print("PASS: Model entitlement, trailing-slash canonicalization and POST path restrictions", flush=True)

    chat = call(owner, "POST", endpoint + "/v1/chat/completions", "Chat Completions", json={
        "model": model, "messages": [{"role": "user", "content": "Reply with hello."}], "max_tokens": 16,
    }).json()
    require(chat.get("choices") and chat["choices"][0].get("message", {}).get("content"), "Chat Completions returned no text")
    print("PASS: Authenticated Chat Completions", flush=True)
    models = call(owner, "GET", endpoint + "/v1/models", "Embedding model discovery").json()["data"]
    require(any(item["id"] == embedding_model and item.get("custom_metadata", {}).get("model_type") == "embedding"
                for item in models), "Configured embedding model is unavailable")
    code = "praxis-" + uuid.uuid4().hex
    document = f"Praxis integration test. The verification code is {code}.\n"
    uploaded = call(owner, "POST", endpoint + "/v1/files", "File upload", data={"purpose": "assistants"},
                    files={"file": (code + ".txt", document.encode(), "text/plain")}).json()
    file_url = track(owner, "files", uploaded)
    require(call(owner, "GET", file_url, "File metadata").json()["id"] == uploaded["id"], "File metadata differs")
    require(call(owner, "GET", file_url + "/content", "File contents").text == document, "File contents differ")
    ownership((other_user, other_tenant), owner, file_url, uploaded["id"], "files", content=True)
    print("PASS: File upload/retrieval and cross-user/cross-tenant file isolation", flush=True)

    def response(payload):
        data = call(owner, "POST", endpoint + "/v1/responses", "Responses", json={
            "model": model, "store": True, "max_output_tokens": 256, **payload,
        }).json()
        url = track(owner, "responses", data)
        require(data.get("status") == "completed" and code in text(data), "Response did not return the verification code")
        stored = call(owner, "GET", url, "Stored Response").json()
        require(stored["id"] == data["id"] and stored["output"] == data["output"], "Stored Response differs")
        ownership((other_user, other_tenant), owner, url, data["id"])
        return data

    response({"input": [{"role": "user", "content": [
        {"type": "input_text", "text": "Read the attached file and return only its verification code."},
        {"type": "input_file", "file_id": uploaded["id"]},
    ]}]})
    print("PASS: Responses file resolution, stored retrieval and ownership isolation", flush=True)

    store = call(owner, "POST", endpoint + "/v1/vector_stores", "Vector store creation", json={
        "name": code, "embedding_model": embedding_model, "embedding_dimension": dimension,
    }).json()
    store_url = track(owner, "vector_stores", store)
    ownership((other_user, other_tenant), owner, store_url, store["id"], "vector_stores", search=True)
    indexed = call(owner, "POST", store_url + "/files", "File indexing", json={"file_id": uploaded["id"]}).json()
    deadline = time.monotonic() + 180
    while indexed.get("status") in ("in_progress", "pending") and time.monotonic() < deadline:
        time.sleep(2)
        indexed = call(owner, "GET", store_url + "/files/" + uploaded["id"], "Indexing status").json()
    require(indexed.get("status") == "completed", "File indexing failed or timed out")
    results = call(owner, "POST", store_url + "/search", "Vector search", json={
        "query": "What is the Praxis integration test verification code?", "max_num_results": 3,
    }).json()["data"]
    require(any(source_id(item) == uploaded["id"] and code in json.dumps(item.get("content")) for item in results),
            "Vector search did not retrieve the uploaded verification code")
    print("PASS: Vector indexing/search and cross-user/cross-tenant vector isolation", flush=True)

    data = response({
        "input": "What is the Praxis integration test verification code? Return only the code.",
        "instructions": "Use file_search to find the code. After receiving results, answer without searching again.",
        "tools": [{"type": "file_search", "vector_store_ids": [store["id"]]}], "include": ["file_search_call.results"],
    })
    searches = [item for item in data["output"] if item.get("type") == "file_search_call"]
    require(searches and all(item.get("status") == "completed" for item in searches), "Hosted file-search call did not complete")
    require(any(source_id(item) == uploaded["id"] for search in searches for item in search.get("results", [])),
            "Agentic file search did not use the uploaded OGX file")
    print("PASS: Model-tool-model file-search loop and stored agentic retrieval", flush=True)


def interrupted(signum, frame):
    raise Failure("Verification interrupted")


signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)
warnings.filterwarnings("ignore", category=InsecureRequestWarning)
try:
    model = yaml.safe_load((files / "versions.yaml").read_text())["model"]
    route = get("openshift-ingress", "route", "praxis-mvp")
    host = route["spec"]["host"]
    require(re.fullmatch(r"[A-Za-z0-9.-]+", host), "Praxis Route has no valid hostname")
    endpoint = "https://" + host
    key_url = maas_gateway()
    policy = get(namespace, "adminnetworkpolicy", "praxis-mvp-ogx", optional=True)
    require(policy is not None and policy["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") == "showroom-praxis",
            "Run install.sh first: OGX AdminNetworkPolicy is missing or unowned")
    require(get(namespace, "route", "ogx-distribution", optional=True) is None,
            "Run install.sh again: the public OGX Route exists")
    cr = get(namespace, "ogxserver", "ogx-distribution")
    require(cr["spec"].get("praxisMode", {}).get("enabled") and
            not cr["spec"].get("network", {}).get("externalAccess", {}).get("enabled", False), "OGX is not in internal Praxis mode")
    port = cr["spec"].get("network", {}).get("port", 8321)
    for ns, resource, name, condition in (
        ("openshift-ingress", "gateway", "praxis-mvp", "Programmed"),
        ("grid-system", "authpolicy", "praxis-mvp", "Enforced"),
    ):
        oc("-n", ns, "wait", resource + "/" + name, "--for=condition=" + condition,
           "--timeout=120s", "--request-timeout=0", timeout=150)
    for name in ("provider-gateway", "consumer-gateway"):
        oc("-n", "grid-system", "rollout", "status", "deployment/" + name,
           "--timeout=120s", "--request-timeout=0", timeout=150)
    provider = yaml.safe_load(get("grid-system", "configmap", "provider-praxis-config")["data"]["praxis.yaml"])
    require(any(entry["filter"] == "provider_route" and any(route.get("model") == model for route in entry["routes"])
                for chain in provider["filter_chains"] for entry in chain["filters"]), "Installed provider does not route the selected model")
    deployment = get(namespace, "deployment", "ogx-distribution")
    environment = {entry["name"]: entry for c in deployment["spec"]["template"]["spec"]["containers"]
                   if c["name"] == "ogx" for entry in c.get("env", [])}

    def setting(name):
        entry = environment[name]
        if "value" in entry:
            return entry["value"]
        reference = entry["valueFrom"]
        if "secretKeyRef" in reference:
            ref = reference["secretKeyRef"]
            return base64.b64decode(get(namespace, "secret", ref["name"])["data"][ref["key"]]).decode()
        ref = reference["configMapKeyRef"]
        return get(namespace, "configmap", ref["name"])["data"][ref["key"]]

    embedding_model = setting("EMBEDDING_PROVIDER") + "/" + setting("EMBEDDING_MODEL")
    dimension = int(setting("EMBEDDING_DIMENSION"))
    require(dimension > 0, "Invalid embedding dimension")
    for ns, verbs, resources in (
        (namespace, ("create", "get", "delete"), ("pods",)),
        ("grid-system", ("create", "get", "delete"), ("pods", "serviceaccounts")),
        ("models-as-a-service", ("create", "get", "delete"),
         ("externalmodels.inference.opendatahub.io", "maasmodelrefs.maas.opendatahub.io",
          "maassubscriptions.maas.opendatahub.io", "maasauthpolicies.maas.opendatahub.io")),
    ):
        for verb in verbs:
            for resource in resources:
                oc("auth", "can-i", verb, resource, "-n", ns, "--quiet")
    for ns in (namespace, "grid-system"):
        oc("auth", "can-i", "create", "pods/exec", "-n", ns, "--quiet")
        oc("auth", "can-i", "watch", "pods", "-n", ns, "--quiet")
    oc("auth", "can-i", "create", "serviceaccounts/token", "-n", "grid-system", "--quiet")
    oc("auth", "can-i", "watch", "maassubscriptions.maas.opendatahub.io", "-n", "models-as-a-service", "--quiet")
    print("Verifying Praxis on context: " + context, flush=True)
    stage = "live network isolation"
    network_checks(deployment, port)
    stage = "temporary MaaS registration"
    for obj in yaml.safe_load_all((files / "test-identities.yaml").read_text().replace("__RUN__", run)):
        create(obj)
    for suffix in ("shared", "other", "denied"):
        oc("-n", "models-as-a-service", "wait", "maassubscription/" + run + "-" + suffix,
           "--for=jsonpath={.status.phase}=Active", "--timeout=120s", "--request-timeout=0", timeout=150)
    tokens = {name: oc("-n", "grid-system", "create", "token", run + "-" + name, "--duration=1h") for name in ("a", "b")}
    admin = session(maas=True)
    try:
        clients = []
        for user, subscription in (("a", "shared"), ("b", "shared"), ("a", "other"), ("a", "denied")):
            data = call(admin, "POST", key_url, "Create test MaaS key",
                        headers={"Authorization": "Bearer " + tokens[user]},
                        json={"name": run, "subscription": run + "-" + subscription, "expiresIn": "1h"}).json()
            keys.append((tokens[user], data["id"]))
            clients.append(session(data["key"]))
        stage = "authenticated API verification"
        functional_tests(clients)
    finally:
        cleanup_api(admin, key_url)
except Failure as error:
    print("FAIL: " + str(error), file=sys.stderr)
    sys.exit(1)
except Exception:
    # API bodies and subprocess errors may include credentials; never echo them.
    print("FAIL: Unexpected error during " + stage, file=sys.stderr)
    sys.exit(1)
finally:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    stage = "cluster cleanup"
    try:
        cleanup_cluster()
    except Failure as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
print("Praxis verification PASSED.", flush=True)
PY
