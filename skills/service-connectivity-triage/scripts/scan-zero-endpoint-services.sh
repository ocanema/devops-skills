#!/usr/bin/env bash
# scan-zero-endpoint-services.sh — list every Service with zero ready endpoints, and say
# whether that's because the selector matches nothing (wiring bug) or because the pods
# behind it aren't Ready (app problem).
#
# Usage: scan-zero-endpoint-services.sh [namespace]     (default: all namespaces)
#
# Read-only. Useful twice: to scope an incident ("what else is dark?"), and afterwards as
# the check that should have caught it — a green fleet says nothing about endpoints.
set -uo pipefail

NS="${1:-}"
if [ -n "$NS" ]; then scope=(-n "$NS"); else scope=(-A); fi

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# Cluster-wide dumps are far too big for argv, so they go through temp files.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
kubectl get svc "${scope[@]}" -o json 2>/dev/null > "$tmp/svcs.json"
kubectl get endpointslice "${scope[@]}" -o json 2>/dev/null > "$tmp/slices.json"
kubectl get pods "${scope[@]}" -o json 2>/dev/null > "$tmp/pods.json"
[ -s "$tmp/svcs.json" ] || { echo "could not list services" >&2; exit 1; }
[ -s "$tmp/slices.json" ] || echo '{"items":[]}' > "$tmp/slices.json"
[ -s "$tmp/pods.json" ] || echo '{"items":[]}' > "$tmp/pods.json"

jq -n --slurpfile svcs_f "$tmp/svcs.json" --slurpfile slices_f "$tmp/slices.json" --slurpfile pods_f "$tmp/pods.json" -r '
  ($svcs_f[0]) as $svcs | ($slices_f[0]) as $slices | ($pods_f[0]) as $pods |
  # ready endpoint count, keyed by "namespace/service"
  (reduce ($slices.items[]? | select(.metadata.labels["kubernetes.io/service-name"])) as $s ({};
     .[$s.metadata.namespace + "/" + $s.metadata.labels["kubernetes.io/service-name"]] +=
       ([$s.endpoints[]? | select(.conditions.ready == true) | .addresses[]?] | length)
  )) as $ready
  | [ $svcs.items[]
      | select((.spec.type // "ClusterIP") != "ExternalName")
      | select(((.spec.selector // {}) | length) > 0)              # selectorless services are managed elsewhere
      | . as $svc
      | ($svc.metadata.namespace + "/" + $svc.metadata.name) as $key
      | select(($ready[$key] // 0) == 0)
      | ($svc.spec.selector | to_entries) as $sel
      | [ $pods.items[] | . as $p
          | select($p.metadata.namespace == $svc.metadata.namespace)
          | select($sel | all(. as $e | (($p.metadata.labels // {}) | .[$e.key]) == $e.value)) ] as $matched
      | ($matched | map(select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)) | length) as $readyPods
      | { key: $key,
          selector: ($sel | map("\(.key)=\(.value)") | join(",")),
          matched: ($matched | length),
          readyPods: $readyPods,
          verdict: (if ($matched | length) == 0 then "SELECTOR MATCHES NO PODS — wiring bug (label/selector mismatch or wrong namespace)"
                    elif $readyPods == 0 then "pods exist but none Ready — app/readiness problem, not wiring"
                    else "pods Ready but absent from endpoints — check targetPort and the EndpointSlice controller" end) } ]
  | if length == 0 then "All Services have at least one ready endpoint."
    else "Services with ZERO ready endpoints:\n" +
      ( map("  " + .key + "\n      selector: " + .selector
            + "\n      pods matching selector: " + (.matched|tostring) + " (" + (.readyPods|tostring) + " Ready)"
            + "\n      -> " + .verdict) | join("\n") )
    end
'
