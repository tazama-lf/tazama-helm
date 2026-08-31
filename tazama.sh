#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: ./tazama.sh apply|destroy|status|diff|template|lint|sync [core|dockerhub|member] [onprem|eks|gke|aks] [selector] [flags]

Package switches (omit a flag to keep the profile YAML default):
  --cms
  --extensions | --dems | --deapi
  --tools | --connection-studio | --rule-studio
  --biar
  --postgres-replica

Relay strings (nats|kafka|rabbitmq|rest; default nats if omitted):
  --relay-efrup VALUE
  --relay-tp VALUE
  --relay-ea VALUE
  --kafka-brokers VALUE
  --rabbitmq-url VALUE
  --rest-url VALUE

Managed DB:
  --postgresql-host VALUE
  --postgresql-replica-host VALUE

Selector:
  --selector VALUE   (or a positional label such as name=tms-service)
EOF
}

COMMAND="${1:-apply}"
if [[ "$COMMAND" == "-h" || "$COMMAND" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

PROFILE="core"
CLOUD="onprem"
SELECTOR=""
PROFILE_SET=0
CLOUD_SET=0

CMS=0
EXTENSIONS=0
DEMS=0
DEAPI=0
TOOLS=0
CONNECTION_STUDIO=0
RULE_STUDIO=0
BIAR=0
POSTGRES_REPLICA=0
RELAY_EFRUP=""
RELAY_TP=""
RELAY_EA=""
KAFKA_BROKERS=""
RABBITMQ_URL=""
REST_URL=""
POSTGRESQL_HOST=""
POSTGRESQL_REPLICA_HOST=""

need_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == -* ]]; then
    echo "Flag $flag requires a value." >&2
    usage >&2
    exit 1
  fi
}

validate_relay() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    return 0
  fi
  case "$value" in
    nats|kafka|rabbitmq|rest) ;;
    *)
      echo "$name must be nats, kafka, rabbitmq, or rest. Got '$value'." >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --cms) CMS=1; shift ;;
    --extensions) EXTENSIONS=1; shift ;;
    --dems) DEMS=1; shift ;;
    --deapi) DEAPI=1; shift ;;
    --tools) TOOLS=1; shift ;;
    --connection-studio) CONNECTION_STUDIO=1; shift ;;
    --rule-studio) RULE_STUDIO=1; shift ;;
    --biar) BIAR=1; shift ;;
    --postgres-replica) POSTGRES_REPLICA=1; shift ;;
    --relay-efrup)
      need_value "$arg" "${2:-}"
      RELAY_EFRUP="$2"
      shift 2
      ;;
    --relay-efrup=*) RELAY_EFRUP="${arg#*=}"; shift ;;
    --relay-tp)
      need_value "$arg" "${2:-}"
      RELAY_TP="$2"
      shift 2
      ;;
    --relay-tp=*) RELAY_TP="${arg#*=}"; shift ;;
    --relay-ea)
      need_value "$arg" "${2:-}"
      RELAY_EA="$2"
      shift 2
      ;;
    --relay-ea=*) RELAY_EA="${arg#*=}"; shift ;;
    --kafka-brokers)
      need_value "$arg" "${2:-}"
      KAFKA_BROKERS="$2"
      shift 2
      ;;
    --kafka-brokers=*) KAFKA_BROKERS="${arg#*=}"; shift ;;
    --rabbitmq-url)
      need_value "$arg" "${2:-}"
      RABBITMQ_URL="$2"
      shift 2
      ;;
    --rabbitmq-url=*) RABBITMQ_URL="${arg#*=}"; shift ;;
    --rest-url)
      need_value "$arg" "${2:-}"
      REST_URL="$2"
      shift 2
      ;;
    --rest-url=*) REST_URL="${arg#*=}"; shift ;;
    --postgresql-host)
      need_value "$arg" "${2:-}"
      POSTGRESQL_HOST="$2"
      shift 2
      ;;
    --postgresql-host=*) POSTGRESQL_HOST="${arg#*=}"; shift ;;
    --postgresql-replica-host)
      need_value "$arg" "${2:-}"
      POSTGRESQL_REPLICA_HOST="$2"
      shift 2
      ;;
    --postgresql-replica-host=*) POSTGRESQL_REPLICA_HOST="${arg#*=}"; shift ;;
    --selector|-l)
      need_value "$arg" "${2:-}"
      SELECTOR="$2"
      shift 2
      ;;
    --selector=*) SELECTOR="${arg#*=}"; shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown flag: $arg" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ "$PROFILE_SET" -eq 0 ]]; then
        PROFILE="$arg"
        PROFILE_SET=1
      elif [[ "$CLOUD_SET" -eq 0 ]]; then
        CLOUD="$arg"
        CLOUD_SET=1
      elif [[ -z "$SELECTOR" ]]; then
        SELECTOR="$arg"
      else
        echo "Unexpected argument: $arg" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

case "$COMMAND" in
  apply|destroy|status|diff|template|lint|sync) ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac

case "$PROFILE" in
  core|dockerhub|member) ;;
  *)
    echo "Unknown profile: $PROFILE (use core, dockerhub, or member)" >&2
    exit 1
    ;;
esac

case "$CLOUD" in
  onprem|eks|gke|aks) ;;
  *)
    echo "Unknown cloud: $CLOUD (use onprem, eks, gke, or aks)" >&2
    exit 1
    ;;
esac

RELAY_EFRUP="$(printf '%s' "$RELAY_EFRUP" | tr '[:upper:]' '[:lower:]')"
RELAY_TP="$(printf '%s' "$RELAY_TP" | tr '[:upper:]' '[:lower:]')"
RELAY_EA="$(printf '%s' "$RELAY_EA" | tr '[:upper:]' '[:lower:]')"
validate_relay "--relay-efrup" "$RELAY_EFRUP"
validate_relay "--relay-tp" "$RELAY_TP"
validate_relay "--relay-ea" "$RELAY_EA"

export TAZAMA_CLOUD="$CLOUD"

if ! command -v helmfile >/dev/null 2>&1; then
  echo "helmfile is not on PATH. Install https://github.com/helmfile/helmfile/releases and retry." >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is not on PATH. Install https://helm.sh/docs/intro/install/ and retry." >&2
  exit 1
fi

if [[ ! -f values/secrets.yaml ]]; then
  cp values/secrets.example.yaml values/secrets.yaml
  echo "Created values/secrets.yaml from the example file."
  echo "Default passwords match tazama-stack docker defaults (postgres / unused)."
  echo "Change them before installing on a shared or cloud cluster."
fi

STATE_SETS=()
STRING_SETS=()

add_set() {
  STATE_SETS+=("$1")
}

add_set_string() {
  STRING_SETS+=("$1")
}

if [[ "$CMS" -eq 1 ]]; then
  add_set "install.cms=true"
  add_set "install.flowable=true"
  add_set "install.couchdb=true"
  add_set "install.opensearch=true"
fi
if [[ "$EXTENSIONS" -eq 1 ]]; then
  add_set "install.dems=true"
  add_set "install.deapi=true"
fi
if [[ "$DEMS" -eq 1 ]]; then
  add_set "install.dems=true"
fi
if [[ "$DEAPI" -eq 1 ]]; then
  add_set "install.deapi=true"
fi
if [[ "$TOOLS" -eq 1 ]]; then
  add_set "install.connectionStudio=true"
  add_set "install.ruleStudio=true"
fi
if [[ "$CONNECTION_STUDIO" -eq 1 ]]; then
  add_set "install.connectionStudio=true"
fi
if [[ "$RULE_STUDIO" -eq 1 ]]; then
  add_set "install.ruleStudio=true"
fi
if [[ "$BIAR" -eq 1 ]]; then
  add_set "install.biar=true"
fi
if [[ "$POSTGRES_REPLICA" -eq 1 ]]; then
  add_set "install.postgresqlReplica=true"
fi

if [[ -n "$RELAY_EFRUP" ]]; then
  add_set_string "relay.efrup.transport=$RELAY_EFRUP"
fi
if [[ -n "$RELAY_TP" ]]; then
  add_set_string "relay.tp.transport=$RELAY_TP"
fi
if [[ -n "$RELAY_EA" ]]; then
  add_set_string "relay.ea.transport=$RELAY_EA"
fi
if [[ -n "$KAFKA_BROKERS" ]]; then
  add_set_string "relay.kafka.brokers=$KAFKA_BROKERS"
fi
if [[ -n "$RABBITMQ_URL" ]]; then
  add_set_string "relay.rabbitmq.url=$RABBITMQ_URL"
fi
if [[ -n "$REST_URL" ]]; then
  add_set_string "relay.rest.url=$REST_URL"
fi

if [[ -n "$POSTGRESQL_HOST" ]]; then
  add_set_string "hosts.postgresql=$POSTGRESQL_HOST"
  add_set "install.postgresql=false"
fi
if [[ -n "$POSTGRESQL_REPLICA_HOST" ]]; then
  add_set_string "hosts.postgresqlReplica=$POSTGRESQL_REPLICA_HOST"
  add_set "install.postgresqlReplica=false"
fi

echo "Profile: $PROFILE"
echo "Cloud:   $CLOUD"
echo "Command: $COMMAND"

ARGS=(-e "$PROFILE" -f helmfile.yaml.gotmpl)
if [[ -n "${KUBECONFIG:-}" ]]; then
  ARGS=(--kubeconfig "$KUBECONFIG" "${ARGS[@]}")
fi
if [[ -n "$SELECTOR" ]]; then
  ARGS+=(-l "$SELECTOR")
fi
if [[ ${#STATE_SETS[@]} -gt 0 ]]; then
  for pair in "${STATE_SETS[@]}"; do
    ARGS+=(--state-values-set "$pair")
  done
fi
if [[ ${#STRING_SETS[@]} -gt 0 ]]; then
  for pair in "${STRING_SETS[@]}"; do
    ARGS+=(--state-values-set-string "$pair")
  done
fi

if [[ ${#STATE_SETS[@]} -gt 0 || ${#STRING_SETS[@]} -gt 0 ]]; then
  echo "Overrides (helmfile --state-values-set):"
  if [[ ${#STATE_SETS[@]} -gt 0 ]]; then
    for pair in "${STATE_SETS[@]}"; do
      echo "  --state-values-set $pair"
    done
  fi
  if [[ ${#STRING_SETS[@]} -gt 0 ]]; then
    for pair in "${STRING_SETS[@]}"; do
      echo "  --state-values-set-string $pair"
    done
  fi
fi

case "$COMMAND" in
  apply)
    if helm plugin list 2>/dev/null | grep -q '^diff'; then
      helmfile "${ARGS[@]}" apply
    else
      echo "helm-diff plugin not found; using helmfile sync instead of apply."
      helmfile "${ARGS[@]}" sync
    fi
    ;;
  sync) helmfile "${ARGS[@]}" sync ;;
  destroy) helmfile "${ARGS[@]}" destroy ;;
  diff) helmfile "${ARGS[@]}" diff ;;
  status) helmfile "${ARGS[@]}" status ;;
  template) helmfile "${ARGS[@]}" template ;;
  lint) helmfile "${ARGS[@]}" lint ;;
esac

if [[ "$COMMAND" == "apply" ]]; then
  echo
  echo "Install submitted. Watch pods with:"
  echo "  kubectl get pods -n tazama -w"
  echo "Port-forward TMS (core profile / on-prem without ingress):"
  echo "  kubectl port-forward -n tazama svc/tms-service 3000:3000"
  echo "  kubectl port-forward -n tazama svc/admin-service 5100:5100"
fi
