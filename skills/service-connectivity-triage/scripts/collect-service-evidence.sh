#!/usr/bin/env bash
# collect-service-evidence.sh — one read-only pass that answers "does this Service have
# endpoints, and if not, why not?"
#
# Usage: collect-service-evidence.sh <namespace> <service>
#
# Reads only: get/describe. It never patches, applies, deletes, or creates.
set -uo pipefail

NS="${1:-}"; SVC="${2:-}"
if [ -z "$NS" ] || [ -z "$SVC" ]; then
  echo "usage: $(basename "$0") <namespace> <service>" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

svc_json="$(kubectl get svc "$SVC" -n "$NS" --show-managed-fields -o json 2>/dev/null)"
if [ -z "$svc_json" ]; then
  echo "Service $NS/$SVC not found. Services in $NS:" >&2
  kubectl get svc -n "$NS" >&2
  exit 1
fi

pods_json="$(kubectl get pods -n "$NS" -o json 2>/dev/null)"
slices_json="$(kubectl get endpointslice -n "$NS" -l "kubernetes.io/service-name=$SVC" -o json 2>/dev/null)"
[ -z "$slices_json" ] && slices_json='{"items":[]}'

hr() { printf '\n=== %s ===\n' "$1"; }

sel="$(jq -r '.spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$svc_json")"

hr "SERVICE $NS/$SVC"
jq -r '
  "type:      " + (.spec.type // "ClusterIP"),
  "clusterIP: " + (.spec.clusterIP // "-"),
  "selector:  " + (if ((.spec.selector // {}) | length) == 0
                   then "(none — selectorless Service; endpoints are managed elsewhere)"
                   else (.spec.selector | to_entries | map("\(.key)=\(.value)") | join(",")) end),
  "ports:     " + ((.spec.ports // []) | map("\(.name // "-"): \(.port) -> targetPort \(.targetPort)/\(.protocol // "TCP")") | join("  |  "))
' <<<"$svc_json"

hr "ENDPOINTS — the pivot of this whole diagnosis"
jq -r '
  ([.items[].endpoints[]? | select(.conditions.ready == true)  | .addresses[]?] | unique) as $ready |
  ([.items[].endpoints[]? | select(.conditions.ready != true)  | .addresses[]?] | unique) as $notready |
  "ready addresses:     " + (if ($ready|length)==0 then "NONE" else ($ready | join(", ")) end),
  "not-ready addresses: " + (if ($notready|length)==0 then "none" else ($notready | join(", ")) end),
  "slice ports:         " + ([.items[].ports[]? | ((.name // "") | if . == "" then "-" else . end) + ":" + (.port|tostring)] | unique | join(", "))
' <<<"$slices_json"

hr "PODS MATCHING THE SELECTOR"
if [ -z "$sel" ]; then
  echo "(service has no selector — skipping)"
else
  match_count="$(kubectl get pods -n "$NS" -l "$sel" --no-headers 2>/dev/null | grep -c . || true)"
  if [ "${match_count:-0}" -eq 0 ]; then
    echo "0 pods match '$sel'"
  else
    kubectl get pods -n "$NS" -l "$sel" \
      -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase,IP:.status.podIP' 2>/dev/null
  fi
fi

hr "LABEL RECONCILIATION — selector value vs values actually on pods"
echo "(a one-character typo shows up here as NO POD HAS THIS VALUE next to the real value)"
jq -n --argjson svc "$svc_json" --argjson pods "$pods_json" -r '
  ($svc.spec.selector // {}) as $sel
  | if ($sel | length) == 0 then "service has no selector"
    else
      ($sel | to_entries[]) as $e
      | ([$pods.items[] | .metadata.labels[$e.key] // empty] | group_by(.) | map({v: .[0], n: length})) as $present
      | "  " + $e.key + "=" + $e.value + "  ->  "
        + (if ($present | map(.v) | index($e.value)) then "matches pods" else "NO POD HAS THIS VALUE" end)
        + "\n      values present in namespace: "
        + (if ($present | length) == 0 then "(no pod carries this label key at all)"
           else ($present | map("\(.v) (\(.n) pods)") | join(", ")) end)
    end
'

hr "PORT RECONCILIATION — Service targetPort vs container ports"
echo "(a named targetPort must match a container port NAME; a numeric one must match the port the app listens on)"
jq -n --argjson svc "$svc_json" --argjson pods "$pods_json" -r '
  ($svc.spec.selector // {}) as $sel
  | ([$pods.items[] | . as $p
      | select(($sel | length) > 0 and (($sel | to_entries) | all(. as $e | (($p.metadata.labels // {}) | .[$e.key]) == $e.value)))]) as $matched
  | (if ($matched | length) > 0 then $matched else $pods.items end) as $scope
  | (if ($matched | length) > 0 then "" else "no pods match the selector — showing every pod in the namespace instead:\n" end)
    + ([$scope[] | "  " + .metadata.name + ": "
        + ([.spec.containers[].ports[]? | "\(.name // "-"):\(.containerPort)/\(.protocol // "TCP")"] | join(", ") | if . == "" then "(no ports declared)" else . end)]
       | join("\n"))
'

hr "DRIFT / PROVENANCE — was the live object edited instead of the manifest?"
jq -r '
  ((.spec.selector // {}) | to_entries | map("\(.key)=\(.value)") | join(",")) as $live
  | (.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] // "") as $la
  | (if $la == "" then "no last-applied-configuration annotation (server-side apply, GitOps, or never kubectl-applied)"
     else ($la | fromjson | (.spec.selector // {}) | to_entries | map("\(.key)=\(.value)") | join(",")) as $applied
       | if $applied == $live
         then "live selector matches last-applied (" + $live + ") — no kubectl-visible drift"
         else "DRIFT: last-applied says [" + $applied + "] but live spec says [" + $live + "]\n"
              + "       someone patched/edited the running object; the manifest may still be correct"
         end
     end),
  "field managers (a lone kubectl-patch/kubectl-edit entry is the tell of a live hand-edit):",
  ([.metadata.managedFields[]? | "  " + .manager + "  op=" + .operation + "  t=" + (.time // "-")]
   | if length == 0 then "  (none reported)" else join("\n") end)
' <<<"$svc_json"

hr "VERDICT (mechanical — confirm it by probing the path)"
ready_n="$(jq -r '[.items[].endpoints[]? | select(.conditions.ready == true) | .addresses[]?] | unique | length' <<<"$slices_json")"
if [ -z "$sel" ]; then
  echo "Selectorless Service — endpoints come from a manually managed EndpointSlice or an external controller."
elif [ "${ready_n:-0}" -gt 0 ]; then
  echo "Service HAS $ready_n ready endpoint(s). The break is downstream of endpoint selection:"
  echo "probe the path (NetworkPolicy, targetPort, what the app binds to). See references/failure-modes.md."
else
  matched_ready="$(kubectl get pods -n "$NS" -l "$sel" -o json 2>/dev/null \
    | jq -r '[.items[] | select([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length > 0)] | length' 2>/dev/null)"
  matched_all="$(kubectl get pods -n "$NS" -l "$sel" -o json 2>/dev/null | jq -r '.items | length' 2>/dev/null)"
  if [ "${matched_all:-0}" -eq 0 ]; then
    echo "0 ready endpoints AND the selector matches 0 pods."
    echo "=> Selector/label mismatch. Compare the LABEL RECONCILIATION block above against the pod labels."
  elif [ "${matched_ready:-0}" -eq 0 ]; then
    echo "0 ready endpoints, but $matched_all pod(s) match the selector — none are Ready."
    echo "=> Readiness problem, not a selector problem. Triage the pods (readiness probe, dependencies)."
  else
    echo "0 ready endpoints, yet $matched_ready matching pod(s) are Ready."
    echo "=> Unusual. Check targetPort vs container ports, and whether the EndpointSlice controller is healthy."
  fi
fi
