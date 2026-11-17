#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#   ./infra/azure/up.sh --sizing small|medium|large --subscription YOUR_SUBSCRIPTION_ID
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

SIZING="medium"
SUB_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sizing) SIZING="$2"; shift 2 ;;
    --sizing=*) SIZING="${1#*=}"; shift ;;
    --subscription) SUB_ARG="$2"; shift 2 ;;
    --subscription=*) SUB_ARG="${1#*=}"; shift ;;
    -h|--help) echo "Usage: $0 --sizing small|medium|large --subscription SUBSCRIPTION_ID"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$SIZING" in
  small|medium|large) ;;
  *) echo "--sizing must be small, medium, or large." >&2; exit 1 ;;
esac

need() { command -v "$1" >/dev/null || { echo "$1 is not on PATH." >&2; exit 1; }; }
TOFU=tofu
if ! command -v tofu >/dev/null; then
  if command -v terraform >/dev/null; then
    TOFU=terraform
    echo "tofu not on PATH; using terraform."
  else
    echo "OpenTofu (tofu) is not on PATH. https://opentofu.org/docs/intro/install/" >&2
    exit 1
  fi
fi
need ssh
need az

if [[ -z "$SUB_ARG" && -n "${ARM_SUBSCRIPTION_ID:-}" ]]; then
  SUB_ARG="$ARM_SUBSCRIPTION_ID"
fi
if [[ -n "$SUB_ARG" ]]; then
  export ARM_SUBSCRIPTION_ID="$SUB_ARG"
  printf 'subscription_id = "%s"\n' "$SUB_ARG" > subscription.auto.tfvars
elif [[ -f subscription.auto.tfvars ]]; then
  echo "Using subscription already saved in subscription.auto.tfvars"
  SUB_ARG="$(sed -n 's/^subscription_id *= *"\(.*\)".*/\1/p' subscription.auto.tfvars | head -1)"
  if [[ -n "$SUB_ARG" ]]; then
    export ARM_SUBSCRIPTION_ID="$SUB_ARG"
  fi
fi

echo "Checking Azure login..."
if ! az account show >/dev/null; then
  echo "Azure CLI is not logged in." >&2
  echo "  az login" >&2
  echo "  az account set --subscription YOUR_SUBSCRIPTION_ID" >&2
  echo "  az provider register --namespace Microsoft.Compute" >&2
  echo "  az provider register --namespace Microsoft.Network" >&2
  echo "  $0 --sizing medium --subscription YOUR_SUBSCRIPTION_ID" >&2
  exit 1
fi

if [[ -z "$SUB_ARG" ]]; then
  SUB_ARG="$(az account show --query id --output tsv)"
  if [[ -z "$SUB_ARG" ]]; then
    echo "Pass --subscription YOUR_SUBSCRIPTION_ID (or az account set --subscription)." >&2
    exit 1
  fi
  export ARM_SUBSCRIPTION_ID="$SUB_ARG"
  printf 'subscription_id = "%s"\n' "$SUB_ARG" > subscription.auto.tfvars
  echo "  Azure subscription: $SUB_ARG  (from az account show)"
else
  az account set --subscription "$SUB_ARG"
  echo "  Azure subscription: $SUB_ARG"
fi

echo "OpenTofu init..."
"$TOFU" init -input=false

echo "Sizing $SIZING"
printf 'sizing = "%s"\n' "$SIZING" > sizing.auto.tfvars
echo "OpenTofu apply (Azure VM + k3s). This takes several minutes..."
"$TOFU" apply -input=false -auto-approve

IP="$("$TOFU" output -raw public_ip)"
SSH_USER="$("$TOFU" output -raw ssh_user)"
KEY="$HERE/id_rsa"
KUBE="$HERE/kubeconfig.yaml"
chmod 600 "$KEY"

echo "Copying kubeconfig from $SSH_USER@$IP ..."
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$SSH_USER@$IP" cat kubeconfig.yaml > "$KUBE"

export KUBECONFIG="$KUBE"
echo
echo "Cluster is up."
echo "  SSH        : ssh -i $KEY -o StrictHostKeyChecking=no $SSH_USER@$IP"
echo "  Kubeconfig : $KUBE"
echo "  Sizing     : $SIZING ($("$TOFU" output -raw instance_type))"
echo
echo "Install Tazama:"
echo "  cd $ROOT"
echo "  export KUBECONFIG=$KUBE"
echo "  ./tazama.sh sync core onprem --sizing $SIZING"
echo
echo "Do not use --cloud aks / -Cloud aks. This node is k3s, not AKS."
echo "Tear down: $HERE/down.sh"
