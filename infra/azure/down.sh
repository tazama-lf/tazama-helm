#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

KUBE="$HERE/kubeconfig.yaml"
if [[ -f "$KUBE" ]] && command -v kubectl >/dev/null && [[ -x "$ROOT/tazama.sh" ]]; then
  export KUBECONFIG="$KUBE"
  if kubectl get nodes >/dev/null 2>&1; then
    echo "Destroying Tazama Helm releases..."
    SIZING="medium"
    if command -v tofu >/dev/null; then
      SIZING="$(tofu output -raw sizing 2>/dev/null || echo medium)"
    elif command -v terraform >/dev/null; then
      SIZING="$(terraform output -raw sizing 2>/dev/null || echo medium)"
    fi
    (cd "$ROOT" && ./tazama.sh destroy core onprem --sizing "$SIZING") || true
    kubectl delete pvc --all -n tazama --wait=false >/dev/null 2>&1 || true
  fi
fi

TOFU=tofu
command -v tofu >/dev/null || TOFU=terraform
command -v "$TOFU" >/dev/null || { echo "OpenTofu (tofu) is not on PATH." >&2; exit 1; }
echo "OpenTofu destroy..."
"$TOFU" destroy -input=false -auto-approve

rm -f "$KUBE"
echo "Azure k3s cluster is gone."
