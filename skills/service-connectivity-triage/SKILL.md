---
name: service-connectivity-triage
description: >-
  Diagnose a Kubernetes Service that is unreachable while its pods look perfectly healthy —
  empty endpoints, selector/label mismatches, targetPort errors, and the DNS red herrings
  that usually come with them. Use this whenever someone reports a service is down, dark,
  unreachable, refusing connections, or timing out but `kubectl get pods` is all green; when
  a Service has no endpoints; when a name resolves but nothing answers; or when anyone
  blames DNS for a service that won't respond. Prefer this over `diagnose-crashloop` or
  `incident-triage` when the pods themselves are Running and Ready — those skills triage pod
  state, and pod state is exactly what looks fine in this failure.
metadata:
  owner: platform-team
  version: 0.1.0
  # A convention this skill follows, not a sandbox the runtime enforces. The real backstops
  # are the bundled scripts (which read, or create one throwaway pod), Claude Code
  # permissions, and your RBAC.
  default-mode: read-only-until-approved
---

# Service connectivity triage

**A Service can be 100% dark while its fleet is 100% green.** Pod health and service
reachability are different facts about the world. Readiness probes passing, zero restarts,
no warning events — none of that says a single byte can reach the app through its Service.
Nothing that alerts on pod state will fire for this class of incident, which is why it
arrives as "support says X is unreachable" rather than as a page, and why the first theory
on the table is usually wrong.

## When to use

Someone says: "the service is unreachable", "it's returning connection refused", "requests
to X time out", "X can't reach Y", "the endpoints are empty", "I think it's DNS" — and the
pods behind it are `Running`, `Ready`, and not restarting.

## The two habits that actually solve it

**1. Find the first hop that fails.** The request path has distinct, separately testable
hops, and exactly one of them is broken:

```
name -> DNS -> ClusterIP -> endpoints -> kube-proxy DNAT -> podIP:targetPort -> app listening
```

Test hops instead of theorizing about them. The evidence tells you which hop; you don't have
to guess, and guessing is what turns a ten-minute incident into an hour.

**2. Never trust a single negative observation — run a control.** When a diagnostic reports
a failure, run the same command against something known-good before you believe it. If the
control fails too, your *tool* is broken, not the service. This one habit is the difference
between fixing the Service and spending the incident rebuilding CoreDNS: `nslookup` in a
busybox debug pod returns NXDOMAIN for `kubernetes.default.svc` — a service that
unambiguously works — because it mishandles `ndots:5` search-path expansion. Anyone
debugging with it concludes "DNS is broken" no matter what is actually wrong.

## Procedure

### 1. Collect the evidence in one pass

```bash
scripts/collect-service-evidence.sh <namespace> <service>
```

Read-only. It prints the Service spec, ready/not-ready endpoints, pods matching the
selector, a **label reconciliation** block, a **port reconciliation** block, drift
provenance, and a mechanical verdict.

Prefer this over improvising `kubectl get` calls, mainly for the label block. A
one-character selector typo is invisible when you eyeball two long label strings — that's
why it shipped. The script sets the selector value beside every value actually present in
the namespace:

```
app.kubernetes.io/name=chekout  ->  NO POD HAS THIS VALUE
    values present in namespace: checkout (2 pods), payments (2 pods)
```

**Endpoints are the pivot.** Pods Ready + zero endpoints means the Service is not selecting
them, and nothing downstream matters until that's fixed. Pods not Ready means you have a pod
problem — hand off to `diagnose-crashloop` or `triage-pending-pods`.

To find everything affected, or when you don't yet know which Service is at fault:

```bash
scripts/scan-zero-endpoint-services.sh [namespace]
```

### 2. Confirm the verdict by probing the path

```bash
scripts/probe-service-path.sh <namespace> <service> [--repeat N] [--from-namespace NS]
```

Creates one short-lived pod, then deletes it. It resolves the name with `getent` (the
resolver applications actually use), connects to the ClusterIP, connects straight to the pod
IPs, repeats to catch intermittency, and pairs the DNS check with a known-good control.

Do this even when step 1 looks conclusive. An empty `endpoints` field is inference; `curl`
failing to the Service while the pod IPs return 200 is proof, and it's stated in the same
terms the reporter used. That distinction matters when you have to tell someone their theory
is wrong.

### 3. When someone names a cause, test it — don't argue

The reporter's *observation* is usually real; their *conclusion* usually isn't. Both halves
matter: dismissing the observation loses their trust and sometimes loses a real clue.

Reproduce their exact command with their exact tooling, then run it against a known-good
target. "Your nslookup says NXDOMAIN for `kubernetes.default.svc` too, and that service
works" ends the argument in one line and costs one command. Compare with disproving DNS by
assertion, which doesn't end it at all.

### 4. Read the signature

| Observation | What it means |
|---|---|
| Name resolves, connect fails instantly (`curl` exit 7, `connect=0.000s`) | No backend. kube-proxy has nothing to DNAT to — endpoints are empty. |
| Name resolves, connect **times out** (exit 28) | Packets are being dropped, not refused. NetworkPolicy, mesh sidecar, node firewall. |
| Name doesn't resolve, **and the control doesn't either** | Resolver or CoreDNS problem, cluster-wide — not this Service. |
| Name doesn't resolve, control resolves fine | Genuinely this Service's DNS: check the Service exists, in that namespace, spelled that way. |
| Service refuses, pod IPs answer | App is healthy. The fault is Service wiring: selector, targetPort, or port. |
| Service answers sometimes | Partial endpoint set — some pods not Ready, or a rollout in flight. |

If the endpoints are populated and it still doesn't work, the cause is in
`references/failure-modes.md` — named targetPorts, apps bound to `127.0.0.1`, NetworkPolicy,
headless Services, mesh mTLS.

### 5. Fix at the right layer — both of them

Propose the fix and get approval before mutating anything. Then fix it in **two places**,
because they're independent:

- **The live object**, to stop the bleeding:
  `kubectl patch svc <svc> -n <ns> --type=merge -p '{"spec":{"selector":{"<key>":"<value>"}}}'`
- **The manifest or IaC that owns it**, or the next deploy silently reverts you.

The evidence script's drift block tells you which is which. If
`last-applied-configuration` disagrees with the live spec, someone edited the running object
and the manifest is probably already correct — a plain re-apply fixes it and no repo change
is needed. If the manifest carries the typo too, patching alone buys you hours at best.
`kubectl diff -f <manifest>` at the end confirms live state and source agree.

### 6. Verify against the reported symptom

Endpoints populating is necessary, not sufficient — it's your metric, not theirs. Re-run the
exact call that was reported broken, in the form it was reported (short name, `.svc` form,
FQDN, and from another namespace if that's where the caller lives), and repeat it enough
times to catch a partial fix: `probe-service-path.sh <ns> <svc> --repeat 30`.

One caveat worth internalizing: `kubectl run --rm -i` **silently drops chunks of output**.
Missing lines look identical to failed requests. The bundled script runs the pod to
completion and reads `kubectl logs` instead, which is authoritative — if you hand-roll a
probe, do the same rather than concluding anything from a gap in attached output.

### 7. Close the loop

- **Prevention.** Alert on Services with 0 ready endpoints for >2m *while their workload has
  Ready pods* — that pairing is what distinguishes "selector broken" from "app is down", and
  it's the alert that would have caught this. `scan-zero-endpoint-services.sh` is the same
  check, runnable now.
- **Selector typos are invisible to Kubernetes.** Label values are free-form strings;
  `chekout` is valid YAML and valid Kubernetes. No schema validation will ever catch it. Only
  CI (`kubectl diff`, a manifest lint asserting every `Service.spec.selector` matches some
  pod template in the same manifest set) or an admission policy will.
- **Retire the lying tool from the runbook.** Tell the reporter *why* their check misled
  them and what to use instead (`getent hosts`, `dig +search`, `curl -v`). Otherwise the next
  incident starts with the same wrong theory.
- **Report unrelated findings, don't chase them.** Broken things you pass on the way — a
  CrashLoopBackOff in the same namespace — get mentioned as separate items with their own
  skill (`diagnose-crashloop`), not folded into this root cause.

## Bundled scripts

| Script | Mutates? | Use |
|---|---|---|
| `scripts/collect-service-evidence.sh <ns> <svc>` | No | One-pass evidence + mechanical verdict |
| `scripts/probe-service-path.sh <ns> <svc>` | Creates one throwaway pod | Find the first failing hop, with controls |
| `scripts/scan-zero-endpoint-services.sh [ns]` | No | Every dark Service, classified by cause |

`references/failure-modes.md` — the long tail: everything that produces empty endpoints,
everything that breaks a Service that *has* endpoints, the catalog of debug tools that lie,
and curl/DNS signatures. Read it when the evidence doesn't match the common case above.
