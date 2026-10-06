#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: ./tazama.sh <command> [profile] [cloud] [selector] [flags]

Commands: apply | destroy | status | diff | template | lint | sync | secrets
Profiles: core | full | private-rules
          (member is an alias for private-rules; dockerhub is an alias for full)
Clouds:   onprem | eks | gke | aks

Sizing flag:    --sizing standard|small|medium|large   (replica counts)

Package flags:  --cms --extensions --dems --deapi --tools
                --connection-studio --rule-studio --biar --postgres-replica
                --generate-secrets
Relay flags:    --relay-efrup|--relay-tp|--relay-ea nats|kafka|rabbitmq|rest
                --kafka-brokers|--rabbitmq-url|--rest-url VALUE
Database flags: --postgresql-host|--postgresql-replica-host VALUE
Ingress flags:  --ingress --ingress-domain DOMAIN [--ingress-class NAME]
                [--ingress-service-type LoadBalancer|NodePort]
Selector:       --selector LABEL   (or a positional label such as name=tms-service)
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
SIZING="standard"
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
INGRESS=0
INGRESS_DOMAIN=""
INGRESS_CLASS=""
INGRESS_SERVICE_TYPE=""
GENERATE_SECRETS=0

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
    --generate-secrets) GENERATE_SECRETS=1; shift ;;
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
    --sizing)
      need_value "$arg" "${2:-}"
      SIZING="$2"
      shift 2
      ;;
    --sizing=*) SIZING="${arg#*=}"; shift ;;
    --ingress) INGRESS=1; shift ;;
    --ingress-domain)
      need_value "$arg" "${2:-}"
      INGRESS_DOMAIN="$2"
      shift 2
      ;;
    --ingress-domain=*) INGRESS_DOMAIN="${arg#*=}"; shift ;;
    --ingress-class)
      need_value "$arg" "${2:-}"
      INGRESS_CLASS="$2"
      shift 2
      ;;
    --ingress-class=*) INGRESS_CLASS="${arg#*=}"; shift ;;
    --ingress-service-type)
      need_value "$arg" "${2:-}"
      INGRESS_SERVICE_TYPE="$2"
      shift 2
      ;;
    --ingress-service-type=*) INGRESS_SERVICE_TYPE="${arg#*=}"; shift ;;
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
  dockerhub)
    echo "Profile 'dockerhub' was renamed to 'full'. Using full." >&2
    PROFILE="full"
    ;;
  member)
    echo "Profile 'member' was renamed to 'private-rules'. Using private-rules." >&2
    PROFILE="private-rules"
    ;;
  core|full|private-rules) ;;
  *)
    echo "Unknown profile: $PROFILE (use core, full, or private-rules)" >&2
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

case "$SIZING" in
  standard|small|medium|large) ;;
  *)
    echo "Unknown sizing: $SIZING (use standard, small, medium, or large)" >&2
    exit 1
    ;;
esac

RELAY_EFRUP="$(printf '%s' "$RELAY_EFRUP" | tr '[:upper:]' '[:lower:]')"
RELAY_TP="$(printf '%s' "$RELAY_TP" | tr '[:upper:]' '[:lower:]')"
RELAY_EA="$(printf '%s' "$RELAY_EA" | tr '[:upper:]' '[:lower:]')"
validate_relay "--relay-efrup" "$RELAY_EFRUP"
validate_relay "--relay-tp" "$RELAY_TP"
validate_relay "--relay-ea" "$RELAY_EA"

if [[ -n "$INGRESS_SERVICE_TYPE" ]]; then
  case "$INGRESS_SERVICE_TYPE" in
    LoadBalancer|NodePort) ;;
    *)
      echo "--ingress-service-type must be LoadBalancer or NodePort. Got '$INGRESS_SERVICE_TYPE'." >&2
      exit 1
      ;;
  esac
fi

export TAZAMA_CLOUD="$CLOUD"
export TAZAMA_SIZING="$SIZING"

if [[ "$COMMAND" != "secrets" ]]; then
  if ! command -v helmfile >/dev/null 2>&1; then
    echo "helmfile is not on PATH. Install https://github.com/helmfile/helmfile/releases and retry." >&2
    exit 1
  fi

  if ! command -v helm >/dev/null 2>&1; then
    echo "helm is not on PATH. Install https://helm.sh/docs/intro/install/ and retry." >&2
    exit 1
  fi
fi

if [[ ! -f values/secrets.yaml ]]; then
  cp values/secrets.example.yaml values/secrets.yaml
  echo "Created values/secrets.yaml from the example file."
fi

new_secret() {
  # 15 random bytes encode to exactly 20 base64 characters (no padding).
  local s
  if command -v openssl >/dev/null 2>&1; then
    s="$(openssl rand -base64 15 | tr -d '\n=' | tr '+/' '-_')"
  else
    s="$(dd if=/dev/urandom bs=15 count=1 2>/dev/null | base64 | tr -d '\n=' | tr '+/' '-_')"
  fi
  printf '%s' "${s:0:20}"
}

is_dummy_secret() {
  local v="$1"
  v="${v%\"}"
  v="${v#\"}"
  v="${v%\'}"
  v="${v#\'}"
  case "$v" in
    unused|password|tazama|auth-lib-client-test-secret|"") return 0 ;;
    *) return 1 ;;
  esac
}

ensure_passwords() {
  local force="$1"
  local tmp section key val stripped secret changed=0
  local generated=()
  tmp="$(mktemp)"
  section=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]{2}([A-Za-z0-9_]+):[[:space:]]*$ ]]; then
      section="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ ^[[:space:]]{4}([A-Za-z0-9_]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "$section.$key" in
        postgres.password|postgres.replicationPassword|keycloak.adminPassword|keycloak.clientSecret|valkey.password)
          stripped="$val"
          stripped="${stripped%\"}"
          stripped="${stripped#\"}"
          if [[ "$force" -eq 1 ]] || is_dummy_secret "$stripped"; then
            secret="$(new_secret)"
            printf '    %s: "%s"\n' "$key" "$secret"
            generated+=("$section.$key")
            changed=1
            continue
          fi
          ;;
      esac
    fi
    printf '%s\n' "$line"
  done < values/secrets.yaml > "$tmp"
  if [[ "$changed" -eq 1 ]]; then
    mv "$tmp" values/secrets.yaml
    echo "Generated random secrets in values/secrets.yaml: ${generated[*]}."
    echo "Those strings are 20-character URL-safe secrets. Kubernetes Secret objects encode them again; keep this file as plaintext YAML."
    echo "If Postgres already initialized, changing postgres.password does not rewrite the role. Wipe the PVC or ALTER USER inside Postgres."
  else
    rm -f "$tmp"
  fi
}

ensure_auth_keys() {
  local force="$1"
  if [[ "$force" -ne 1 ]]; then
    if grep -Eq "BEGIN (RSA )?PRIVATE KEY" values/secrets.yaml \
      && ! grep -q "AQDQZ9laLMsoNk8q" values/secrets.yaml; then
      return 0
    fi
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    echo "Auth needs an RSA key pair in values/secrets.yaml. openssl was not found. Install openssl, or paste a matching publicKey and privateKey yourself. Never commit the private key." >&2
    exit 1
  fi
  work="$(mktemp -d)"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/private.pem" >/dev/null 2>&1
  openssl rsa -in "$work/private.pem" -pubout -out "$work/public.pem" >/dev/null 2>&1
  tmp="$(mktemp)"
  awk -v pubfile="$work/public.pem" -v prifile="$work/private.pem" '
    /^  auth:/ {
      print "  auth:"
      print "    publicKey: |"
      while ((getline line < pubfile) > 0) if (line != "") print "      " line
      close(pubfile)
      print "    privateKey: |"
      while ((getline line < prifile) > 0) if (line != "") print "      " line
      close(prifile)
      skip=1
      next
    }
    skip && /^  [a-zA-Z]/ { skip=0 }
    skip { next }
    { print }
  ' values/secrets.yaml > "$tmp"
  mv "$tmp" values/secrets.yaml
  rm -rf "$work"
  echo "Generated an Auth RSA key pair in values/secrets.yaml (gitignored). Do not commit that file."
}

ensure_passwords "$GENERATE_SECRETS"
ensure_auth_keys "$GENERATE_SECRETS"

if [[ "$COMMAND" == "secrets" ]]; then
  echo "Secrets written to values/secrets.yaml (gitignored). Each install gets its own 20-character URL-safe secrets. Do not commit that file."
  echo "Kubernetes Secret objects encode the same strings again. Keep plaintext in the YAML. Do not paste kubectl base64 data back into this file."
  exit 0
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

if [[ "$INGRESS" -eq 1 ]]; then
  add_set "ingress.enabled=true"
  add_set "install.ingressNginx=true"
fi
if [[ -n "$INGRESS_DOMAIN" ]]; then
  add_set_string "ingress.domain=$INGRESS_DOMAIN"
fi
if [[ -n "$INGRESS_CLASS" ]]; then
  add_set_string "ingress.className=$INGRESS_CLASS"
fi
if [[ -n "$INGRESS_SERVICE_TYPE" ]]; then
  add_set_string "ingressNginx.serviceType=$INGRESS_SERVICE_TYPE"
  add_set_string "ingress.nginx.serviceType=$INGRESS_SERVICE_TYPE"
fi

echo "Profile: $PROFILE"
echo "Cloud:   $CLOUD"
echo "Sizing:  $SIZING"
echo "Command: $COMMAND"

if [[ "$SIZING" != "standard" && ( "$COMMAND" == "apply" || "$COMMAND" == "sync" ) ]]; then
  echo "Sizing '$SIZING' raises replica counts. Confirm the cluster has capacity:"
  echo "  kubectl get nodes"
  echo "  kubectl top nodes"
fi

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
      echo "helm-diff plugin not found; using helmfile sync instead of apply." >&2
      echo "helm-diff can also skip nested helmfiles; for a first install prefer: ./tazama.sh sync $PROFILE $CLOUD" >&2
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
  if [[ "$INGRESS" -eq 1 || "$CLOUD" != "onprem" ]]; then
    echo "Ingress: kubectl get ingress -n tazama"
    echo "Map hosts (tms.<domain>, admin.<domain>, ...) in /etc/hosts or C:\\Windows\\System32\\drivers\\etc\\hosts if DNS is not set."
  else
    echo "Port-forward TMS (core profile / on-prem without ingress):"
    echo "  kubectl port-forward -n tazama svc/tms-service 3000:3000"
    echo "  kubectl port-forward -n tazama svc/admin-service 5100:5100"
  fi
fi
