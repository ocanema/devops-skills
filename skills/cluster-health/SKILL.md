---
name: cluster-health
description: Quick read-only health sweep of the current Kubernetes cluster. Use when asked "is the cluster healthy", "check the cluster", or before/after a deploy to spot broken pods, pressure conditions, and recent warning events.
---

# Cluster health sweep

A fast, **read-only** snapshot of cluster health. Never mutate anything —
no deletes, no restarts, no scaling. If something is broken, report it and
recommend the matching triage skill (e.g. `incident-triage`,
`diagnose-crashloop`); do not fix it here.

## Steps

1. **Nodes** — `kubectl get nodes -o wide`. Flag any node not `Ready`, and
   check conditions for `MemoryPressure`, `DiskPressure`, `PIDPressure`:
   `kubectl describe nodes | grep -A5 Conditions`.
2. **Workloads** — `kubectl get pods -A`. Flag anything not `Running` or
   `Completed`, and any pod with restarts > 3. Note the namespace — ignore
   nothing, but lead with non-system namespaces.
3. **Recent warnings** — `kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20`.
4. **Capacity quick-look** — `kubectl top nodes` if metrics-server is
   available; skip silently if not.

## Report format

One short section per step, worst news first. End with a verdict line:

- `HEALTHY — nothing needs attention`
- `DEGRADED — <n> issues, none urgent`
- `BROKEN — <what> needs triage now` (name the skill to run next)

Keep the whole report under 30 lines. Raw command output goes in
collapsible detail only if the user asks.
