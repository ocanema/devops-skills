# Service connectivity: the long tail

Read this when the evidence doesn't match the common case in `SKILL.md` — that is, when the
selector is fine, or the endpoints are populated and the Service still won't answer.

- [1. Empty endpoints](#1-empty-endpoints)
- [2. Endpoints populated, still unreachable](#2-endpoints-populated-still-unreachable)
- [3. Debug tools that lie](#3-debug-tools-that-lie)
- [4. Signatures: curl exit codes](#4-signatures-curl-exit-codes)
- [5. DNS in Kubernetes](#5-dns-in-kubernetes)
- [6. Drift and provenance](#6-drift-and-provenance)
- [7. Prevention](#7-prevention)

---

## 1. Empty endpoints

The EndpointSlice controller adds a pod when *every* condition holds: the pod's labels are a
superset of `spec.selector`, the pod is in the Service's namespace, it has a pod IP, and it
is Ready. Each failure below breaks exactly one of those.

| Cause | Tell |
|---|---|
| **Selector typo** | Selector value appears on no pod; a near-identical value does. The label reconciliation block in `collect-service-evidence.sh` shows both. |
| **Case / whitespace** | `App=Checkout` vs `app=checkout`. Label matching is exact and case-sensitive. |
| **Wrong namespace** | Selectors never cross namespaces. A Service in `demo` cannot select pods in `staging`, no matter the labels. |
| **Selector copied from the Deployment's `matchLabels`** | Usually identical, so it usually works — until someone adds a label to `template.metadata.labels` only, or to `matchLabels` only, and they diverge. The Service matches *pod* labels, nothing else. |
| **Pods never become Ready** | Selector matches, `matched > 0` but `readyPods == 0`. This is a pod problem: readiness probe, missing dependency, config. Hand off to `diagnose-crashloop`. |
| **Readiness gates** | Pod containers are ready but a `readinessGate` condition is unmet, so the pod is not Ready and is excluded. |
| **Named `targetPort` not present on the container** | `targetPort: http` requires a container port literally *named* `http`. If it isn't there, the slice is created without usable ports. |
| **Pods terminating / rolling** | Terminating pods leave the slice immediately. During a bad rollout you can hit zero briefly — or permanently, if the new pods never pass readiness. |
| **Selectorless Service** | `spec.selector` absent: endpoints are managed by hand or by an external controller (a common pattern for pointing at an out-of-cluster backend). Empty means whoever manages them stopped. |
| **`publishNotReadyAddresses`** | When true, not-ready pods are published anyway — so a *populated* endpoint list can still route to pods that can't serve. |

## 2. Endpoints populated, still unreachable

Endpoints being present only proves selection worked.

- **App bound to `127.0.0.1`.** Works via `kubectl exec` + `curl localhost`, fails from every
  other pod. Bind to `0.0.0.0`. Very common in frameworks whose dev-server default is
  localhost.
- **`targetPort` ≠ the port the process actually listens on.** `containerPort` is
  documentation — it is not enforced and does not open anything. A Service can point at 8080
  while the app listens on 3000, with every manifest looking correct.
- **NetworkPolicy.** The signature is a *timeout*, not a refusal: a policy drops packets
  silently. Check for policies selecting either the client or the server pods; remember that
  a namespace with any ingress policy defaults to deny for pods it selects.
- **Protocol mismatch.** A UDP service probed with TCP tooling looks dead. Check
  `spec.ports[].protocol`.
- **Service mesh / mTLS.** A sidecar rejecting a plaintext or non-mTLS peer looks like a
  connection reset. Probing from a pod *without* a sidecar (like the throwaway probe pod) can
  fail while real traffic works — or the reverse. Note whether the namespace has injection
  enabled before trusting either result.
- **Headless Service (`clusterIP: None`).** DNS returns pod IPs, not a virtual IP, and there
  is no kube-proxy DNAT. Clients that expect a single stable IP misbehave; `getent hosts`
  returns several addresses.
- **`externalTrafficPolicy: Local`** on NodePort/LoadBalancer drops traffic on nodes with no
  local backing pod — some requests work, some don't, depending on which node they land on.
- **kube-proxy unhealthy on a node.** Rare, but produces node-dependent failure: same Service,
  different result depending on the client's node. Probe from pods on two different nodes.
- **Stale conntrack entries** after a backend's IP changed can pin traffic to a dead endpoint
  for the life of the entry.

## 3. Debug tools that lie

A control run is the cheapest defence against all of these — same command, known-good target.

| Tool | The lie |
|---|---|
| **busybox / alpine `nslookup`** | Returns NXDOMAIN for names that resolve perfectly, including `kubernetes.default.svc`, because it mishandles `ndots:5` search-path expansion. It has sent more incidents down the DNS path than any actual DNS fault. Use `getent hosts` or `dig +search`. |
| **`ping <ClusterIP>`** | Always fails, even for a perfectly healthy Service. A ClusterIP is a virtual IP with DNAT rules for its declared ports; nothing answers ICMP. "I can't even ping it" is not evidence. |
| **`kubectl run --rm -i`** | Silently drops chunks of a short-lived pod's output. Missing lines are indistinguishable from failed requests. Run the pod to completion and read `kubectl logs`. |
| **`nc -z`** | Behaviour varies by build (busybox vs GNU vs BSD): some report success on a half-open connection, some hang. |
| **`telnet` / `curl` absent from the image** | "Command not found" reads as a connection failure in a hurried skim of the output. |
| **Testing from the host / a node** | ClusterIP and cluster DNS are only meaningful inside the pod network. Failures there mean nothing about in-cluster reachability. |

## 4. Signatures: curl exit codes

Run with `-s -o /dev/null -w "http=%{http_code} connect=%{time_connect}s"` — `time_connect`
is as informative as the exit code.

| Exit | Meaning | Typical cause |
|---|---|---|
| `0` | HTTP response received | Path works end to end |
| `6` | Could not resolve host | Real DNS failure — verify with a control |
| `7` | Failed to connect | With `connect≈0.000s` on a ClusterIP: **no endpoints**. Also: nothing listening on that port |
| `28` | Timeout | Packets dropped: NetworkPolicy, firewall, wrong IP, blackhole route |
| `52` / `56` | Empty or malformed reply | **TCP connected.** Connectivity is fine; the port just isn't HTTP (gRPC, TLS-only, a raw protocol) |

Anything other than 6, 7, or 28 means the TCP connection was established — which is the
question you're actually asking when triaging reachability.

## 5. DNS in Kubernetes

- **Forms of a name.** `checkout` → `checkout.demo` → `checkout.demo.svc` →
  `checkout.demo.svc.cluster.local`. All of these resolve from a pod in `demo` with a normal
  resolver, via the `search` list in `/etc/resolv.conf`.
- **`ndots:5`** means names with fewer than 5 dots are tried against each search-domain
  suffix *first*. This is why partially-qualified names depend on correct search-path
  handling, and why a resolver that fumbles it fails on short forms while the FQDN works.
- **A trailing dot** (`checkout.demo.svc.cluster.local.`) bypasses the search path entirely —
  useful for isolating search-path bugs from actual resolution failures.
- **DNS knows nothing about endpoints.** A Service with zero endpoints still resolves to its
  ClusterIP. Resolution succeeding tells you the Service object exists — nothing more.
- **CoreDNS health**, when you genuinely suspect it:
  `kubectl get pods -n kube-system -l k8s-app=kube-dns` and check that the `kube-dns` Service
  has endpoints. If CoreDNS were down, *every* name would fail, including your control.

## 6. Drift and provenance

Worth a minute, because it decides whether the fix goes in the cluster, the repo, or both.

- **`kubectl.kubernetes.io/last-applied-configuration` vs the live spec.** A mismatch proves
  someone mutated the running object (`kubectl edit`/`patch`) rather than the manifest — so
  the manifest is likely still correct and a re-apply is the cleanest fix.
- **`kubectl get svc <x> --show-managed-fields -o json`** → `.metadata.managedFields` lists
  every field manager and when it wrote. A `kubectl-patch` or `kubectl-edit` entry timestamped
  around the incident window names the mechanism, if not the person.
- **`kubectl diff -f <manifest>`** shows live-vs-source in both directions. Empty output after
  a fix is the proof that no drift remains.
- **Check whether the "incident" was self-inflicted.** Grep the repo for the offending value
  before writing a postmortem — demo scripts, test fixtures, and chaos tooling apply exactly
  these breakages on purpose. Provenance changes what you tell people.

## 7. Prevention

1. **Alert on zero-endpoint Services.** Fire when a Service has 0 ready endpoints for >2m
   while pods matching its selector are Ready. That pairing separates "wiring broken" from
   "app down" and would have caught this class outright. `scan-zero-endpoint-services.sh` is
   the manual form:

   ```bash
   kubectl get endpointslice -A -o json | jq -r '
     .items[] | select(.metadata.labels["kubernetes.io/service-name"]) |
     select([.endpoints[]?.conditions.ready // false] | any | not) |
     "\(.metadata.namespace)/\(.metadata.labels["kubernetes.io/service-name"])"'
   ```

2. **Validate selectors in CI.** Assert that every `Service.spec.selector` matches at least
   one workload's pod template labels in the same manifest set. Kubernetes will never do this
   for you — label values are free-form strings.
3. **Admission policy** (Kyverno/OPA) for the same rule, if you'd rather catch it at apply
   time than at merge time.
4. **GitOps with drift detection**, or `kubectl diff -f` in CI, to close the live-edit path
   that produced the drift in the first place.
5. **Fix the runbook, not just the Service.** If your debug pod's `nslookup` lies, every
   future incident starts with a wrong theory. Standardise on `getent hosts`, `dig +search`,
   and `curl -v`.
