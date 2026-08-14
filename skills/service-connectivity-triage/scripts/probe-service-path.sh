#!/usr/bin/env bash
# probe-service-path.sh — walk the request path from inside the cluster and find the first
# hop that fails: DNS -> Service ClusterIP -> pod IP:targetPort.
#
# Every check runs alongside a known-good control, because the usual reason these incidents
# get misdiagnosed is a debug tool that lies (see references/failure-modes.md). It also uses
# getent rather than nslookup: getent goes through the same resolver the application uses.
#
# Usage: probe-service-path.sh <namespace> <service> [--repeat N] [--pod-selector k=v,...] [--from-namespace NS]
#
# Creates one short-lived pod (kubectl run --rm) and issues HTTP GETs. Nothing else is mutated.
set -uo pipefail

NS="${1:-}"; SVC="${2:-}"; shift 2 2>/dev/null || true
if [ -z "$NS" ] || [ -z "$SVC" ]; then
  echo "usage: $(basename "$0") <namespace> <service> [--repeat N] [--pod-selector k=v] [--from-namespace NS]" >&2
  exit 2
fi

REPEAT=5
POD_SELECTOR=""
FROM_NS="$NS"
while [ $# -gt 0 ]; do
  case "$1" in
    --repeat)         REPEAT="${2:?}"; shift 2 ;;
    --pod-selector)   POD_SELECTOR="${2:?}"; shift 2 ;;
    --from-namespace) FROM_NS="${2:?}"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

svc_json="$(kubectl get svc "$SVC" -n "$NS" -o json 2>/dev/null)"
[ -z "$svc_json" ] && { echo "Service $NS/$SVC not found" >&2; exit 1; }

PORT="$(jq -r '.spec.ports[0].port' <<<"$svc_json")"
TARGET="$(jq -r '.spec.ports[0].targetPort // .spec.ports[0].port' <<<"$svc_json")"
[ -z "$POD_SELECTOR" ] && POD_SELECTOR="$(jq -r '.spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$svc_json")"

# Which backends should be serving? Prefer the selector. When it matches nothing — the very
# case this skill exists for — fall back to pods in the namespace exposing that port, so we
# can still prove the app itself is healthy.
POD_IPS=""
if [ -n "$POD_SELECTOR" ]; then
  POD_IPS="$(kubectl get pods -n "$NS" -l "$POD_SELECTOR" \
    -o jsonpath='{range .items[?(@.status.podIP)]}{.status.podIP}{"\n"}{end}' 2>/dev/null)"
fi
FALLBACK=0
if [ -z "$POD_IPS" ] && [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  FALLBACK=1
  POD_IPS="$(kubectl get pods -n "$NS" -o json 2>/dev/null | jq -r --argjson tp "$TARGET" '
    .items[] | select(.status.podIP != null)
    | select([.spec.containers[].ports[]?.containerPort] | index($tp))
    | .status.podIP')"
fi

FQDN="$SVC.$NS.svc.cluster.local"
echo "probing $FQDN:$PORT (targetPort $TARGET) from namespace $FROM_NS"
[ "$FALLBACK" = "1" ] && echo "note: selector matched no pods — falling back to pods in $NS that expose port $TARGET"

# Built as a here-doc so the remote script stays readable. Interpolated values are k8s names,
# IPs, and integers.
remote_script="$(cat <<EOF
explain() {
  case "\$1" in
    0)  echo "(ok)" ;;
    6)  echo "(DNS: could not resolve)" ;;
    7)  echo "(connection refused / no route — for a ClusterIP this is the signature of NO BACKEND)" ;;
    28) echo "(timed out — a drop, not a refusal: suspect NetworkPolicy or a firewall)" ;;
    52|56) echo "(TCP connected but the reply was not HTTP — connectivity is fine, the probe is wrong)" ;;
    *)  echo "" ;;
  esac
}
probe() {
  out=\$(curl -s -o /dev/null -w "http=%{http_code} connect=%{time_connect}s total=%{time_total}s" --max-time 5 "\$1" 2>/dev/null)
  rc=\$?
  echo "  \$1 -> \$out exit=\$rc \$(explain \$rc)"
}

echo "### 1. DNS via getent — the resolver applications actually use"
getent hosts $FQDN || echo "  FAILED to resolve $FQDN"
echo "    control (a service that definitely works):"
getent hosts kubernetes.default.svc.cluster.local || echo "  CONTROL FAILED — the resolver itself is broken, not this Service"

echo
echo "### 2. Connect to the Service ClusterIP"
probe "http://$FQDN:$PORT/"

echo
echo "### 3. Connect straight to the pods, bypassing the Service"
if [ -z "$(echo "$POD_IPS" | tr '\n' ' ' | tr -d ' ')" ]; then
  echo "  (no pod IPs to probe)"
else
$(for ip in $POD_IPS; do echo "  probe \"http://$ip:$TARGET/\""; done)
fi

echo
echo "### 4. Repeat x$REPEAT through the Service — catches partial/intermittent failure"
ok=0; bad=0
i=1
while [ \$i -le $REPEAT ]; do
  curl -s -o /dev/null --max-time 5 "http://$FQDN:$PORT/" 2>/dev/null
  rc=\$?
  case "\$rc" in
    6|7|28) bad=\$((bad+1)) ;;
    *)      ok=\$((ok+1)) ;;
  esac
  i=\$((i+1))
done
echo "  TCP established on \$ok/$REPEAT attempts, failed on \$bad"
EOF
)"

# Run the pod to completion and read its logs, rather than `--rm -i` attaching to it.
# Attach silently drops chunks of output on short-lived pods — you get a partial answer with
# no indication anything is missing, which is how a probe like this quietly lies to you.
POD="svcprobe-$$"
cleanup() { kubectl delete pod "$POD" -n "$FROM_NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl run "$POD" -n "$FROM_NS" --restart=Never --quiet \
  --image=curlimages/curl:8.5.0 --command -- sh -c "$remote_script" >/dev/null 2>&1

deadline=$((SECONDS + 150))
while :; do
  phase="$(kubectl get pod "$POD" -n "$FROM_NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
  case "$phase" in Succeeded|Failed) break ;; esac
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "probe pod stuck in phase=${phase:-unknown}; recent events:" >&2
    kubectl get events -n "$FROM_NS" --field-selector "involvedObject.name=$POD" >&2 2>/dev/null
    break
  fi
  sleep 2
done

kubectl logs "$POD" -n "$FROM_NS" 2>&1

cat <<'LEGEND'

--- how to read this ---
DNS resolves + connect fails instantly (exit 7, connect≈0.000s) -> the ClusterIP has no
  backend to DNAT to. Endpoints are empty. Look at the selector, not at DNS.
DNS resolves + connect times out (exit 28) -> something is dropping packets. NetworkPolicy,
  a mesh sidecar, or a node firewall.
DNS fails but the control also fails -> the resolver or CoreDNS is the problem, cluster-wide.
Service fails but the pod IPs answer -> the app is healthy; the fault is in Service wiring.
LEGEND
