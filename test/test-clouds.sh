#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Test every cloud overlay against one local cluster.
#
# The overlays in environments/cloud/ differ in four ways: the storageClass
# name, the ingress-nginx Service type and its annotations, the Valkey replica
# switch, and the Postgres volume size. This exercises those differences
# locally so a broken overlay does not reach a real cluster.
#
#   render  (default) Template every overlay. Catches Go-template and chart
#           value errors in seconds and needs no cluster.
#   install Sync each overlay on the current cluster and wait for pods.
#
# Install mode destroys and deletes PVCs between clouds. StatefulSet
# volumeClaimTemplates are immutable, so Postgres cannot move from one
# storageClass or volume size to another in place.
#
# Alias StorageClasses named gp3, standard-rwo and managed-csi are created
# against the cluster's own default provisioner. Cloud load balancer
# annotations render but do nothing locally, so the ingress controller Service
# is forced to NodePort unless --real-load-balancer is passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLOUDS="onprem eks gke aks"
PROFILE="core"
SIZING="standard"
MODE="render"
INCLUDE_RULES="false"
REAL_LB="false"
KEEP_RELEASES="false"
READY_TIMEOUT="600"

# Cloud storageClass names, kept in sync with environments/cloud/*.yaml.
# onprem uses "" (the cluster default) so it needs no alias.
ALIAS_CLASSES="gp3 standard-rwo managed-csi"

# aks enables every release onprem does plus ingress-nginx, so destroying with
# it removes the superset no matter which overlay was installed last.
TEARDOWN_CLOUD="aks"

usage() {
  cat <<'EOF'
Usage: test/test-clouds.sh [options]

  --mode render|install      render templates only (default) or install for real
  --clouds "onprem eks ..."  which overlays to test (default: all four)
  --profile core|full|private-rules|member|dockerhub
  --sizing standard|small|medium|large
  --include-rules            install every rule pod too (install mode)
  --real-load-balancer       keep the overlay Service type instead of NodePort
  --keep-releases            leave the last install running
  --ready-timeout SECONDS    pod readiness wait (default 600)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    --clouds) CLOUDS="$2"; shift 2 ;;
    --clouds=*) CLOUDS="${1#*=}"; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --sizing) SIZING="$2"; shift 2 ;;
    --sizing=*) SIZING="${1#*=}"; shift ;;
    --include-rules) INCLUDE_RULES="true"; shift ;;
    --real-load-balancer) REAL_LB="true"; shift ;;
    --keep-releases) KEEP_RELEASES="true"; shift ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --ready-timeout=*) READY_TIMEOUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$MODE" in
  render|install) ;;
  *) echo "--mode must be render or install. Got '$MODE'." >&2; exit 1 ;;
esac

case "$PROFILE" in
  core|full|private-rules|member|dockerhub) ;;
  *) echo "--profile must be core, full, private-rules, member or dockerhub. Got '$PROFILE'." >&2; exit 1 ;;
esac

case "$SIZING" in
  standard|small|medium|large) ;;
  *) echo "--sizing must be standard, small, medium or large. Got '$SIZING'." >&2; exit 1 ;;
esac

for cloud in $CLOUDS; do
  case "$cloud" in
    onprem|eks|gke|aks) ;;
    *) echo "Unknown cloud '$cloud'. Allowed: onprem eks gke aks." >&2; exit 1 ;;
  esac
done

for tool in helmfile helm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH." >&2; exit 1; }
done
if [ "$MODE" = "install" ]; then
  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl is not on PATH and is required for --mode install." >&2
    exit 1
  }
fi

LAUNCHER="$ROOT/tazama.sh"
[ -f "$LAUNCHER" ] || { echo "tazama.sh not found in $ROOT." >&2; exit 1; }

default_provisioner() {
  kubectl get storageclass \
    -o 'jsonpath={.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].provisioner}' \
    2>/dev/null | awk '{print $1}'
}

any_provisioner() {
  kubectl get storageclass -o 'jsonpath={.items[0].provisioner}' 2>/dev/null
}

create_alias_classes() {
  local provisioner="$1" name
  for name in $ALIAS_CLASSES; do
    if kubectl get storageclass "$name" >/dev/null 2>&1; then
      echo "  $name already exists, left alone"
      continue
    fi
    kubectl apply -f - >/dev/null <<EOF || { echo "Failed to create StorageClass $name." >&2; exit 1; }
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $name
  labels:
    tazama.io/cloud-test-alias: "true"
provisioner: $provisioner
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
    echo "  $name -> $provisioner"
  done
}

clear_tazama_state() {
  # Releases and PVCs both have to go. A surviving PVC keeps the previous
  # storageClass and size, which the next overlay cannot change in place.
  # tazama.sh takes profile and cloud positionally: <command> [profile] [cloud]
  "$LAUNCHER" destroy "$PROFILE" "$TEARDOWN_CLOUD" --sizing "$SIZING" >/dev/null 2>&1
  kubectl delete pvc --all -n tazama --wait=false >/dev/null 2>&1
  kubectl wait --for=delete pvc --all -n tazama --timeout=120s >/dev/null 2>&1
}

unhealthy_pods() {
  kubectl get pods -n tazama \
    -o 'go-template={{range .items}}{{if ne .status.phase "Succeeded"}}{{$ready := true}}{{$reason := .status.phase}}{{range .status.containerStatuses}}{{if not .ready}}{{$ready = false}}{{if .state.waiting}}{{$reason = .state.waiting.reason}}{{end}}{{end}}{{end}}{{if or (ne .status.phase "Running") (not $ready)}}{{.metadata.name}}={{$reason}}{{"\n"}}{{end}}{{end}}{{end}}' \
    2>/dev/null
}

echo ""
echo "Cloud overlay test"
echo "  mode    : $MODE"
echo "  profile : $PROFILE"
echo "  sizing  : $SIZING"
echo "  clouds  : $CLOUDS"

if [ "$MODE" = "install" ]; then
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "No reachable cluster. Point kubectl at one, or use --mode render." >&2
    exit 1
  fi

  PROVISIONER="$(default_provisioner)"
  [ -n "$PROVISIONER" ] || PROVISIONER="$(any_provisioner)"
  if [ -z "$PROVISIONER" ]; then
    echo "Could not read a StorageClass provisioner from this cluster." >&2
    exit 1
  fi
  echo ""
  echo "Alias StorageClasses (cloud names on the local provisioner):"
  create_alias_classes "$PROVISIONER"

  if [ "$INCLUDE_RULES" != "true" ]; then
    echo ""
    echo "Rules tier excluded for capacity. Pass --include-rules to install every rule pod."
  fi
fi

SUMMARY=""
FAILURES=0
TOTAL=0

for cloud in $CLOUDS; do
  echo ""
  printf -- '-%.0s' $(seq 62); echo ""
  echo "$cloud ($MODE)"
  printf -- '-%.0s' $(seq 62); echo ""

  if [ "$MODE" = "render" ]; then
    set -- template
  else
    set -- sync
  fi
  set -- "$@" "$PROFILE" "$cloud" --sizing "$SIZING"

  if [ "$MODE" = "install" ]; then
    echo "Clearing previous releases and PVCs..."
    clear_tazama_state

    if [ "$INCLUDE_RULES" != "true" ]; then
      set -- "$@" --selector 'tier!=rules'
    fi
    if [ "$REAL_LB" != "true" ] && [ "$cloud" != "onprem" ]; then
      # A local cluster assigns no external IP, so helm --wait would sit on a
      # pending LoadBalancer until it times out.
      set -- "$@" --ingress-service-type NodePort
    fi
  fi

  started="$(date +%s)"
  output="$("$LAUNCHER" "$@" 2>&1)"
  code=$?
  elapsed=$(( $(date +%s) - started ))

  status="PASS"
  detail=""
  TOTAL=$(( TOTAL + 1 ))

  if [ "$code" -ne 0 ]; then
    status="FAIL"
    detail="$(printf '%s\n' "$output" | grep -m1 -E 'Error:|error:|failed|FAILED' | tr -s ' ' | cut -c1-120)"
    echo "FAIL after ${elapsed}s"
    if [ -n "$detail" ]; then
      echo "  $detail"
    else
      printf '%s\n' "$output" | tail -n 15 | sed 's/^/  /'
    fi
  elif [ "$MODE" = "install" ]; then
    echo "Synced in ${elapsed}s, waiting for pods..."
    kubectl wait --for=condition=Ready pods --all -n tazama --timeout="${READY_TIMEOUT}s" >/dev/null 2>&1
    bad="$(unhealthy_pods)"
    if [ -n "$bad" ]; then
      status="FAIL"
      detail="$(printf '%s\n' "$bad" | head -n 3 | paste -sd ',' -)"
      echo "$(printf '%s\n' "$bad" | grep -c .) pod(s) never became ready:"
      printf '%s\n' "$bad" | sed 's/^/  /'
    else
      echo "PASS, all pods Ready"
    fi
  else
    echo "PASS in ${elapsed}s"
  fi

  [ "$status" = "PASS" ] || FAILURES=$(( FAILURES + 1 ))
  SUMMARY="${SUMMARY}$(printf '%-8s %-5s %5ss  %s' "$cloud" "$status" "$elapsed" "$detail")
"
done

if [ "$MODE" = "install" ] && [ "$KEEP_RELEASES" != "true" ]; then
  echo ""
  echo "Tearing down. Pass --keep-releases to leave the last install running."
  clear_tazama_state
fi

echo ""
echo "Summary"
printf '%s' "$SUMMARY"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES of $TOTAL overlays failed."
  exit 1
fi
echo "All $TOTAL overlays passed."
exit 0
