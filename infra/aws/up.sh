#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#   ./infra/aws/up.sh --sizing small|medium|large [--aws-profile tazama]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

SIZING="medium"
AWS_PROFILE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sizing) SIZING="$2"; shift 2 ;;
    --sizing=*) SIZING="${1#*=}"; shift ;;
    --aws-profile) AWS_PROFILE_ARG="$2"; shift 2 ;;
    --aws-profile=*) AWS_PROFILE_ARG="${1#*=}"; shift ;;
    -h|--help) echo "Usage: $0 --sizing small|medium|large [--aws-profile NAME]"; exit 0 ;;
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
need aws

if [[ -z "$AWS_PROFILE_ARG" && -n "${AWS_PROFILE:-}" ]]; then
  AWS_PROFILE_ARG="$AWS_PROFILE"
fi
if [[ -n "$AWS_PROFILE_ARG" ]]; then
  export AWS_PROFILE="$AWS_PROFILE_ARG"
  printf 'aws_profile = "%s"\n' "$AWS_PROFILE_ARG" > profile.auto.tfvars
elif [[ -f profile.auto.tfvars ]]; then
  echo "Using aws_profile already saved in profile.auto.tfvars"
  AWS_PROFILE_ARG="$(sed -n 's/^aws_profile *= *"\(.*\)".*/\1/p' profile.auto.tfvars | head -1)"
  if [[ -n "$AWS_PROFILE_ARG" ]]; then
    export AWS_PROFILE="$AWS_PROFILE_ARG"
  fi
fi

echo "Checking AWS credentials..."
if [[ -n "$AWS_PROFILE_ARG" ]]; then
  echo "  AWS profile: $AWS_PROFILE_ARG"
  aws sts get-caller-identity --profile "$AWS_PROFILE_ARG"
else
  echo "  AWS profile: default  (no --aws-profile; this is often your personal account)"
  aws sts get-caller-identity
fi

echo "OpenTofu init..."
"$TOFU" init -input=false

echo "Sizing $SIZING"
printf 'sizing = "%s"\n' "$SIZING" > sizing.auto.tfvars
echo "OpenTofu apply (EC2 + k3s). This takes several minutes..."
"$TOFU" apply -input=false -auto-approve

IP="$("$TOFU" output -raw public_ip)"
KEY="$HERE/id_rsa"
KUBE="$HERE/kubeconfig.yaml"
chmod 600 "$KEY"

echo "Copying kubeconfig from ec2-user@$IP ..."
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "ec2-user@$IP" cat kubeconfig.yaml > "$KUBE"

export KUBECONFIG="$KUBE"
echo
echo "Cluster is up."
echo "  SSH        : ssh -i $KEY -o StrictHostKeyChecking=no ec2-user@$IP"
echo "  Kubeconfig : $KUBE"
echo
echo "Lens: add cluster from $KUBE"
echo "  Sizing     : $SIZING ($("$TOFU" output -raw instance_type))"
echo "Install Tazama:"
echo "  cd $ROOT"
echo "  export KUBECONFIG=$KUBE"
echo "  ./tazama.sh sync core onprem --sizing $SIZING"
echo
echo "Tear down: $HERE/down.sh"
