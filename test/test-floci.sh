#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Install each cloud overlay on a Floci-backed k3s cluster.
# See test/test-floci.ps1 for the Windows twin and the README Floci section.
#
#   ./test/test-floci.sh
#   ./test/test-floci.sh --clouds "eks gke"
#   ./test/test-floci.sh --keep-releases --keep-emulators

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLOUDS="eks gke aks"
PROFILE="core"
SIZING="standard"
INCLUDE_RULES="false"
REAL_LB="false"
KEEP_RELEASES="false"
KEEP_EMULATORS="false"
CLUSTER_TIMEOUT="180"
READY_TIMEOUT="600"

ALIAS_CLASSES="gp3 standard-rwo managed-csi"
TEARDOWN_CLOUD="aks"
LAUNCHER="$ROOT/tazama.sh"
KUBE_DIR="${HOME}/.kube"
mkdir -p "$KUBE_DIR"

usage() {
  cat <<'EOF'
Usage: test/test-floci.sh [options]

  --clouds "eks gke aks"     which Floci clouds to test (default: all three)
  --profile core|full|private-rules|member|dockerhub
  --sizing standard|small|medium|large
  --include-rules            install every rule pod too
  --real-load-balancer       keep overlay Service type instead of NodePort
  --keep-releases            leave the last Tazama install running
  --keep-emulators           leave Floci containers running
  --cluster-timeout SECONDS  wait for k3s cluster (default 180)
  --ready-timeout SECONDS    pod readiness wait (default 600)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --clouds) CLOUDS="$2"; shift 2 ;;
    --clouds=*) CLOUDS="${1#*=}"; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --sizing) SIZING="$2"; shift 2 ;;
    --sizing=*) SIZING="${1#*=}"; shift ;;
    --include-rules) INCLUDE_RULES="true"; shift ;;
    --real-load-balancer) REAL_LB="true"; shift ;;
    --keep-releases) KEEP_RELEASES="true"; shift ;;
    --keep-emulators) KEEP_EMULATORS="true"; shift ;;
    --cluster-timeout) CLUSTER_TIMEOUT="$2"; shift 2 ;;
    --cluster-timeout=*) CLUSTER_TIMEOUT="${1#*=}"; shift ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --ready-timeout=*) READY_TIMEOUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

for cloud in $CLOUDS; do
  case "$cloud" in
    eks|gke|aks) ;;
    *) echo "Unknown cloud '$cloud'. Floci covers eks gke aks." >&2; exit 1 ;;
  esac
done

for tool in docker kubectl helm helmfile; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH." >&2; exit 1; }
done
[ -f "$LAUNCHER" ] || { echo "tazama.sh not found in $ROOT." >&2; exit 1; }

wait_port() {
  local host="$1" port="$2" seconds="${3:-90}" i
  for i in $(seq 1 "$seconds"); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for ${host}:${port}" >&2
  return 1
}

start_aws() {
  docker rm -f tazama-floci-aws >/dev/null 2>&1 || true
  docker run -d --name tazama-floci-aws \
    -p 4566:4566 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    floci/floci:latest >/dev/null
  wait_port 127.0.0.1 4566 90
}

start_gcp() {
  docker rm -f tazama-floci-gcp >/dev/null 2>&1 || true
  docker run -d --name tazama-floci-gcp \
    -p 4588:4588 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    floci/floci-gcp:latest >/dev/null
  wait_port 127.0.0.1 4588 90
}

start_az() {
  docker rm -f tazama-floci-az >/dev/null 2>&1 || true
  docker run -d --name tazama-floci-az \
    -p 4577:4577 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    floci/floci-az:latest >/dev/null
  wait_port 127.0.0.1 4577 90
}

stop_floci() {
  [ "$KEEP_EMULATORS" = "true" ] && return 0
  docker rm -f "$1" >/dev/null 2>&1 || true
}

alias_storage() {
  local provisioner name
  provisioner="$(kubectl get storageclass \
    -o 'jsonpath={.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].provisioner}' \
    2>/dev/null | awk '{print $1}')"
  [ -n "$provisioner" ] || provisioner="$(kubectl get storageclass -o 'jsonpath={.items[0].provisioner}' 2>/dev/null)"
  [ -n "$provisioner" ] || { echo "k3s has no StorageClass." >&2; return 1; }
  echo "  aliasing cloud StorageClass names onto $provisioner"
  for name in $ALIAS_CLASSES; do
    if kubectl get storageclass "$name" >/dev/null 2>&1; then
      echo "  $name already exists"
      continue
    fi
    kubectl apply -f - >/dev/null <<EOF
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
  done
}

clear_tazama() {
  "$LAUNCHER" destroy "$PROFILE" "$TEARDOWN_CLOUD" --sizing "$SIZING" >/dev/null 2>&1 || true
  kubectl delete pvc --all -n tazama --wait=false >/dev/null 2>&1 || true
  kubectl wait --for=delete pvc --all -n tazama --timeout=120s >/dev/null 2>&1 || true
}

unhealthy_pods() {
  kubectl get pods -n tazama \
    -o 'go-template={{range .items}}{{if ne .status.phase "Succeeded"}}{{$ready := true}}{{$reason := .status.phase}}{{range .status.containerStatuses}}{{if not .ready}}{{$ready = false}}{{if .state.waiting}}{{$reason = .state.waiting.reason}}{{end}}{{end}}{{end}}{{if or (ne .status.phase "Running") (not $ready)}}{{.metadata.name}}={{$reason}}{{"\n"}}{{end}}{{end}}{{end}}' \
    2>/dev/null
}

connect_eks() {
  command -v aws >/dev/null 2>&1 || { echo "AWS CLI is required for eks." >&2; return 1; }
  export AWS_ENDPOINT_URL=http://localhost:4566
  export AWS_DEFAULT_REGION=us-east-1
  export AWS_EC2_METADATA_DISABLED=true
  aws iam create-user --user-name tazama-eks >/dev/null 2>&1 || true
  local key_json id secret
  key_json="$(aws iam create-access-key --user-name tazama-eks --output json)" || {
    echo "Could not create an IAM access key in Floci." >&2
    return 1
  }
  id="$(printf '%s' "$key_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
  secret="$(printf '%s' "$key_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
  export AWS_ACCESS_KEY_ID="$id"
  export AWS_SECRET_ACCESS_KEY="$secret"
  aws eks create-cluster \
    --name tazama-eks \
    --role-arn arn:aws:iam::000000000000:role/eks-role \
    --resources-vpc-config 'subnetIds=[],securityGroupIds=[]' >/dev/null 2>&1 || true
  local i status
  for i in $(seq 1 "$CLUSTER_TIMEOUT"); do
    status="$(aws eks describe-cluster --name tazama-eks --query cluster.status --output text 2>/dev/null || true)"
    echo "  EKS status: $status"
    [ "$status" = "ACTIVE" ] && break
    sleep 5
  done
  [ "$status" = "ACTIVE" ] || { echo "EKS cluster did not become ACTIVE." >&2; return 1; }
  export KUBECONFIG="${KUBE_DIR}/tazama-floci-eks.yaml"
  aws eks update-kubeconfig --name tazama-eks --kubeconfig "$KUBECONFIG"
  kubectl config --kubeconfig "$KUBECONFIG" set-cluster "arn:aws:eks:us-east-1:000000000000:cluster/tazama-eks" --insecure-skip-tls-verify=true >/dev/null
  kubectl get nodes
}

connect_gke() {
  curl -sS -X POST \
    "http://localhost:4588/container/v1/projects/floci-local/locations/us-central1/clusters" \
    -H "Content-Type: application/json" \
    -d '{"cluster":{"name":"tazama-gke"}}' >/dev/null
  local i json status server ca kube
  kube="${KUBE_DIR}/tazama-floci-gke.yaml"
  for i in $(seq 1 "$CLUSTER_TIMEOUT"); do
    json="$(curl -sS "http://localhost:4588/container/v1/projects/floci-local/locations/us-central1/clusters/tazama-gke")"
    status="$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d.get("cluster", d); print(c.get("status",""))')"
    echo "  GKE status: $status"
    [ "$status" = "RUNNING" ] && break
    sleep 5
  done
  [ "$status" = "RUNNING" ] || { echo "GKE cluster did not become RUNNING." >&2; return 1; }
  server="$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d.get("cluster", d); print(c.get("endpoint",""))')"
  ca="$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d.get("cluster", d); print((c.get("masterAuth") or {}).get("clusterCaCertificate",""))')"
  case "$server" in
    https://*|http://*) ;;
    *) server="https://${server}" ;;
  esac
  if [ -n "$ca" ]; then
    ca_line="    certificate-authority-data: ${ca}"
  else
    ca_line="    insecure-skip-tls-verify: true"
  fi
  cat > "$kube" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
${ca_line}
    server: ${server}
  name: tazama-gke
contexts:
- context:
    cluster: tazama-gke
    user: tazama-gke
  name: tazama-gke
current-context: tazama-gke
users:
- name: tazama-gke
  user:
    token: floci
EOF
  export KUBECONFIG="$kube"
  kubectl get nodes
}

connect_aks() {
  local api cred kube b64
  api="http://localhost:4577/subscriptions/tazama-sub/resourceGroups/tazama-rg/providers/Microsoft.ContainerService/managedClusters/tazama-aks?api-version=2024-04-01"
  curl -sS -X PUT "$api" -H "Content-Type: application/json" -d '{
    "location":"eastus",
    "properties":{
      "kubernetesVersion":"1.29",
      "dnsPrefix":"tazama-aks",
      "agentPoolProfiles":[{"name":"nodepool1","count":1,"vmSize":"Standard_DS2_v2","osType":"Linux","mode":"System"}]
    }
  }' >/dev/null
  local i state
  for i in $(seq 1 "$CLUSTER_TIMEOUT"); do
    state="$(curl -sS "$api" | python3 -c 'import sys,json; print(json.load(sys.stdin)["properties"]["provisioningState"])')"
    echo "  AKS provisioningState: $state"
    [ "$state" = "Succeeded" ] && break
    sleep 5
  done
  [ "$state" = "Succeeded" ] || { echo "AKS cluster did not reach Succeeded." >&2; return 1; }
  cred="http://localhost:4577/subscriptions/tazama-sub/resourceGroups/tazama-rg/providers/Microsoft.ContainerService/managedClusters/tazama-aks/listClusterAdminCredential?api-version=2024-04-01"
  kube="${KUBE_DIR}/tazama-floci-aks.yaml"
  b64="$(curl -sS -X POST "$cred" | python3 -c 'import sys,json; print(json.load(sys.stdin)["kubeconfigs"][0]["value"])')"
  printf '%s' "$b64" | base64 -d > "$kube"
  export KUBECONFIG="$kube"
  kubectl get nodes
}

echo ""
echo "Floci cloud overlay test"
echo "  profile : $PROFILE"
echo "  sizing  : $SIZING"
echo "  clouds  : $CLOUDS"
echo ""
echo "This starts a k3s cluster per cloud through Floci. It does not talk to a real cloud account."

SUMMARY=""
FAILURES=0
TOTAL=0

for cloud in $CLOUDS; do
  echo ""
  printf -- '-%.0s' $(seq 62); echo ""
  echo "$cloud (floci)"
  printf -- '-%.0s' $(seq 62); echo ""

  status="PASS"
  detail=""
  started="$(date +%s)"
  emulator=""
  TOTAL=$(( TOTAL + 1 ))

  set +e
  case "$cloud" in
    eks) emulator=tazama-floci-aws; echo "Starting Floci AWS on :4566..."; start_aws && echo "Creating EKS (k3s) cluster..." && connect_eks ;;
    gke) emulator=tazama-floci-gcp; echo "Starting Floci GCP on :4588..."; start_gcp && echo "Creating GKE (k3s) cluster..." && connect_gke ;;
    aks) emulator=tazama-floci-az; echo "Starting Floci Azure on :4577..."; start_az && echo "Creating AKS (k3s) cluster..." && connect_aks ;;
  esac
  if [ $? -ne 0 ]; then
    status="FAIL"
    detail="cluster create or kubeconfig failed"
  else
    alias_storage
    echo "Clearing leftover Tazama releases..."
    clear_tazama
    set -- sync "$PROFILE" "$cloud" --sizing "$SIZING"
    if [ "$INCLUDE_RULES" != "true" ]; then
      set -- "$@" --selector 'tier!=rules'
    fi
    if [ "$REAL_LB" != "true" ]; then
      set -- "$@" --ingress-service-type NodePort
    fi
    echo "Installing Tazama ($cloud overlay)..."
    output="$("$LAUNCHER" "$@" 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
      status="FAIL"
      detail="$(printf '%s\n' "$output" | grep -m1 -E 'Error:|error:|failed|FAILED' | tr -s ' ' | cut -c1-120)"
    else
      echo "Waiting for pods..."
      kubectl wait --for=condition=Ready pods --all -n tazama --timeout="${READY_TIMEOUT}s" >/dev/null 2>&1
      bad="$(unhealthy_pods)"
      if [ -n "$bad" ]; then
        status="FAIL"
        detail="$(printf '%s\n' "$bad" | head -n 3 | paste -sd ',' -)"
      else
        echo "PASS, all pods Ready"
      fi
    fi
  fi
  set -e

  elapsed=$(( $(date +%s) - started ))
  [ "$status" = "PASS" ] || { FAILURES=$(( FAILURES + 1 )); echo "FAIL: $detail"; }
  SUMMARY="${SUMMARY}$(printf '%-8s %-5s %5ss  %s' "$cloud" "$status" "$elapsed" "$detail")
"

  if [ "$KEEP_RELEASES" != "true" ]; then
    echo "Tearing down Tazama..."
    clear_tazama
  fi
  [ -n "$emulator" ] && stop_floci "$emulator"
done

echo ""
echo "Summary"
printf '%s' "$SUMMARY"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES of $TOTAL Floci clouds failed."
  exit 1
fi
echo "All $TOTAL Floci clouds passed."
exit 0
