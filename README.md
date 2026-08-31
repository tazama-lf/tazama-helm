# Tazama on Kubernetes

This repository installs the Tazama transaction-monitoring stack on a Kubernetes cluster.

**Kubernetes** is software that runs containers (packaged applications) on one or more machines. You talk to the cluster with `kubectl`. **Helm** is the usual package manager for Kubernetes; a Helm *chart* is one installable package. This repo uses **Helmfile**, a tool that reads one file and installs many Helm charts together.

Clone this repo and run the wrapper scripts below.

This is a sandbox- and demo-capable, production-oriented Helmfile stack. It is not a full GitOps platform. Pass wrapper flags, then run apply again.

**WARNING:** The example passwords are for first boot only. Generate or paste your own Auth private key locally and never commit it. Replace credentials, pin image tags, and prefer a managed database before any shared or production cluster.

Related history: this is the Helm/Helmfile form of [tazama-stack](https://github.com/tazama-lf/tazama-stack). It is not a copy of the public Docker Compose test stack (that stack leaves Auth off). Older cloud-only repos: [On-Prem-helm](https://github.com/tazama-lf/On-Prem-helm), [EKS-helm](https://github.com/tazama-lf/EKS-helm), [GKE-helm](https://github.com/tazama-lf/GKE-helm), [AKS-helm](https://github.com/tazama-lf/AKS-helm).

## What you need on your machine

You need all of the following:

1. A Kubernetes cluster, and `kubectl` pointing at it. Check with `kubectl get nodes`.
2. [Helm 3](https://helm.sh/docs/intro/install/) on your `PATH`.
3. [Helmfile](https://github.com/helmfile/helmfile/releases) 1.x on your `PATH`. This repo’s entry file is `helmfile.yaml.gotmpl` (Helmfile 1.x Go-template format). Download a release, put `helmfile` (or `helmfile.exe` on Windows) somewhere on your `PATH`, then confirm with `helmfile version`.
4. Cluster disk that can bind a **PVC** (PersistentVolumeClaim: a request for disk that survives pod restarts). Examples: local-path, Longhorn, EBS CSI, GCE PD, Azure Disk.
5. Network access to pull `docker.io/tazamaorg/*`. If those images are private, set a pull secret (see [Secrets and passwords](#secrets-and-passwords)).

**Windows:** use PowerShell and `tazama.ps1`. **Linux and macOS:** use bash and `tazama.sh`. Helmfile must be on `PATH` in both cases. The scripts look up `helmfile` and `helm` by name; they will stop if either is missing.

Optional: the [helm-diff](https://github.com/databus23/helm-diff) plugin (`helm plugin install https://github.com/databus23/helm-diff`). If it is missing, `apply` still works. The wrapper switches to `helmfile sync` instead of `helmfile apply`.

Optional for public hostnames: an ingress controller, or set `install.ingressNginx: true`. Cloud overlays for EKS, GKE, and AKS turn that on for you. You also need DNS for `*.your-domain` when ingress is enabled.

## How install works

You run `tazama.ps1` or `tazama.sh`. The wrapper sets the cloud name, then runs Helmfile against `helmfile.yaml.gotmpl`. Helmfile installs many independent Helm *releases* (Postgres, NATS, TMS, rules, and so on) so you can add or remove pieces later without uninstalling the whole cluster.

A **profile** is a named set of on/off flags (`core`, `dockerhub`, or `member`). **Values** are the YAML settings Helmfile merges (image tag, passwords, which packages are on). A **namespace** is a named folder inside the cluster. This stack uses `tazama` by default. A **pod** is one running instance of a container.

The primary way to turn packages on is a one-liner flag. Omitted flags leave the profile YAML unchanged (`environments/core.yaml`, `environments/dockerhub.yaml`, or `environments/member.yaml`, plus `values/defaults.yaml`). You do not need to edit YAML for a first install. Editing YAML is an [advanced](#advanced-persist-flags-in-yaml) way to persist the same settings in git.

## Quick start

Work from this folder (the repo root that contains `tazama.ps1` and `tazama.sh`).

**PowerShell:**

```powershell
copy values\secrets.example.yaml values\secrets.yaml
.\tazama.ps1 apply -Profile core -Cloud onprem
kubectl get pods -n tazama -w
```

**bash:**

```bash
chmod +x tazama.sh
cp values/secrets.example.yaml values/secrets.yaml
./tazama.sh apply core onprem
kubectl get pods -n tazama -w
```

The first run copies `values/secrets.example.yaml` to `values/secrets.yaml` if the file is missing. Default passwords match tazama-stack Docker (`postgres` / `unused`). Change them before any shared cluster.

Wait until Postgres and the processors are Ready. Then use **port-forward** (a `kubectl` tunnel from a cluster service to your laptop) to reach TMS, the Transaction Monitoring Service:

**PowerShell:**

```powershell
kubectl port-forward -n tazama svc/tms-service 3000:3000
kubectl port-forward -n tazama svc/admin-service 5100:5100
kubectl port-forward -n tazama svc/auth-service 3020:3020
kubectl port-forward -n tazama svc/keycloak 8080:8080
curl http://localhost:3000
```

**bash:** the same `kubectl` and `curl` commands.

Expect `{"status":"UP"}` from TMS once schema init and processor waits have finished. The first boot can take several minutes while Postgres runs `00-CREATE.sql` and `10-core-config.sql`, and while Keycloak imports the tazama realm.

Press Ctrl+C to stop `kubectl get pods -w` or a port-forward when you are done watching.

## What core installs

The `core` profile (`environments/core.yaml`) turns on infrastructure plus the transaction pipeline.

| Piece | What it is |
| --- | --- |
| Admin | Configuration and admin API (`admin-service`, port 5100) |
| TMS | Transaction Monitoring Service, the intake API (`tms-service`, port 3000) |
| ED | Event Director |
| EF | Event Flow |
| TP | Typology Processor |
| EA | Event Adjudicator |
| Auth | Auth service (`auth-service`, port 3020) |
| Keycloak | Login and tokens (`keycloak`, port 8080). Image `quay.io/keycloak/keycloak:23.0.6` |
| Three relays | Forward EF, TP, and EA output (default destination: NATS) |
| Rules 901 and 902 | Public rule images listed in `rules.enabled` |
| Postgres | In-cluster database (groundhog2k chart) plus SQL schema and sample typology |
| NATS | Message bus with JetStream |
| Valkey | In-memory cache (Redis-compatible) |

Auth and Keycloak are installed even when `auth.authenticated` is `false` (the default). TMS and Admin do not require JWTs until you set that flag to `true`.

The in-cluster Postgres replica is **off** in core. Ingress-nginx is **off** for `onprem`.

## Wrapper flags

These are the flags `tazama.ps1` and `tazama.sh` accept. Omitted flags leave the environment YAML defaults. Combine any of them on one command. PowerShell switches also accept `-Cms:$true` (same for the other switches).

Copy-paste recipes are in [Example installations](#example-installations).

### Package switches

| What | PowerShell | bash | Helmfile keys set to true |
| --- | --- | --- | --- |
| CMS. Also enables Flowable, CouchDB, and OpenSearch (CMS needs them) | `-Cms` | `--cms` | `install.cms`, `install.flowable`, `install.couchdb`, `install.opensearch` |
| DEMS and DEAPI | `-Extensions` | `--extensions` | `install.dems`, `install.deapi` |
| DEMS only | `-Dems` | `--dems` | `install.dems` |
| DEAPI only | `-Deapi` | `--deapi` | `install.deapi` |
| Connection Studio and Rule Studio | `-Tools` | `--tools` | `install.connectionStudio`, `install.ruleStudio` |
| Connection Studio only | `-ConnectionStudio` | `--connection-studio` | `install.connectionStudio` |
| Rule Studio only | `-RuleStudio` | `--rule-studio` | `install.ruleStudio` |
| BIAR (NiFi) | `-Biar` | `--biar` | `install.biar` |
| In-cluster Postgres replica | `-PostgresReplica` | `--postgres-replica` | `install.postgresqlReplica` |

`-Cms` / `--cms` always turns on Flowable, CouchDB, and OpenSearch in the same run. You do not pass extra flags for those three.

### Relay strings

Each value must be `nats`, `kafka`, `rabbitmq`, or `rest`. If you omit a relay flag, the profile YAML keeps its default (NATS in core).

| What | PowerShell | bash | Helmfile key |
| --- | --- | --- | --- |
| Event Flow / EFRuP relay transport | `-RelayEfrup <value>` | `--relay-efrup <value>` | `relay.efrup.transport` |
| Typology Processor relay transport | `-RelayTp <value>` | `--relay-tp <value>` | `relay.tp.transport` |
| Event Adjudicator relay transport | `-RelayEa <value>` | `--relay-ea <value>` | `relay.ea.transport` |
| Kafka brokers (required when any transport is `kafka`) | `-KafkaBrokers <host:port>` | `--kafka-brokers <host:port>` | `relay.kafka.brokers` |
| RabbitMQ URL (required when any transport is `rabbitmq`) | `-RabbitmqUrl <url>` | `--rabbitmq-url <url>` | `relay.rabbitmq.url` |
| REST URL (required when any transport is `rest`) | `-RestUrl <url>` | `--rest-url <url>` | `relay.rest.url` |

Helm does **not** install Kafka or RabbitMQ. NATS is the only broker this stack starts. If you set a relay to `kafka`, you must already have brokers and pass `-KafkaBrokers` / `--kafka-brokers`. Same for RabbitMQ and REST. Helmfile fails with a clear error if those URLs are missing.

### PostgreSQL hosts

| What | PowerShell | bash | Helmfile keys |
| --- | --- | --- | --- |
| Managed primary (also turns in-cluster Postgres off) | `-PostgresqlHost <host>` | `--postgresql-host <host>` | `hosts.postgresql`, `install.postgresql=false` |
| Managed replica (also turns the in-cluster replica off) | `-PostgresqlReplicaHost <host>` | `--postgresql-replica-host <host>` | `hosts.postgresqlReplica`, `install.postgresqlReplica=false` |

## Optional packages

These stay off in `core`. Turn them on with a wrapper flag from the table above, then run apply again. The `dockerhub` profile already enables most of this list.

| Package | Flag | What you get |
| --- | --- | --- |
| DEMS | `-Dems` / `--dems` (or `-Extensions`) | Event monitoring service |
| DEAPI | `-Deapi` / `--deapi` (or `-Extensions`) | Data enrichment service |
| TCS | `-ConnectionStudio` / `--connection-studio` (or `-Tools`) | Connection Studio (frontend + backend). Ingress hosts `tcs` and `tcs-api` |
| TRS | `-RuleStudio` / `--rule-studio` (or `-Tools`) | Rule Studio (frontend + backend). Ingress hosts `trs` and `trs-api` |
| CMS | `-Cms` / `--cms` | Case Management System (frontend + backend), plus Flowable, CouchDB, and OpenSearch |
| BIAR | `-Biar` / `--biar` | NiFi reference workload. Needs a Postgres replica (see below) |

The `dockerhub` profile also turns on OpenSearch, CouchDB, and Flowable, plus a longer public rule list. Those support CMS and the studios. BIAR stays off until you enable it yourself.

## Relays

Core deploys three relays:

- `relay-service-ef` (Event Flow / EFRuP)
- `relay-service-tp` (Typology Processor)
- `relay-service-ea` (Event Adjudicator)

The default destination transport is **NATS** (the in-cluster JetStream broker). Set each relay independently with `-RelayEfrup` / `--relay-efrup` (and the TP / EA flags).

Relays still consume from in-cluster NATS. The transport setting only changes where they produce. Images are `tazamaorg/relay-service-integration-<transport>`.

See [Example installations](#example-installations) for Kafka, RabbitMQ, and REST one-liners.

## BIAR and the Postgres replica

BIAR’s NiFi job should not hit the primary database.

Passing `-Biar` / `--biar` does **not** start a replica by itself. Choose one:

1. **In-cluster replica:** pass `-Biar -PostgresReplica` (`--biar --postgres-replica`). Helm starts a streaming replica of `postgresql` and a Service `postgresql-replica`. NiFi uses `hosts.postgresqlReplica` (default `postgresql-replica`).
2. **Managed replica:** pass `-Biar -PostgresqlReplicaHost <endpoint>` (`--biar --postgresql-replica-host`). That sets `install.postgresqlReplica=false` and points `hosts.postgresqlReplica` at RDS, Cloud SQL, or Azure Database. Keep `values/secrets.yaml` in sync with that database user.

Helmfile fails if BIAR is on, the in-cluster replica is off, and `hosts.postgresqlReplica` is still the default `postgresql-replica`.

Application env still expects the Tazama database names (`configuration`, `raw_history`, `event_history`, `evaluation`). Create a `keycloak` database if you keep Keycloak on managed Postgres.

## Profiles and clouds

Set the profile with `-Profile` (PowerShell) or the second argument (`tazama.sh`).

| Profile | Files | What it turns on |
| --- | --- | --- |
| `core` | `environments/core.yaml` | Infra, Admin, TMS, ED, EF, TP, EA, Auth, Keycloak, three relays, rules 901 and 902 |
| `dockerhub` | `environments/dockerhub.yaml` | Core plus the public rule list, TCS, TRS, CMS, DEAPI, DEMS, OpenSearch, CouchDB, Flowable |
| `member` | dockerhub + `environments/member.yaml` | Same as dockerhub. `rules.imageRegistry` is commented out; uncomment it (example `ghcr.io/frmscoe`) to pull private rule images |

Set the cloud with `-Cloud` (PowerShell) or the third argument. The wrapper exports `TAZAMA_CLOUD` and Helmfile loads `environments/cloud/<name>.yaml`.

| Cloud | Storage class | Ingress-nginx | Notes |
| --- | --- | --- | --- |
| `onprem` | cluster default (empty) | off | k3d, kind, kubeadm, RKE2. Use port-forward, or enable ingress yourself |
| `eks` | `gp3` | on, NLB annotations | Needs the AWS EBS CSI driver |
| `gke` | `standard-rwo` | on | Use `premium-rwo` in the overlay if you want SSD |
| `aks` | `managed-csi` | on, Azure probe path | Needs the Azure Disk CSI driver |

```powershell
.\tazama.ps1 apply -Profile core -Cloud eks
.\tazama.ps1 apply -Profile dockerhub -Cloud gke
.\tazama.ps1 apply -Profile core -Cloud aks
```

```bash
./tazama.sh apply core eks
./tazama.sh apply dockerhub gke
./tazama.sh apply core aks
```

Before a cloud install:

1. Replace every password in `values/secrets.yaml`.
2. Set `ingress.domain` in the cloud overlay (or another values file you overlay) to a DNS name you control.
3. Confirm the StorageClass exists: `kubectl get storageclass`.
4. For EKS, create `gp3` if your cluster only has `gp2`.
5. Pin `global.tazamaVersion` to a tested tag instead of `rc` when you care about repeatability.

When ingress is enabled:

- TMS: `tms.<ingress.domain>`
- Admin: `admin.<ingress.domain>`
- Auth: `auth.<ingress.domain>`
- Keycloak: `keycloak.<ingress.domain>`
- Connection Studio: `tcs.<ingress.domain>` and `tcs-api.<ingress.domain>`
- Rule Studio: `trs.<ingress.domain>` and `trs-api.<ingress.domain>`
- CMS: `cms.<ingress.domain>` and `cms-api.<ingress.domain>`
- NiFi (when BIAR is on): `nifi.<ingress.domain>`

## Example installations

The wrappers take a command, a profile, a cloud, optional package switches, and optional relay or host strings. Omitted flags leave the profile YAML unchanged. Combine switches on one command. Auth and Keycloak stay on in `core`; the wrappers do not turn them off.

Copy `values/secrets.example.yaml` to `values/secrets.yaml` once, as in [Quick start](#quick-start). Work from this folder.

### 1. Core only (default)

When to use it: a first on-prem install of the transaction pipeline, with no studios, CMS, or BIAR.

`environments/core.yaml` already turns on Admin, TMS, ED, EF, TP, EA, Auth, Keycloak, three NATS relays, rules 901 and 902, Postgres, NATS, and Valkey. The in-cluster Postgres replica stays off.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem
```

**bash:**

```bash
./tazama.sh apply core onprem
```

### 2. Core plus CMS

When to use it: Case Management on a core cluster. `-Cms` / `--cms` also turns on Flowable, CouchDB, and OpenSearch (CMS is invalid without them).

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -Cms
```

**bash:**

```bash
./tazama.sh apply core onprem --cms
```

The `dockerhub` profile already turns CMS on with those three dependencies.

### 3. Core plus extensions and tools

When to use it: DEMS and DEAPI (`-Extensions` / `--extensions`) plus Connection Studio and Rule Studio (`-Tools` / `--tools`) on core, without the full `dockerhub` profile. `-Dems` / `-Deapi` / `-ConnectionStudio` / `-RuleStudio` (and the bash long flags) turn one package on.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -Extensions -Tools
```

**bash:**

```bash
./tazama.sh apply core onprem --extensions --tools
```

These studios talk to in-cluster Postgres and NATS. They do not require Flowable, CouchDB, or OpenSearch. When ingress is enabled, hosts are `tcs` / `tcs-api` and `trs` / `trs-api`.

### 4. Core plus BIAR (in-cluster replica)

When to use it: NiFi (BIAR) on the same cluster, reading from a streaming replica of in-cluster Postgres.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -Biar -PostgresReplica
```

**bash:**

```bash
./tazama.sh apply core onprem --biar --postgres-replica
```

Helmfile fails if BIAR is on, the in-cluster replica is off, and `hosts.postgresqlReplica` is still `postgresql-replica`.

### 5. Core plus BIAR (managed replica)

When to use it: NiFi should use an external Postgres replica (RDS, Cloud SQL, Azure Database) while the Tazama apps still use in-cluster Postgres. `-PostgresqlReplicaHost` sets the host and turns the in-cluster replica off.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -Biar -PostgresqlReplicaHost "mydb-ro.xxxx.rds.amazonaws.com"
```

**bash:**

```bash
./tazama.sh apply core onprem --biar --postgresql-replica-host mydb-ro.xxxx.rds.amazonaws.com
```

Keep `install.postgresql` on unless you are also moving the primary out of the cluster (see example 10). Do not pass `-PostgresReplica` when the replica is managed. Helmfile fails: the in-cluster replica requires `install.postgresql`.

### 6. Relay EA to Kafka

When to use it: EF and TP still produce to in-cluster NATS, and EA produces to Kafka you already run. Helm does not install Kafka.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -RelayEa kafka -KafkaBrokers "kafka.example.com:9092"
```

**bash:**

```bash
./tazama.sh apply core onprem --relay-ea kafka --kafka-brokers kafka.example.com:9092
```

Helmfile fails if any transport is `kafka` and `relay.kafka.brokers` is empty.

RabbitMQ example (EA to a broker you already run):

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -RelayEa rabbitmq -RabbitmqUrl "amqp://user:pass@rabbit.example.com:5672"
```

**bash:**

```bash
./tazama.sh apply core onprem --relay-ea rabbitmq --rabbitmq-url amqp://user:pass@rabbit.example.com:5672
```

Helmfile fails if any transport is `rabbitmq` and `relay.rabbitmq.url` is empty.

REST example (EA to an HTTP endpoint you already run):

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -RelayEa rest -RestUrl "https://relay.example.com/intake"
```

**bash:**

```bash
./tazama.sh apply core onprem --relay-ea rest --rest-url https://relay.example.com/intake
```

Helmfile fails if any transport is `rest` and `relay.rest.url` is empty. Relays still consume from in-cluster NATS. The transport setting only changes where they produce.

### 7. Dockerhub (fuller public rules)

When to use it: public Docker Hub images, the longer rule list, Connection Studio, Rule Studio, CMS (with Flowable, CouchDB, and OpenSearch), DEAPI, and DEMS. Flags live in `environments/dockerhub.yaml`. BIAR stays off.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile dockerhub -Cloud onprem
```

**bash:**

```bash
./tazama.sh apply dockerhub onprem
```

### 8. Member (private rule registry)

When to use it: the same stack as dockerhub, but rule images come from a private registry (example `ghcr.io/frmscoe`).

The `member` profile loads `environments/dockerhub.yaml`, then `environments/member.yaml`. Uncomment and set the registry (advanced YAML edit):

```yaml
# environments/member.yaml
rules:
  imageRegistry: ghcr.io/frmscoe
```

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile member -Cloud onprem
```

**bash:**

```bash
./tazama.sh apply member onprem
```

Leave `imageRegistry` commented if you only want dockerhub under the member environment name. Public `tazamaorg/rule-NNN` images stay on Docker Hub until you set that key. [frmscoe](https://github.com/frmscoe) repos are often processing-engines and typologies, not `rule-NNN`. Map those images explicitly when you have the real names.

### 9. Cloud (EKS)

When to use it: the same profile on Amazon EKS. The wrapper sets `TAZAMA_CLOUD` and Helmfile loads `environments/cloud/eks.yaml` (ingress-nginx on, `gp3` StorageClass). GKE and AKS are the same pattern with `-Cloud gke` or `-Cloud aks`. Package switches work the same as on-prem.

Set `ingress.domain` in that cloud overlay to a DNS name you control before you apply. Replace passwords in `values/secrets.yaml`. Confirm the StorageClass exists.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud eks
.\tazama.ps1 apply -Profile dockerhub -Cloud gke
.\tazama.ps1 apply -Profile core -Cloud eks -Cms
```

**bash:**

```bash
./tazama.sh apply core eks
./tazama.sh apply dockerhub gke
./tazama.sh apply core eks --cms
```

### 10. Managed Postgres

When to use it: apps should use an external database instead of in-cluster Postgres. `-PostgresqlHost` sets the host and turns in-cluster Postgres off.

**PowerShell:**

```powershell
.\tazama.ps1 apply -Profile core -Cloud onprem -PostgresqlHost "mydb.xxxx.rds.amazonaws.com"
```

**bash:**

```bash
./tazama.sh apply core onprem --postgresql-host mydb.xxxx.rds.amazonaws.com
```

Keep `values/secrets.yaml` in sync with that database user. Create the Tazama database names (`configuration`, `raw_history`, `event_history`, `evaluation`) on the server. Create a `keycloak` database if you keep Keycloak on.

If BIAR is also on, pass `-PostgresqlReplicaHost` / `--postgresql-replica-host` as in example 5. Do not pass `-PostgresReplica` here: the in-cluster replica requires `install.postgresql`.

### Advanced: persist flags in YAML

If you want the same package set without repeating wrapper flags, edit `environments/core.yaml` (Helmfile merges it over `values/defaults.yaml`) and run apply with no extra switches:

```yaml
# environments/core.yaml
install:
  cms: true
  flowable: true
  couchdb: true
  opensearch: true
```

Relay transports can be persisted the same way:

```yaml
relay:
  efrup:
    transport: nats        # nats | kafka | rabbitmq | rest
  tp:
    transport: nats
  ea:
    transport: nats
  kafka:
    brokers: ""            # required when any transport is kafka
  rabbitmq:
    url: ""                # required when any transport is rabbitmq
  rest:
    url: ""                # required when any transport is rest
    authUsername: ""
    authPassword: ""
```

## Secrets and passwords

Never commit `values/secrets.yaml`. It is created from `values/secrets.example.yaml` and should stay gitignored.

Edit `values/secrets.yaml` to change:

- Postgres user, password, and replication password
- Keycloak admin user, password, and client secret
- Auth public/private key pair
- Optional Docker Hub pull secret (`secrets.dockerHub.createPullSecret: true` plus username and password)

`values/secrets.example.yaml` does not ship an Auth private key. After you copy it to `values/secrets.yaml`, generate or paste your own key locally; never commit it. Then set `auth.authenticated: true` in `values/defaults.yaml` (or a profile overlay) when TMS and Admin should require JWTs.

Helm stores values on the release Secret in the cluster. Treat the cluster as trusted, or plan an external secrets controller later. Do not ship real TLS keys in git.

After you change passwords, run apply again. If Postgres already initialized on an existing PVC, changing the Secret does not rewrite the database role. You must update the role inside Postgres or wipe the PVC (you will lose data).

## Add or remove later

Each service is its own Helm release. To add something, pass the wrapper flag (for example `-Cms` / `--cms`) and run apply again.

Turning a flag off and running apply does not always delete a release that is no longer listed (rules are generated from `rules.enabled`). To take something out of the cluster:

```powershell
# 1) destroy those releases (CMS was added with -Cms)
.\tazama.ps1 destroy -Profile core -Cloud onprem -Selector "name=cms-backend"
.\tazama.ps1 destroy -Profile core -Cloud onprem -Selector "name=cms-frontend"

# Remove one rule: delete "901" from rules.enabled, then
.\tazama.ps1 destroy -Profile core -Cloud onprem -Selector "name=rule-901"

.\tazama.ps1 apply -Profile core -Cloud onprem
```

```bash
./tazama.sh destroy core onprem name=cms-backend
./tazama.sh apply core onprem
```

To pause a running app without destroying the release, scale the Deployment to zero:

```powershell
kubectl scale deployment/tms-service -n tazama --replicas=0
```

Scale back to `1` (or run apply) when you want it again.

To skip in-cluster Postgres and use a managed database, see [Managed Postgres](#10-managed-postgres) in the examples. If BIAR is on, also pass `-PostgresqlReplicaHost` as in [Core plus BIAR (managed replica)](#5-core-plus-biar-managed-replica).

Add extra public rules by appending ids to `rules.enabled` and running apply. If the image is not `docker.io/tazamaorg/rule-NNN`, set `rules.imageRegistry`. `environments/member.yaml` has a commented example for `ghcr.io/frmscoe`. [frmscoe](https://github.com/frmscoe) repos are often processing-engines and typologies, not `rule-NNN`. Map those images explicitly when you have the real names. Keep private lists out of the public `core` profile.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Pods `Pending`, PVC `Pending` | No StorageClass, or the class in the cloud overlay does not exist. Run `kubectl get storageclass` and set `storageClass` in `environments/cloud/<name>.yaml`. |
| First boot takes a long time / processors in Init | Postgres is still running `00-CREATE.sql` and `10-core-config.sql`. Those scripts run only on an empty data directory. Core and rule pods wait until table `pain013` exists in `raw_history`, and until Valkey `:6379` and NATS `:4222` accept TCP. |
| Postgres CrashLoop / init errors | `kubectl logs -n tazama statefulset/postgresql`. If you changed SQL after the first boot, delete the Postgres PVC (you will lose data) or apply SQL yourself with `psql`. |
| Keycloak CrashLoop on a reused PVC | SQL init does not re-run. As postgres, run `CREATE DATABASE keycloak;` if that database is missing. Confirm ConfigMap `keycloak-realm` is mounted. |
| `apply` did not show a diff | helm-diff is not installed. The wrapper used `helmfile sync`. Install helm-diff, or run `sync` on purpose. |
| ImagePullBackOff | Docker Hub rate limit or a private image. Set `secrets.dockerHub.createPullSecret: true` and credentials in `values/secrets.yaml`. |
| Relay template error about brokers/url | Pass `-KafkaBrokers` / `--kafka-brokers`, `-RabbitmqUrl` / `--rabbitmq-url`, or `-RestUrl` / `--rest-url` for that transport. Helm does not install those brokers. |
| TMS up but no rule hits | Core config is 901/902 on `pacs.002.001.12`. Send a pacs.002, not only pacs.008. |
| `helmfile` errors on nested values | Confirm `values/secrets.yaml` exists and the YAML is valid. |

```powershell
kubectl get pods,svc,ingress,pvc -n tazama
kubectl describe pod -n tazama <pod-name>
kubectl logs -n tazama statefulset/postgresql
```

PVCs are often kept after `destroy`. Delete them only when you intend to wipe the database:

```powershell
kubectl get pvc -n tazama
kubectl delete pvc -n tazama --all
```

## Command reference

Wrapper arguments: PowerShell uses `-Profile`, `-Cloud`, `-Selector`, and the flags in [Wrapper flags](#wrapper-flags). bash uses positional `command`, `profile`, `cloud`, optional selector, then `--cms` style flags. Omitted flags leave the profile YAML unchanged.

| Action | PowerShell | bash |
| --- | --- | --- |
| Install or upgrade | `.\tazama.ps1 apply -Profile core -Cloud onprem` | `./tazama.sh apply core onprem` |
| Core plus CMS | `.\tazama.ps1 apply -Profile core -Cloud onprem -Cms` | `./tazama.sh apply core onprem --cms` |
| Core plus extensions and tools | `.\tazama.ps1 apply -Profile core -Cloud onprem -Extensions -Tools` | `./tazama.sh apply core onprem --extensions --tools` |
| Core plus BIAR (in-cluster replica) | `.\tazama.ps1 apply -Profile core -Cloud onprem -Biar -PostgresReplica` | `./tazama.sh apply core onprem --biar --postgres-replica` |
| Relay EA to Kafka | `.\tazama.ps1 apply -Profile core -Cloud onprem -RelayEa kafka -KafkaBrokers "kafka.example.com:9092"` | `./tazama.sh apply core onprem --relay-ea kafka --kafka-brokers kafka.example.com:9092` |
| Dockerhub profile | `.\tazama.ps1 apply -Profile dockerhub -Cloud onprem` | `./tazama.sh apply dockerhub onprem` |
| Cloud EKS | `.\tazama.ps1 apply -Profile core -Cloud eks` | `./tazama.sh apply core eks` |
| Managed Postgres host | `.\tazama.ps1 apply -Profile core -Cloud onprem -PostgresqlHost "mydb.xxxx.rds.amazonaws.com"` | `./tazama.sh apply core onprem --postgresql-host mydb.xxxx.rds.amazonaws.com` |
| Sync (always `helmfile sync`, no helm-diff) | `.\tazama.ps1 sync -Profile core -Cloud onprem` | `./tazama.sh sync core onprem` |
| Preview the diff | `.\tazama.ps1 diff -Profile core -Cloud onprem` | `./tazama.sh diff core onprem` |
| Render YAML | `.\tazama.ps1 template -Profile core -Cloud onprem -Cms` | `./tazama.sh template core onprem --cms` |
| Status | `.\tazama.ps1 status -Profile core -Cloud onprem` | `./tazama.sh status core onprem` |
| Lint | `.\tazama.ps1 lint -Profile core -Cloud onprem` | `./tazama.sh lint core onprem` |
| Uninstall everything this Helmfile owns | `.\tazama.ps1 destroy -Profile core -Cloud onprem` | `./tazama.sh destroy core onprem` |
| One release only | `.\tazama.ps1 destroy -Profile core -Cloud onprem -Selector "name=tms-service"` | `./tazama.sh destroy core onprem name=tms-service` |

Allowed profiles: `core`, `dockerhub`, `member`. Allowed clouds: `onprem`, `eks`, `gke`, `aks`. Defaults if you omit them: `apply`, `core`, `onprem`. Relay transports: `nats`, `kafka`, `rabbitmq`, `rest`.

`apply` is `helmfile apply` when helm-diff is installed, otherwise `helmfile sync`. `sync` always runs `helmfile sync`.

## For operators

The wrapper runs `helmfile -e <profile> -f helmfile.yaml.gotmpl` with `TAZAMA_CLOUD` set. Package and host flags become `--state-values-set` / `--state-values-set-string` (Helmfile 1.x state overrides, not Helm chart `--set`). You can call helmfile yourself from this folder. If `KUBECONFIG` is set, the wrapper passes `--kubeconfig`.

Values merge in this order (later files win):

1. `values/defaults.yaml` (namespace, image tag, hosts, every `install.*` flag, relay transports)
2. Profile: `environments/core.yaml`, or `environments/dockerhub.yaml`, or dockerhub plus `environments/member.yaml`
3. Cloud: `environments/cloud/{{ TAZAMA_CLOUD }}.yaml` (default `onprem`)
4. `values/secrets.yaml`
5. Wrapper `--state-values-set` / `--state-values-set-string` (only keys you passed)

Useful keys in `values/defaults.yaml`:

```yaml
namespace: tazama
global:
  tazamaVersion: "rc"          # image tag for tazamaorg/*
  imageRegistry: docker.io/tazamaorg
  ruleRel: "4-0-0"             # FUNCTION_NAME suffix, rule-901-rel-4-0-0

hosts:
  postgresql: postgresql
  postgresqlReplica: postgresql-replica
  nats: nats
  valkey: valkey
  keycloak: keycloak

install:
  postgresql: true
  postgresqlReplica: false
  nats: true
  valkey: true
  admin: true
  tms: true
  eventDirector: true
  eventFlow: true
  typologyProcessor: true
  eventAdjudicator: true
  relay: true
  auth: true
  keycloak: true
  biar: false

auth:
  authenticated: false
```

Helmfile then applies nested files in order: datastore, auxiliary, core, rules, extensions, biar.

Selector labels you can pass to `-Selector` / `--selector` or a positional label (Helmfile `-l`):

- `tier=datastore` \| `auxiliary` \| `core` \| `rules` \| `extensions` \| `biar`
- `name=<release>` such as `tms-service`, `postgresql`, `rule-902`, `relay-service-ea`, `keycloak`

Equivalent Helmfile without the wrapper:

```bash
helmfile -e core -f helmfile.yaml.gotmpl -l name=cms-backend destroy
helmfile -e core -f helmfile.yaml.gotmpl -l tier=rules apply
helmfile -e core -f helmfile.yaml.gotmpl apply
```

App images come from Docker Hub (`tazamaorg/*`). Infra charts come from upstream Helm repos (groundhog2k Postgres, official NATS, Valkey, ingress-nginx, OpenSearch). You do not need a Helm chart inside every Tazama service repo for this stack to install.

```
tazama-Helms/
  helmfile.yaml.gotmpl          # entrypoint
  tazama.ps1 / tazama.sh        # wrapper (profile, cloud, package flags)
  values/defaults.yaml          # shared knobs
  values/secrets.example.yaml
  environments/                 # core, dockerhub, member
  environments/cloud/           # onprem, eks, gke, aks
  charts/tazama-workload/       # generic app chart
  charts/tazama-files/          # SQL, Keycloak realm, credentials
  datastore/ auxiliary/ core/ rules/ extensions/ biar/
```

## License

Apache-2.0. SQL and env defaults are derived from [tazama-stack](https://github.com/tazama-lf/tazama-stack) (Apache-2.0).
