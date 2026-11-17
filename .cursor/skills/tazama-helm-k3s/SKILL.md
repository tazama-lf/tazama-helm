---
name: tazama-helm-k3s
description: >-
  Tazama Helmfile wrapper command catalog (tazama.cmd / tazama.sh): sync,
  apply, destroy, profiles, clouds, sizing, package flags, relays, selectors.
  Use when the user asks which command to run, how to combine flags, first
  install vs upgrade, or mentions tazama.cmd, helmfile, -Profile, -Cms, -Biar,
  -Selector, or sync.
---

# Tazama Helmfile commands

For a from-scratch install (tools, cluster, sync, verify), use skill `tazama-helm-install` instead of this catalog.

Run from `tazama-Helms/`. **Windows:** `.\tazama.cmd` (never `.\tazama.ps1`). **Linux/macOS:** `./tazama.sh`.

This AWS, GCP, or Azure k3s box: set kubeconfig, then `-Cloud onprem` (not `eks` / `gke` / `aks`).

```powershell
cd tazama-Helms
$env:KUBECONFIG = "$PWD\infra\aws\kubeconfig.yaml"
# or $env:KUBECONFIG = "$PWD\infra\gcp\kubeconfig.yaml"
# or $env:KUBECONFIG = "$PWD\infra\azure\kubeconfig.yaml"
```

Shape:

```text
.\tazama.cmd <command> -Profile <profile> -Cloud <cloud> [-Sizing <tier>] [package flags...] [-Selector "<label>"]
./tazama.sh  <command> <profile> <cloud> [--sizing <tier>] [package flags...] [--selector <label>]
```

Omitted flags leave the profile YAML unchanged. Combine any package flags on one line.

## Commands

| Command | What it runs |
| --- | --- |
| `sync` | Always `helmfile sync`. Use for **first install**. |
| `apply` | `helmfile apply` if helm-diff is installed, otherwise `sync`. |
| `diff` | Preview |
| `template` | Render YAML |
| `status` | Release status |
| `lint` | Lint |
| `destroy` | Uninstall what this Helmfile owns |
| `secrets` | Write `values/secrets.yaml` only (no cluster) |
| `configure` | Load rules/typologies/network map from a local **tms-configuration** clone into admin-service |
| `tenant` | Run tazama-stack `add-tenant` against Keycloak (`TAZAMA.ORG` child groups and 12 users) |

Defaults if omitted: command `apply`, profile `core`, cloud `onprem`, sizing `standard`.

Allowed profiles: `core` | `full` | `private-rules` (`member` = private-rules, `dockerhub` = full).
Allowed clouds: `onprem` | `eks` | `gke` | `aks`.
Allowed sizing: `standard` | `small` | `medium` | `large`.

## Profiles (what they turn on)

- **core**: Admin, TMS, ED, EF, TP, EA, Auth, Keycloak, NATS relays, public rules, Postgres, NATS, Valkey. Replica off. Studios/CMS/BIAR off. `auth.authenticated` defaults to **true** (JWT on TMS/admin/CMS/studios/DEMS/DEAPI).
- **full**: core plus Connection Studio, Rule Studio, CMS (Flowable, CouchDB, OpenSearch), DEAPI, DEMS. BIAR still off.
- **private-rules**: same as `full`, rule images from a private registry (`environments/private-rules.yaml`).

## Package flags (additive on any profile)

| Windows | bash | Sets |
| --- | --- | --- |
| `-Cms` | `--cms` | CMS + Flowable + CouchDB + OpenSearch |
| `-Extensions` | `--extensions` | DEMS + DEAPI |
| `-Dems` | `--dems` | DEMS |
| `-Deapi` | `--deapi` | DEAPI |
| `-Tools` | `--tools` | Connection Studio + Rule Studio |
| `-ConnectionStudio` | `--connection-studio` | Connection Studio |
| `-RuleStudio` | `--rule-studio` | Rule Studio |
| `-Biar` | `--biar` | BIAR (NiFi) |
| `-PostgresReplica` | `--postgres-replica` | In-cluster Postgres replica |
| `-GenerateSecrets` | `--generate-secrets` | Rotate secrets in `values/secrets.yaml` |
| `-NoAuth` | `--no-auth` | `auth.authenticated=false` (JWT checks off; lab only) |
| `-EmptyRealm` | `--empty-realm` | `auth.emptyRealm=true` (Keycloak groups/roles, no login users) |

`-Cms` always enables Flowable, CouchDB, and OpenSearch in the same run.

**BIAR** needs a replica: pass `-PostgresReplica` (in-cluster) **or** `-PostgresqlReplicaHost <host>` (managed). Not both. Helmfile fails if BIAR is on and there is no replica host.

## Copy-paste recipes (Windows)

First install on this k3s cluster (full + BIAR):

```powershell
.\tazama.cmd sync -Profile full -Cloud onprem -Sizing medium -Biar -PostgresReplica
```

Core only:

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem
```

JWT off (lab only):

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -NoAuth
```

Keycloak with groups/roles but no login users (then create a tenant before configure):

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -EmptyRealm
.\tazama.cmd tenant
.\tazama.cmd configure -Truncate -AuthUser tazama-api-client@tazama.org -AuthPassword password
```

Core + CMS:

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -Cms
```

Core + DEMS/DEAPI + studios:

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -Extensions -Tools
```

One package on core:

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -Dems
.\tazama.cmd sync -Profile core -Cloud onprem -Deapi
.\tazama.cmd sync -Profile core -Cloud onprem -ConnectionStudio
.\tazama.cmd sync -Profile core -Cloud onprem -RuleStudio
```

Full (studios, CMS, enrichment; no BIAR):

```powershell
.\tazama.cmd sync -Profile full -Cloud onprem
```

Core + BIAR, in-cluster replica:

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -Biar -PostgresReplica
```

Core + BIAR, managed replica:

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -Biar -PostgresqlReplicaHost "mydb-ro.xxxx.rds.amazonaws.com"
```

Managed primary (turns in-cluster Postgres off):

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -PostgresqlHost "mydb.xxxx.rds.amazonaws.com"
```

On-prem ingress:

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -Ingress -IngressDomain tazama.local
```

Cloud (ingress already on in the overlay; set domain first):

```powershell
.\tazama.cmd sync -Profile core -Cloud eks -IngressDomain tm.example.com
.\tazama.cmd sync -Profile full -Cloud gke -IngressDomain tm.example.com
.\tazama.cmd sync -Profile core -Cloud aks -IngressDomain tm.example.com -Sizing medium
```

Relays (Helm does not install Kafka/RabbitMQ). Transports: `nats` | `kafka` | `rabbitmq` | `rest`.

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -RelayEa kafka -KafkaBrokers "kafka.example.com:9092"
.\tazama.cmd sync -Profile core -Cloud onprem -RelayEa rabbitmq -RabbitmqUrl "amqp://user:pass@rabbit.example.com:5672"
.\tazama.cmd sync -Profile core -Cloud onprem -RelayEa rest -RestUrl "https://relay.example.com/intake"
.\tazama.cmd sync -Profile core -Cloud onprem -RelayEfrup kafka -RelayTp kafka -RelayEa kafka -KafkaBrokers "kafka.example.com:9092"
```

Same flags work on `apply`, `diff`, `template`, `status`, `lint`, `destroy`.

## Selectors (one release or one tier)

`-Selector` is Helmfile `-l`.

```powershell
.\tazama.cmd sync -Profile full -Cloud onprem -Selector "name=tms-service"
.\tazama.cmd sync -Profile full -Cloud onprem -Selector "name=dems"
.\tazama.cmd sync -Profile full -Cloud onprem -Selector "tier=extensions"
.\tazama.cmd destroy -Profile core -Cloud onprem -Selector "name=tms-service"
```

Labels: `name=<release>` (`tms-service`, `postgresql`, `rule-902`, `cms-backend`, `keycloak`, …) or `tier=datastore|auxiliary|core|rules|extensions|biar`.

## Load TMS configuration (private repo)

The Postman collection and `curl/` payloads live in private [frmscoe/tms-configuration](https://github.com/frmscoe/tms-configuration). This wrapper does not copy them. Each operator clones that repo with their GitHub access, then `configure` posts the payloads. This stack has no Hasura: use Admin-Service only (the default runner).

Clone next to `tazama-Helms/` (or pass `-TmsConfigPath`):

```powershell
git clone https://github.com/frmscoe/tms-configuration
```

Default runner (same inject as the collection's **Admin-Service API** folder, no Postman/Newman). Use `-Truncate` on the first load so sample 901/902 does not collide (`rule_pkey`):

```powershell
.\tazama.cmd configure -Truncate
.\tazama.cmd configure
.\tazama.cmd configure -TmsConfigPath "H:\path\to\tms-configuration"
.\tazama.cmd configure -AdminUrl "http://admin.tazama.local"
.\tazama.cmd configure -SkipAuth
.\tazama.cmd configure -Truncate -AuthUser tazama-api-client@tazama.org -AuthPassword password
```

Newman (still from the private clone; runs **Admin-Service API / v4.0.0** only, skips Hasura):

```powershell
npm install -g newman
.\tazama.cmd configure -Newman
```

```bash
./tazama.sh configure --truncate
./tazama.sh configure
./tazama.sh configure --tms-config-path /path/to/tms-configuration
./tazama.sh configure --newman
./tazama.sh configure --skip-auth
./tazama.sh configure --truncate --auth-user tazama-api-client@tazama.org --auth-password password
```

`configure` port-forwards `admin-service:5100` when the URL is localhost, then POSTs `curl/rule-configs.json`, `typology-configs.json`, `network-map.json`, and activate **with a JWT** (`tazama-user@tazama.org` / `password` unless `-AuthUser` / `-AuthPassword`). It restarts ED / TP / EA unless `-SkipRestart` / `--skip-restart`. Use `-Truncate` / `--truncate` on the first load: it clears `rule`, `typology`, and `network_map` so sample 901/902 does not hit `rule_pkey`. `-SkipAuth` / `--skip-auth` skips the token; only use that with `-NoAuth`. After `-EmptyRealm`, run `tenant` first, then `configure -AuthUser tazama-api-client@tazama.org`. `-Auth` / `--auth` is accepted and is the default.

Confirm the rows in Postgres (`configuration` database). Sample 901/902 is two rules; after `-Truncate` you should see many more (public v4 payloads are typically around 34 / 6 / 1):

```powershell
kubectl exec -n tazama postgresql-0 -- psql -U postgres -d configuration -c "SELECT 'rule' AS table, count(*) FROM rule UNION ALL SELECT 'typology', count(*) FROM typology UNION ALL SELECT 'network_map', count(*) FROM network_map;"
kubectl exec -n tazama postgresql-0 -- psql -U postgres -d configuration -c "SELECT configuration->>'cfg' AS cfg, configuration->>'tenantId' AS tenant_id, configuration->>'active' AS active FROM network_map;"
```

Expect `cfg` `4.0.0`, tenant `DEFAULT`, `active` `true`.

Do not commit the private collection into this repo.

## Keycloak tenant groups (TAZAMA.ORG)

The realm import is the tazama-stack skeleton only. Nested domain groups and `tazama-api-client` are **not** in that JSON. After Keycloak is Ready:

```powershell
.\tazama.cmd tenant
.\tazama.cmd tenant -Domain tazama.org -TenantId TAZAMA -TenantPassword password
```

```bash
./tazama.sh tenant
./tazama.sh tenant --domain tazama.org --tenant-id TAZAMA --tenant-password password
```

That is the same `add-tenant.py` / `add-tenant.js` as [tazama-stack](https://github.com/tazama-lf/tazama-stack). It creates `TAZAMA.ORG` under CMS roles, TCS/TRS roles, and `tazama-batch` / `tazama-conditions` / `tazama-config` / `tazama-jupyter` / `tazama-nifi` / `tazama-reports` / `tazama-tms`, then attaches the 12 users.

## Other wrapper commands

```powershell
.\tazama.cmd secrets
.\tazama.cmd secrets -GenerateSecrets
.\tazama.cmd diff -Profile full -Cloud onprem -Biar -PostgresReplica
.\tazama.cmd template -Profile core -Cloud onprem -Cms
.\tazama.cmd status -Profile full -Cloud onprem
.\tazama.cmd lint -Profile core -Cloud onprem
.\tazama.cmd destroy -Profile full -Cloud onprem
```

Raw Helmfile (same folder):

```powershell
helmfile -e full -f helmfile.yaml.gotmpl sync
helmfile -e core -f helmfile.yaml.gotmpl -l name=cms-backend destroy
helmfile -e core -f helmfile.yaml.gotmpl -l tier=rules apply
```

If `$env:KUBECONFIG` is set, the wrapper passes `--kubeconfig`.

## bash equivalents

```bash
./tazama.sh sync full onprem --sizing medium --biar --postgres-replica
./tazama.sh sync core onprem --cms
./tazama.sh sync core onprem --extensions --tools
./tazama.sh sync core onprem --no-auth
./tazama.sh sync core onprem --empty-realm
./tazama.sh configure --truncate --auth-user tazama-api-client@tazama.org --auth-password password
./tazama.sh destroy core onprem name=tms-service
```
