#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#   ./infra/gcp/up.sh --sizing small|medium|large --project YOUR_PROJECT_ID
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

SIZING="medium"
PROJECT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sizing) SIZING="$2"; shift 2 ;;
    --sizing=*) SIZING="${1#*=}"; shift ;;
    --project) PROJECT_ARG="$2"; shift 2 ;;
    --project=*) PROJECT_ARG="${1#*=}"; shift ;;
    -h|--help) echo "Usage: $0 --sizing small|medium|large --project PROJECT_ID"; exit 0 ;;
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
need gcloud

if [[ -z "$PROJECT_ARG" && -n "${GOOGLE_CLOUD_PROJECT:-}" ]]; then
  PROJECT_ARG="$GOOGLE_CLOUD_PROJECT"
fi
if [[ -z "$PROJECT_ARG" && -n "${CLOUDSDK_CORE_PROJECT:-}" ]]; then
  PROJECT_ARG="$CLOUDSDK_CORE_PROJECT"
fi
if [[ -n "$PROJECT_ARG" ]]; then
  export GOOGLE_CLOUD_PROJECT="$PROJECT_ARG"
  printf 'project = "%s"\n' "$PROJECT_ARG" > project.auto.tfvars
elif [[ -f project.auto.tfvars ]]; then
  echo "Using project already saved in project.auto.tfvars"
  PROJECT_ARG="$(sed -n 's/^project *= *"\(.*\)".*/\1/p' project.auto.tfvars | head -1)"
  if [[ -n "$PROJECT_ARG" ]]; then
    export GOOGLE_CLOUD_PROJECT="$PROJECT_ARG"
  fi
fi

echo "Checking GCP credentials (application-default)..."
if ! gcloud auth application-default print-access-token >/dev/null; then
  echo "GCP application-default credentials are missing." >&2
  echo "  gcloud auth login" >&2
  echo "  gcloud auth application-default login" >&2
  echo "  gcloud services enable compute.googleapis.com --project YOUR_PROJECT_ID" >&2
  echo "  $0 --sizing medium --project YOUR_PROJECT_ID" >&2
  exit 1
fi

if [[ -z "$PROJECT_ARG" ]]; then
  PROJECT_ARG="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -z "$PROJECT_ARG" || "$PROJECT_ARG" == "(unset)" ]]; then
    echo "Pass --project YOUR_PROJECT_ID (or gcloud config set project)." >&2
    exit 1
  fi
  export GOOGLE_CLOUD_PROJECT="$PROJECT_ARG"
  printf 'project = "%s"\n' "$PROJECT_ARG" > project.auto.tfvars
  echo "  GCP project: $PROJECT_ARG  (from gcloud config)"
else
  echo "  GCP project: $PROJECT_ARG"
fi

echo "OpenTofu init..."
"$TOFU" init -input=false

echo "Sizing $SIZING"
printf 'sizing = "%s"\n' "$SIZING" > sizing.auto.tfvars
echo "OpenTofu apply (GCE + k3s). This takes several minutes..."
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
echo "Do not use --cloud gke / -Cloud gke. This node is k3s, not GKE."
echo "Tear down: $HERE/down.sh"
