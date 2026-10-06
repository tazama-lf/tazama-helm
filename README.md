# Tazama on Kubernetes

Install the Tazama transaction-monitoring stack on Kubernetes. This repo is **Helmfile**: many independent Helm releases (Postgres, NATS, TMS, rules, and so on), not a single umbrella chart. You can add CMS later, or destroy only `name=cms-backend`, without uninstalling TMS.

You talk to the cluster with `kubectl`. **Helm** installs each chart. **Helmfile** reads `helmfile.yaml.gotmpl` and installs them together. The wrappers (`tazama.cmd` on Windows, `tazama.sh` on Linux and macOS) cover a local Kind cluster, an existing on-prem cluster, and EKS / GKE / AKS.

Clone this repo, install the tools in [End-to-end setup](#end-to-end-setup), then run the wrapper for your OS. First install: use `sync`. After that, pass wrapper flags and run `apply` again to add packages.

**Before any shared or production cluster:**

- Never commit `values/secrets.yaml`. The wrapper generates random passwords and an Auth RSA key pair into that gitignored file.
- Pin `global.tazamaVersion` to a tested image tag instead of `rc`.
- Prefer a [managed Postgres](#10-managed-postgres) primary (`-PostgresqlHost`). If BIAR is on, use a managed replica (`-PostgresqlReplicaHost`). In-cluster Postgres is a single-primary StatefulSet with a PVC.

This is the Helm/Helmfile form of [tazama-stack](https://github.com/tazama-lf/tazama-stack). It is not the public Docker Compose test stack (that stack leaves Auth off).

## Contents

- [End-to-end setup](#end-to-end-setup)
- [What core installs](#what-core-installs)
- [Wrapper flags](#wrapper-flags)
- [Optional packages](#optional-packages)
- [Loading configuration](#loading-configuration)
- [Relays](#relays)
- [BIAR and the Postgres replica](#biar-and-the-postgres-replica)
- [Profiles and clouds](#profiles-and-clouds)
- [Example installations](#example-installations)
- [Secrets and passwords](#secrets-and-passwords)
- [Add or remove later](#add-or-remove-later)
- [Troubleshooting](#troubleshooting)
- [Command reference](#command-reference)
- [For operators](#for-operators)

## End-to-end setup

Follow this path once per machine and cluster. Pick the OS block and the cluster block that match how you work. Do not mix them: a Kind cluster uses `-Cloud onprem`; Amazon EKS uses `-Cloud eks` against that cluster’s kubeconfig, not a local Kind cluster.

A **profile** (`core`, `full`, or `private-rules`) is a named set of on/off flags. **Values** are the YAML Helmfile merges (image tag, passwords, which packages are on). This stack uses the `tazama` namespace by default; Helmfile creates it. You do not need `kubectl create ns tazama` first.

You run `tazama.cmd` (Windows) or `tazama.sh` (Linux / macOS). The wrapper sets the cloud name, then runs Helmfile. Omitted flags leave the profile YAML unchanged. You do not need to edit YAML for a first install. Editing YAML is an [advanced](#advanced-persist-flags-in-yaml) way to persist the same settings in git.

**Windows:** use `tazama.cmd` (cmd or PowerShell). That launcher runs `tazama.ps1` with `-ExecutionPolicy Bypass`, so you do not hit “running scripts is disabled”. **Linux and macOS:** `./tazama.sh`. That command fails in Windows PowerShell with “bash not found”. The scripts look up `helmfile` and `helm` by name; they stop if either is missing.

### 1. Install tools

You need all of the following on the machine that will run the wrapper:

| Tool | Why | Check |
| --- | --- | --- |
| Docker (Kind / Docker Desktop Kubernetes only) | Runs the local cluster | `docker version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Talks to the cluster | `kubectl version --client` |
| [Helm 3](https://helm.sh/docs/intro/install/) | Installs each chart | `helm version` |
| [Helmfile 1.x](https://github.com/helmfile/helmfile/releases) | Installs this repo’s many charts together. Entry file is `helmfile.yaml.gotmpl` | `helmfile version` (must report 1.x, not 0.x) |
| [openssl](https://www.openssl.org/) | Wrapper generates Auth RSA keys and random passwords | `openssl version` |
| git | Clone this repo and [tms-configuration](https://github.com/frmscoe/tms-configuration) | `git --version` |

Also required on the **cluster** (not necessarily on your laptop):

- Disk that can bind a **PVC** (PersistentVolumeClaim: a request for disk that survives pod restarts). Examples: Kind’s default local-path, Longhorn, EBS CSI (`gp3`), GCE PD (`standard-rwo` / `premium-rwo`), Azure Disk (`managed-csi`).
- Network access to pull `docker.io/tazamaorg/*`. If those images are private, set a pull secret (see [Secrets and passwords](#secrets-and-passwords)).

Optional:

- [helm-diff](https://github.com/databus23/helm-diff) (`helm plugin install https://github.com/databus23/helm-diff`). If it is missing, `apply` still works. The wrapper prints a warning on stderr and switches to `helmfile sync`. helm-diff can also skip nested helmfiles; for a first install prefer `sync`.
- [GitHub CLI](https://cli.github.com/) (`gh`) if you prefer `gh repo clone` over `git clone`.
- Public hostnames: pass `-Ingress` / `--ingress` (also installs ingress-nginx). Cloud overlays for EKS, GKE, and AKS turn that on for you. You also need DNS (or a hosts-file entry) for `*.your-domain`. Default `core` / `onprem` stays on port-forward until you pass the flag.

Install only what is missing. After each block, run the **Check** commands in the table.

#### Windows (PowerShell)

Docker Desktop (needed for Kind or Docker Desktop Kubernetes): [Install Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/). Start Docker and wait until it is running.

kubectl, Helm, and Kind via winget (or use [Chocolatey](https://chocolatey.org/) `choco install kubernetes-cli kubernetes-helm kind` if you already use it):

```powershell
winget install --id Kubernetes.kubectl -e
winget install --id Helm.Helm -e
winget install --id Kubernetes.kind -e
```

If `winget` has no Kind package, download `kind-windows-amd64` from the [Kind releases](https://github.com/kubernetes-sigs/kind/releases), rename it to `kind.exe`, and put it on your `PATH`.

Helmfile 1.x: download the latest `helmfile_*_windows_amd64.zip` from [Helmfile releases](https://github.com/helmfile/helmfile/releases), extract `helmfile.exe`, and put it on your `PATH` (for example `%USERPROFILE%\bin`). Confirm with `helmfile version`.

openssl: install [Git for Windows](https://git-scm.com/download/win). The wrapper finds `C:\Program Files\Git\usr\bin\openssl.exe` if `openssl` is not on `PATH`.

Open a **new** PowerShell window so `PATH` updates apply.

#### macOS (Homebrew)

```bash
brew install kubectl helm helmfile kind git
# openssl is already present on macOS; Homebrew openssl is optional
```

Docker: [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/) or Colima (`brew install colima docker` then `colima start`). Kind needs a running container runtime.

#### Linux

Docker Engine: follow [Install Docker Engine](https://docs.docker.com/engine/install/). Kind and kubectl talk to that daemon.

kubectl (official binary, amd64; use `arm64` in the URL on ARM):

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client
```

Helm:

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Helmfile 1.x (latest GitHub release, amd64):

```bash
TAG="$(curl -s https://api.github.com/repos/helmfile/helmfile/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')"
curl -L -o helmfile.tar.gz "https://github.com/helmfile/helmfile/releases/download/${TAG}/helmfile_${TAG#v}_linux_amd64.tar.gz"
tar -xzf helmfile.tar.gz helmfile
sudo mv helmfile /usr/local/bin/helmfile
sudo chmod +x /usr/local/bin/helmfile
rm helmfile.tar.gz
helmfile version
```

On ARM machines, use the `linux_arm64` asset from the same release instead of `linux_amd64`.

Kind (amd64; use `kind-linux-arm64` on ARM):

```bash
curl -Lo ./kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64"
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

openssl and git: `sudo apt-get install -y openssl git` on Debian/Ubuntu, or `sudo dnf install openssl git` on Fedora / RHEL. Fedora / RHEL can also install `kubectl` and `helm` from distro repos if you prefer packages over the binaries above.

### 2. Create or connect a cluster

`kubectl` must already point at the cluster you intend to install into. Check with `kubectl get nodes`. The wrapper uses the current context (or `KUBECONFIG` if you set it).

Pick **one** of the following.

#### Local Kind (laptop sandbox)

Kind is Kubernetes in Docker. Use it to learn the stack. Do not use Kind as a production control plane.

```bash
kind create cluster --name tazama-cluster
kubectl cluster-info --context kind-tazama-cluster
```

**Windows:** the same `kind` / `kubectl` commands work in PowerShell once Docker Desktop is running.

Kind already ships a default StorageClass. The `onprem` overlay leaves `storageClass` empty so that default is used.

If you later enable ingress on Kind, keep the controller as **NodePort** (the `onprem` default). Kind has no cloud load balancer; a `LoadBalancer` Service stays `<pending>` and Helm `--wait` hangs. See [On-prem with ingress](#11-on-prem-with-ingress).

To delete the sandbox later: `kind delete cluster --name tazama-cluster`.

#### Docker Desktop Kubernetes, k3d, kubeadm, RKE2, OpenShift-compatible

Enable Kubernetes in Docker Desktop, or use any cluster whose StorageClass can bind PVCs. Point `kubectl` at it, then use `-Cloud onprem`. You do not run `kind create cluster`.

#### Amazon EKS, Google GKE, Azure AKS (shared or production)

Create the managed cluster with your usual cloud process (eksctl, gcloud, az, Terraform). Install the disk CSI driver if the cluster does not already have it (EKS: EBS CSI and a `gp3` StorageClass; GKE: `standard-rwo` or `premium-rwo`; AKS: `managed-csi`). Authenticate so `kubectl get nodes` lists those nodes.

Then install this stack with `-Cloud eks`, `-Cloud gke`, or `-Cloud aks`. Those overlays turn ingress-nginx on and set a cloud StorageClass. Set `-IngressDomain` (or `ingress.domain` in the overlay) to a DNS name you control **before** the first apply. Prefer a [managed Postgres](#10-managed-postgres) host for anything shared. Pin `global.tazamaVersion` to a tested tag instead of `rc`. Kind is not involved.

### 3. Clone the repo and prepare secrets

Clone this repository, then:

```bash
cd tazama-Helms
```

**Windows:** `cd` into the same folder (the one that contains `tazama.ps1`, `tazama.cmd`, and `tazama.sh`).

Copy the example secrets file once:

```powershell
copy values\secrets.example.yaml values\secrets.yaml
```

```bash
cp values/secrets.example.yaml values/secrets.yaml
```

The first wrapper run also copies that file if it is missing, then generates **random** Postgres / Keycloak / Valkey passwords and a matching Auth RSA key pair into gitignored `values/secrets.yaml`. Dummy placeholders (`unused`, `password`, `tazama`) are replaced automatically.

Do **not** create a separate `kubectl` Secret for RSA keys. Older notes that run `openssl genrsa` and `kubectl create secret generic tazama-auth-keys` are for a different chart. This stack mounts keys from `values/secrets.yaml` through the `tazama-credentials` Secret that Helmfile already creates. Pasting `kubectl get secret` base64 into `values/secrets.yaml` double-encodes the values and breaks Auth.

Never commit `values/secrets.yaml`. Each environment (laptop, staging, production) should get its own generated file. See [Secrets and passwords](#secrets-and-passwords).

### 4. Deploy the stack

Work from the repo root. `sync` is the safest first install (always `helmfile sync`, no helm-diff). `apply` is `helmfile apply` when helm-diff is installed, otherwise it falls back to `sync`.

**PowerShell or cmd (Windows):**

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem
kubectl get pods -n tazama -w
```

If you call `tazama.ps1` yourself and Windows blocks it:

```powershell
powershell -ExecutionPolicy Bypass -File .\tazama.ps1 sync -Profile core -Cloud onprem
```

**bash (Linux / macOS):**

```bash
chmod +x tazama.sh
./tazama.sh sync core onprem
kubectl get pods -n tazama -w
```

Cloud examples (kubeconfig must already target that cluster):

```powershell
.\tazama.cmd sync -Profile core -Cloud eks -IngressDomain tm.example.com
.\tazama.cmd sync -Profile core -Cloud gke -IngressDomain tm.example.com
.\tazama.cmd sync -Profile core -Cloud aks -IngressDomain tm.example.com
```

```bash
./tazama.sh sync core eks --ingress-domain tm.example.com
./tazama.sh sync core gke --ingress-domain tm.example.com
./tazama.sh sync core aks --ingress-domain tm.example.com
```

Wait until Postgres and the processors are Ready. The first boot can take several minutes while Postgres runs `00-CREATE.sql` and `10-core-config.sql`, and while Keycloak imports the tazama realm. Press Ctrl+C to stop `kubectl get pods -w` when you are done watching.

Package flags (`-Cms`, `--biar`, relays, managed Postgres hosts) are in [Wrapper flags](#wrapper-flags) and [Example installations](#example-installations).

### 5. Reach the APIs

On `core` / `onprem` without `-Ingress`, use **port-forward** (a `kubectl` tunnel from a cluster Service to your laptop). This stack’s TMS Service port is **3000**, not Docker Compose’s 5000.

**PowerShell or bash:**

```powershell
kubectl port-forward -n tazama svc/tms-service 3000:3000
kubectl port-forward -n tazama svc/admin-service 5100:5100
kubectl port-forward -n tazama svc/auth-service 3020:3020
kubectl port-forward -n tazama svc/keycloak 8080:8080
```

In another terminal:

```powershell
curl.exe http://localhost:3000
```

```bash
curl http://localhost:3000
```

On Windows, prefer `curl.exe` so PowerShell’s `curl` alias does not rewrite the request.

Expect `{"status":"UP"}` from TMS once schema init and processor waits have finished. Admin is `http://localhost:5100`. Load rules and the network map through **admin-service** (see [Loading configuration](#loading-configuration)).

With ingress enabled (cloud overlays, or `-Ingress` / `--ingress`), use `http://tms.<ingress.domain>` and `http://admin.<ingress.domain>` instead of port-forward. Map those names in DNS, or in `/etc/hosts` (Linux / macOS) or `C:\Windows\System32\drivers\etc\hosts` (Windows).

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
| Rules | Public rule images listed in `rules.enabled` (30+ ids plus 901/902) |
| Postgres | In-cluster database (groundhog2k chart) plus SQL schema and sample typology |
| NATS | Message bus with JetStream |
| Valkey | In-memory cache (Redis-compatible) |

Auth and Keycloak are installed even when `auth.authenticated` is `false` (the default). TMS and Admin do not require JWTs until you set that flag to `true`.

The in-cluster Postgres replica is **off** in core. Ingress-nginx is **off** for `onprem` unless you pass `-Ingress` / `--ingress`.

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
| Rotate dummy (or all) passwords and Auth keys in `values/secrets.yaml` | `-GenerateSecrets` | `--generate-secrets` | writes random secrets into the gitignored file |

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

### Sizing (replica counts)

Default is **one pod per service**. Pass `-Sizing` / `--sizing` to scale the pipeline for throughput.

| What | PowerShell | bash | Helmfile keys |
| --- | --- | --- | --- |
| Replica tier | `-Sizing <tier>` | `--sizing <tier>` | `replicas.*`, `postgres.maxConnections` |

Tiers are `standard` (default), `small`, `medium`, and `large`, each a file in `values/sizing/`. Helmfile loads `values/sizing/<tier>.yaml` after the cloud overlay, so a tier wins over profile and cloud defaults but still loses to `values/secrets.yaml`.

| Service | standard | small | medium | large |
| --- | --- | --- | --- | --- |
| `tms-service` | 1 | 2 | 3 | 4 |
| `admin-service` | 1 | 1 | 2 | 2 |
| `event-director` | 1 | 2 | 4 | 8 |
| `event-flow` | 1 | 2 | 3 | 4 |
| `typology-processor` | 1 | 6 | 12 | 24 |
| `event-adjudicator` | 1 | 3 | 6 | 12 |
| `auth-service` | 1 | 1 | 2 | 2 |
| `keycloak` | 1 | 1 | 1 | 2 |
| Each relay | 1 | 1 | 2 | 2 |
| Each rule | 1 | 1 | 1 | 2 |
| Postgres `max_connections` | 200 | 400 | 800 | 1600 |

`replicas.rules` applies to **every** id in `rules.enabled`. Core enables 33 rules, so `large` adds 33 pods on that line alone. Check the list before you raise it.

Tiers follow the **ratio** in [Infrastructure-Spec-For-Tazama](https://github.com/tazama-lf/docs/blob/dev/Technical/Environment-Setup/Infrastructure/Infrastructure-Spec-For-Tazama.md) (Typology Processor is the hot path, Event Adjudicator next) at a much lower absolute pod count. Treat that spec as the reference target and these tiers as a safe starting point, then raise them against your own load. Spec names map as: **CRSP** is `event-director`, **TADP** is `event-adjudicator` (with `event-flow`), **REDIS** is Valkey, **Arango** is Postgres. ELK is not installed; OpenSearch is the optional equivalent.

Infrastructure replicas are **not** part of a tier. Set NATS and Valkey through their own keys (`valkey.replicaEnabled`, `valkey.replicas`) because those are upstream charts with their own clustering model.

```powershell
.\tazama.cmd apply -Profile core -Cloud eks -Sizing medium
```

```bash
./tazama.sh apply core eks --sizing medium
```

Check capacity first. A tier above `standard` will not fit on Kind or Docker Desktop, and `helmfile` waits on pods that can never be scheduled:

```powershell
kubectl get nodes
kubectl top nodes
kubectl get pods -n tazama --field-selector status.phase=Pending
```

### Connection pooling and `max_connections`

Each app pod keeps a **pool** of open Postgres connections and reuses them instead of connecting per query. That is good for latency, but pool size multiplies by pod count: 12 Typology Processor pods holding 10 connections each want 120 connections on their own.

Postgres forks a backend process per connection, so it caps the total. This stack sets `max_connections` from `postgres.maxConnections` (200 by default, raised per sizing tier). Budget roughly 5-10 MB of Postgres memory per connection, and remember the in-cluster primary is a single StatefulSet pod.

Past roughly 500 connections, raising the cap stops helping. Put a pooler (PgBouncer in transaction mode) in front of the primary, or move to a [managed Postgres](#10-managed-postgres) that has one. This stack does not install a pooler.

If you see `FATAL: sorry, too many clients already`, you have more pods times pool size than `max_connections`. Raise the tier, lower replica counts, or add a pooler.

### Ingress

Default `core` / `onprem` does **not** enable ingress. Use port-forward, or pass `-Ingress` / `--ingress`. Cloud overlays (`eks`, `gke`, `aks`) already set `ingress.enabled` and `install.ingressNginx`.

| What | PowerShell / `tazama.cmd` | bash | Helmfile keys |
| --- | --- | --- | --- |
| Enable ingress and install ingress-nginx | `-Ingress` | `--ingress` | `ingress.enabled=true`, `install.ingressNginx=true` |
| Hostname suffix (`tms.<domain>`, `admin.<domain>`, ...) | `-IngressDomain <domain>` | `--ingress-domain <domain>` | `ingress.domain` |
| IngressClass name (default `nginx`) | `-IngressClass <name>` | `--ingress-class <name>` | `ingress.className` |
| Controller Service type (on-prem default `NodePort`; cloud uses `LoadBalancer`) | `-IngressServiceType <type>` | `--ingress-service-type <type>` | `ingressNginx.serviceType`, `ingress.nginx.serviceType` |

Example (on-prem, local domain):

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem -Ingress -IngressDomain tazama.local
```

```bash
./tazama.sh apply core onprem --ingress --ingress-domain tazama.local
```

Then map hosts to the ingress-nginx address. On Linux or macOS that is `/etc/hosts`. On Windows it is `C:\Windows\System32\drivers\etc\hosts`. Add lines such as `127.0.0.1 tms.tazama.local admin.tazama.local auth.tazama.local keycloak.tazama.local` (use the LoadBalancer or NodePort IP if it is not localhost). Confirm objects with:

```powershell
kubectl get ingress -n tazama
kubectl get svc -n ingress-nginx
```

Host prefixes live in `values/ingress.yaml` under `ingress.hosts` (TMS, Admin, Auth, Keycloak, TCS, TRS, CMS, NiFi). Change a prefix there if you do not want `tms.<domain>`.

## Optional packages

These stay off in `core`. Turn them on with a wrapper flag from the table above, then run apply again. The `full` profile already enables most of this list.

| Package | Flag | What you get |
| --- | --- | --- |
| DEMS | `-Dems` / `--dems` (or `-Extensions`) | Event monitoring service |
| DEAPI | `-Deapi` / `--deapi` (or `-Extensions`) | Data enrichment service |
| TCS | `-ConnectionStudio` / `--connection-studio` (or `-Tools`) | Connection Studio (frontend + backend). Ingress hosts `tcs` and `tcs-api` |
| TRS | `-RuleStudio` / `--rule-studio` (or `-Tools`) | Rule Studio (frontend + backend). Ingress hosts `trs` and `trs-api` |
| CMS | `-Cms` / `--cms` | Case Management System (frontend + backend), plus Flowable, CouchDB, and OpenSearch |
| BIAR | `-Biar` / `--biar` | NiFi reference workload. Needs a Postgres replica (see below) |

The `full` profile also turns on OpenSearch, CouchDB, and Flowable. Those support CMS and the studios. The public rule list already lives in `core`. BIAR stays off until you enable it yourself.

## Loading configuration

Core already ships a sample network map (rules 901/902 on `pacs.002.001.12`, tenant `DEFAULT`) via Postgres init SQL. That is enough to prove TMS is up. A full typology set (pacs.008 plus pacs.002, public rules) is loaded through **admin-service**. This stack does not include Hasura.

Follow the Admin-Service API steps in [tms-configuration](https://github.com/frmscoe/tms-configuration) (`curl/` payloads). Clone that repo next to this one (or anywhere you can run `curl` from).

### Reach admin-service

Port-forward if you are on `onprem` without ingress:

```powershell
kubectl port-forward -n tazama svc/admin-service 5100:5100
```

```bash
export ADMIN_URL=http://localhost:5100
```

```powershell
$env:ADMIN_URL = "http://localhost:5100"
```

With ingress, set `ADMIN_URL` to `http://admin.<ingress.domain>` (or `https://` if you terminated TLS). TMS stays `http://localhost:3000` on port-forward, not Docker Compose’s 5000.

If `auth.authenticated` is `true`, admin-service expects a Keycloak JWT. Leave it `false` until you have loaded config and confirmed the pipeline (the default in `values/defaults.yaml`).

### Optional: clear the sample 901/902 map

Only do this if you want the tms-configuration payloads to be the only map in Postgres. This deletes configuration rows. It does not drop schema.

```powershell
kubectl exec -it -n tazama postgresql-0 -- psql -U postgres -d configuration
```

Then in `psql`:

```sql
TRUNCATE TABLE rule, typology, network_map;
\q
```

On Windows PowerShell, `kubectl exec -it` works the same way. If the pod name is not `postgresql-0`, run `kubectl get pods -n tazama -l app.kubernetes.io/name=postgres` (or `kubectl get pods -n tazama | findstr postgres`) and use that pod.

### POST rules, typologies, and the network map

From the **tms-configuration** repo root (the folder that contains `curl/rule-configs.json`):

```bash
curl -X POST "$ADMIN_URL/v1/admin/configuration/rule" \
  -H "Content-Type: application/json" \
  --data @curl/rule-configs.json

curl -X POST "$ADMIN_URL/v1/admin/configuration/typology" \
  -H "Content-Type: application/json" \
  --data @curl/typology-configs.json

curl -X POST "$ADMIN_URL/v1/admin/configuration/network_map" \
  -H "Content-Type: application/json" \
  --data @curl/network-map.json

curl -X POST "$ADMIN_URL/v1/admin/configuration/network_map/4.0.0/activate" \
  -H "Content-Type: application/json" \
  -d '{"reloadMode":"cascade"}'
```

**Windows PowerShell:** use `curl.exe` (not the `curl` alias) and `%ADMIN_URL%` in cmd, or `$env:ADMIN_URL` as above:

```powershell
curl.exe -X POST "$env:ADMIN_URL/v1/admin/configuration/rule" -H "Content-Type: application/json" --data "@curl/rule-configs.json"
curl.exe -X POST "$env:ADMIN_URL/v1/admin/configuration/typology" -H "Content-Type: application/json" --data "@curl/typology-configs.json"
curl.exe -X POST "$env:ADMIN_URL/v1/admin/configuration/network_map" -H "Content-Type: application/json" --data "@curl/network-map.json"
curl.exe -X POST "$env:ADMIN_URL/v1/admin/configuration/network_map/4.0.0/activate" -H "Content-Type: application/json" -d "{\"reloadMode\":\"cascade\"}"
```

Order matters: rules, then typologies, then the network map, then activate. A 2xx response per call is success. If a call returns 4xx, the JSON in `curl/` does not match what admin-service expects (ids, versions, or tenant).

After a config load, restart the processors so they pick up the active map:

```powershell
kubectl rollout restart -n tazama deploy/event-director deploy/typology-processor deploy/event-adjudicator
kubectl rollout status -n tazama deploy/event-director
```

### Send test traffic

Keep TMS port-forwarded (`svc/tms-service` `3000:3000`). Send pacs.008 and pacs.002 to `http://localhost:3000` using the messages in tms-configuration (Postman collection or raw ISO XML). Tenant id is `DEFAULT`.

The sample map that ships in SQL only lists `pacs.002.001.12`. Until you load and activate a full network map, a pacs.008 is accepted by TMS but Event Director logs that there is no network-map row for that `txTp`. After the activate call above, both message types should evaluate.

Results land in Postgres database `evaluation`, table `evaluation`:

```powershell
kubectl exec -it -n tazama postgresql-0 -- psql -U postgres -d evaluation -c "SELECT * FROM evaluation ORDER BY 1 DESC LIMIT 20;"
```

NATS also carries evaluation output (the relays in core publish to JetStream). You do not need a GraphQL overlay to confirm a hit.

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
| `core` | `environments/core.yaml` | Infra, Admin, TMS, ED, EF, TP, EA, Auth, Keycloak, three relays, public rule list |
| `full` | `environments/full.yaml` | Core plus TCS, TRS, CMS, DEAPI, DEMS, OpenSearch, CouchDB, Flowable. (Former name: `dockerhub`. The wrapper still accepts that alias.) |
| `private-rules` | `full` + `environments/private-rules.yaml` | Same as `full`, plus an optional private rule-image registry. Uncomment `rules.imageRegistry` (example `ghcr.io/frmscoe`). Former name: `member` (still accepted as an alias). |

Set the cloud with `-Cloud` (PowerShell) or the third argument. The wrapper exports `TAZAMA_CLOUD` and Helmfile loads `environments/cloud/<name>.yaml`.

| Cloud | Storage class | Ingress-nginx | Notes |
| --- | --- | --- | --- |
| `onprem` | cluster default (empty) | off | k3d, kind, kubeadm, RKE2. Use port-forward, or pass `-Ingress` / `--ingress` |
| `eks` | `gp3` | on, NLB annotations | Needs the AWS EBS CSI driver |
| `gke` | `standard-rwo` | on | Use `premium-rwo` in the overlay if you want SSD |
| `aks` | `managed-csi` | on, Azure probe path | Needs the Azure Disk CSI driver |

```powershell
.\tazama.cmd apply -Profile core -Cloud eks
.\tazama.cmd apply -Profile full -Cloud gke
.\tazama.cmd apply -Profile core -Cloud aks
```

```bash
./tazama.sh apply core eks
./tazama.sh apply full gke
./tazama.sh apply core aks
```

### Before you apply to EKS, GKE, or AKS

1. Generate unique secrets in `values/secrets.yaml` (see [Secrets and passwords](#secrets-and-passwords)).
2. Set `-IngressDomain` / `--ingress-domain`, or `ingress.domain` in the cloud overlay, to a DNS name you control.
3. Confirm the StorageClass exists: `kubectl get storageclass`. For EKS, create `gp3` if the cluster only has `gp2`.
4. Pin `global.tazamaVersion` to a tested tag instead of `rc`.
5. Prefer `-PostgresqlHost` (and `-PostgresqlReplicaHost` if BIAR is on).

When ingress is enabled:

- TMS: `tms.<ingress.domain>`
- Admin: `admin.<ingress.domain>`
- Auth: `auth.<ingress.domain>`
- Keycloak: `keycloak.<ingress.domain>`
- Connection Studio: `tcs.<ingress.domain>` and `tcs-api.<ingress.domain>`
- Rule Studio: `trs.<ingress.domain>` and `trs-api.<ingress.domain>`
- CMS: `cms.<ingress.domain>` and `cms-api.<ingress.domain>`
- NiFi (when BIAR is on): `nifi.<ingress.domain>`

### Local overlay tests (optional)

These scripts check that the `eks` / `gke` / `aks` overlays install. They do **not** replace a real cloud cluster.

[Floci](https://floci.io) emulates AWS, GCP, and Azure on Docker Desktop and starts a k3s container per cloud. That is a Kubernetes API without real CSI drivers, NLBs, or managed control planes. Use a real account when you care about those. Clouds run one after another so k3s API ports do not overlap. From the repo root:

```powershell
.\test\test-floci.ps1
.\test\test-floci.ps1 -Clouds eks
```

```bash
./test/test-floci.sh
```

`test/test-clouds.ps1` (and `test/test-clouds.sh`) templates or installs every overlay against **one** local cluster (Kind, k3s, Docker Desktop) and aliases the cloud StorageClass names. Use `-Mode render` to compile only, `-Mode install` to bring pods up.

```powershell
.\test\test-clouds.ps1
.\test\test-clouds.ps1 -Mode install
```

## Example installations

The wrappers take a command, a profile, a cloud, optional package switches, and optional relay or host strings. Omitted flags leave the profile YAML unchanged. Combine switches on one command. Auth and Keycloak stay on in `core`; the wrappers do not turn them off.

Copy `values/secrets.example.yaml` to `values/secrets.yaml` once, as in [End-to-end setup](#3-clone-the-repo-and-prepare-secrets). Work from this folder.

### 1. Core only (default)

When to use it: a first on-prem install of the transaction pipeline, with no studios, CMS, or BIAR.

`environments/core.yaml` already turns on Admin, TMS, ED, EF, TP, EA, Auth, Keycloak, three NATS relays, the public rule list, Postgres, NATS, and Valkey. The in-cluster Postgres replica stays off.

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem
```

**bash:**

```bash
./tazama.sh apply core onprem
```

### 2. Core plus CMS

When to use it: Case Management on a core cluster. `-Cms` / `--cms` also turns on Flowable, CouchDB, and OpenSearch (CMS is invalid without them).

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem -Cms
```

**bash:**

```bash
./tazama.sh apply core onprem --cms
```

The `full` profile already turns CMS on with those three dependencies.

### 3. Core plus extensions and tools

When to use it: DEMS and DEAPI (`-Extensions` / `--extensions`) plus Connection Studio and Rule Studio (`-Tools` / `--tools`) on core, without the `full` profile. `-Dems` / `-Deapi` / `-ConnectionStudio` / `-RuleStudio` (and the bash long flags) turn one package on.

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem -Extensions -Tools
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
.\tazama.cmd apply -Profile core -Cloud onprem -Biar -PostgresReplica
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
.\tazama.cmd apply -Profile core -Cloud onprem -Biar -PostgresqlReplicaHost "mydb-ro.xxxx.rds.amazonaws.com"
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
.\tazama.cmd apply -Profile core -Cloud onprem -RelayEa kafka -KafkaBrokers "kafka.example.com:9092"
```

**bash:**

```bash
./tazama.sh apply core onprem --relay-ea kafka --kafka-brokers kafka.example.com:9092
```

Helmfile fails if any transport is `kafka` and `relay.kafka.brokers` is empty.

RabbitMQ example (EA to a broker you already run):

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem -RelayEa rabbitmq -RabbitmqUrl "amqp://user:pass@rabbit.example.com:5672"
```

**bash:**

```bash
./tazama.sh apply core onprem --relay-ea rabbitmq --rabbitmq-url amqp://user:pass@rabbit.example.com:5672
```

Helmfile fails if any transport is `rabbitmq` and `relay.rabbitmq.url` is empty.

REST example (EA to an HTTP endpoint you already run):

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem -RelayEa rest -RestUrl "https://relay.example.com/intake"
```

**bash:**

```bash
./tazama.sh apply core onprem --relay-ea rest --rest-url https://relay.example.com/intake
```

Helmfile fails if any transport is `rest` and `relay.rest.url` is empty. Relays still consume from in-cluster NATS. The transport setting only changes where they produce.

### 7. Full (studios, CMS, enrichment)

When to use it: public Docker Hub images, Connection Studio, Rule Studio, CMS (with Flowable, CouchDB, and OpenSearch), DEAPI, and DEMS. Flags live in `environments/full.yaml`. The public rule list is already in `core`. BIAR stays off.

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile full -Cloud onprem
```

**bash:**

```bash
./tazama.sh apply full onprem
```

### 8. Private rule registry (`private-rules`)

When to use it: the same stack as `full`, but rule images come from a private registry (example `ghcr.io/frmscoe`).

The `private-rules` profile loads `environments/full.yaml`, then `environments/private-rules.yaml`. Uncomment and set the registry (advanced YAML edit):

```yaml
# environments/private-rules.yaml
rules:
  imageRegistry: ghcr.io/frmscoe
```

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile private-rules -Cloud onprem
```

**bash:**

```bash
./tazama.sh apply private-rules onprem
```

Public `tazamaorg/rule-NNN` images stay on Docker Hub until you set `imageRegistry`. [frmscoe](https://github.com/frmscoe) repos are often processing-engines and typologies, not `rule-NNN`. Map those images by their real names. `-Profile member` still works as an alias.

### 9. Cloud (EKS)

When to use it: the same profile on Amazon EKS. The wrapper sets `TAZAMA_CLOUD` and Helmfile loads `environments/cloud/eks.yaml` (ingress-nginx on, `gp3` StorageClass). GKE and AKS are the same pattern with `-Cloud gke` or `-Cloud aks`. Package switches work the same as on-prem.

Set `ingress.domain` in that cloud overlay to a DNS name you control before you apply. Replace passwords in `values/secrets.yaml`. Confirm the StorageClass exists.

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile core -Cloud eks
.\tazama.cmd apply -Profile full -Cloud gke
.\tazama.cmd apply -Profile core -Cloud eks -Cms
```

**bash:**

```bash
./tazama.sh apply core eks
./tazama.sh apply full gke
./tazama.sh apply core eks --cms
```

### 10. Managed Postgres

When to use it: apps should use an external database instead of in-cluster Postgres. `-PostgresqlHost` sets the host and turns in-cluster Postgres off.

**PowerShell:**

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem -PostgresqlHost "mydb.xxxx.rds.amazonaws.com"
```

**bash:**

```bash
./tazama.sh apply core onprem --postgresql-host mydb.xxxx.rds.amazonaws.com
```

Keep `values/secrets.yaml` in sync with that database user. Create the Tazama database names (`configuration`, `raw_history`, `event_history`, `evaluation`) on the server. Create a `keycloak` database if you keep Keycloak on.

If BIAR is also on, pass `-PostgresqlReplicaHost` / `--postgresql-replica-host` as in example 5. Do not pass `-PostgresReplica` here: the in-cluster replica requires `install.postgresql`.

### 11. On-prem with ingress

When to use it: reach TMS and Admin by hostname on a local cluster instead of port-forward. This does **not** change the default `core` / `onprem` install. You must pass the flag.

**PowerShell or cmd:**

```powershell
.\tazama.cmd apply -Profile core -Cloud onprem -Ingress -IngressDomain tazama.local
```

**bash:**

```bash
./tazama.sh apply core onprem --ingress --ingress-domain tazama.local
```

On-prem defaults the controller Service to NodePort so Helm `--wait` does not hang on a pending LoadBalancer IP (Kind and Docker Desktop have no cloud LB). Cloud overlays still use LoadBalancer. Override with `-IngressServiceType LoadBalancer` if you have MetalLB or another LB controller. Map `tms.tazama.local` (and the other prefixes) in `/etc/hosts` or the Windows hosts file, then run `kubectl get ingress -n tazama`.

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

Never commit `values/secrets.yaml`. It is created from `values/secrets.example.yaml` and should stay gitignored. Each clone generates **its own** random values so two production installs do not share passwords.

On first wrapper run, dummy placeholders (`unused`, `password`, `tazama`, `auth-lib-client-test-secret`, empty Valkey password, empty Auth keys, and the old published test RSA pair) are replaced with **20-character URL-safe secrets** (`openssl rand -base64 15`, then `+/=` stripped so they are safe in YAML and in Postgres URLs). Auth gets a fresh 2048-bit RSA pair. Existing longer secrets in `values/secrets.yaml` are left alone unless you pass `-GenerateSecrets` / `--generate-secrets`.

Keep **plaintext** in `values/secrets.yaml`. Kubernetes Secret objects (`tazama-credentials`) store those strings as `stringData` and base64-encode them for etcd. Do **not** paste `kubectl get secret -o json` / `--export` data back into the file (that would double-encode).

To generate secrets without talking to the cluster (copy the file into a vault, then apply):

```powershell
.\tazama.cmd secrets
```

```bash
./tazama.sh secrets
```

Generated fields:

- `secrets.postgres.password` and `secrets.postgres.replicationPassword`
- `secrets.keycloak.adminPassword` and `secrets.keycloak.clientSecret` (the imported realm client secret is rewritten to match)
- `secrets.valkey.password` (Valkey ACL auth turns on when this is non-empty)
- `secrets.auth.publicKey` / `secrets.auth.privateKey`

Docker Hub pull credentials are never auto-generated. Keycloak `adminUser` stays `admin`; the password is random.

To rotate even if values are no longer dummies:

```powershell
.\tazama.cmd secrets -GenerateSecrets
.\tazama.cmd apply -Profile core -Cloud onprem
```

```bash
./tazama.sh secrets --generate-secrets
./tazama.sh apply core onprem
```

Open `values/secrets.yaml` to copy values into `psql` or the Keycloak admin console. After you change `postgres.password` on a cluster that already initialized Postgres, the PVC still has the old role password. Wipe the PVC (you will lose data) or `ALTER USER` inside Postgres, then apply again.

Edit `values/secrets.yaml` by hand if you already have a managed-database password. The wrapper leaves non-dummy values alone unless you pass `-GenerateSecrets` / `--generate-secrets`.

Optional Docker Hub pull secret: `secrets.dockerHub.createPullSecret: true` plus username and password.

Helm stores values on the release Secret in the cluster. Treat the cluster as trusted, or plan an external secrets controller later. Do not ship real TLS keys in git.

## Add or remove later

Each service is its own Helm release. To add something, pass the wrapper flag (for example `-Cms` / `--cms`) and run apply again.

Turning a flag off and running apply does not always delete a release that is no longer listed (rules are generated from `rules.enabled`). To take something out of the cluster:

```powershell
# 1) destroy those releases (CMS was added with -Cms)
.\tazama.cmd destroy -Profile core -Cloud onprem -Selector "name=cms-backend"
.\tazama.cmd destroy -Profile core -Cloud onprem -Selector "name=cms-frontend"

# Remove one rule: delete "901" from rules.enabled, then
.\tazama.cmd destroy -Profile core -Cloud onprem -Selector "name=rule-901"

.\tazama.cmd apply -Profile core -Cloud onprem
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

Add extra public rules by appending ids to `rules.enabled` and running apply. If the image is not `docker.io/tazamaorg/rule-NNN`, set `rules.imageRegistry`. `environments/private-rules.yaml` has a commented example for `ghcr.io/frmscoe`. [frmscoe](https://github.com/frmscoe) repos are often processing-engines and typologies, not `rule-NNN`. Map those images explicitly when you have the real names. Keep private registry overrides in the `private-rules` overlay, not in `core`.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Pods `Pending`, PVC `Pending` | No StorageClass, or the class in the cloud overlay does not exist. Run `kubectl get storageclass` and set `storageClass` in `environments/cloud/<name>.yaml`. |
| First boot takes a long time / processors in Init | Postgres is still running `00-CREATE.sql` and `10-core-config.sql`. Those scripts run only on an empty data directory. Core and rule pods wait until table `pain013` exists in `raw_history`, and until Valkey `:6379` and NATS `:4222` accept TCP. |
| Postgres CrashLoop / init errors | `kubectl logs -n tazama statefulset/postgresql`. If you changed SQL after the first boot, delete the Postgres PVC (you will lose data) or apply SQL yourself with `psql`. |
| Keycloak CrashLoop on a reused PVC | SQL init does not re-run. As postgres, run `CREATE DATABASE keycloak;` if that database is missing. Confirm ConfigMap `keycloak-realm` is mounted. |
| `apply` did not show a diff | helm-diff is not installed. The wrapper wrote a warning to stderr and used `helmfile sync`. Install helm-diff, or run `sync` on purpose. First install: prefer `sync` because helm-diff can skip nested helmfiles. |
| ImagePullBackOff | Docker Hub rate limit or a private image. Set `secrets.dockerHub.createPullSecret: true` and credentials in `values/secrets.yaml`. |
| Relay template error about brokers/url | Pass `-KafkaBrokers` / `--kafka-brokers`, `-RabbitmqUrl` / `--rabbitmq-url`, or `-RestUrl` / `--rest-url` for that transport. Helm does not install those brokers. |
| TMS up but no rule hits | Core SQL config is 901/902 on `pacs.002.001.12`. Send a pacs.002, or load a full map via admin-service and activate with `reloadMode: cascade`, then restart Event Director, Typology Processor, and Event Adjudicator. |
| Event Director: no network map for tenant DEFAULT | The map has no row for that `txTp` (often pacs.008 while only pacs.002 is loaded). Load and activate [tms-configuration](https://github.com/frmscoe/tms-configuration), then restart ED / TP / EA. |
| `curl` on Windows returns a weird error / empty body | PowerShell aliases `curl` to `Invoke-WebRequest`. Use `curl.exe`. |
| `helmfile` is not on PATH / version 0.x | Install Helmfile **1.x** from [releases](https://github.com/helmfile/helmfile/releases). This repo’s entry file is `helmfile.yaml.gotmpl`. |
| Kind install: Helm waits 900s on ingress-nginx | On-prem ingress must stay NodePort (default). Kind has no cloud load balancer. Do not set `-IngressServiceType LoadBalancer` unless you have MetalLB or equivalent. |
| `FATAL: sorry, too many clients already` | Pods times pool size exceeds `postgres.maxConnections`. Raise the sizing tier, cut replica counts, or add a pooler. See [Connection pooling](#connection-pooling-and-max_connections). |
| Pods `Pending` after `-Sizing` | The tier asks for more CPU or memory than the cluster has. Run `kubectl get nodes` and `kubectl top nodes`, then drop to a lower tier. Tiers above `standard` do not fit on Kind. |
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
| First install (no helm-diff) | `.\tazama.cmd sync -Profile core -Cloud onprem` | `./tazama.sh sync core onprem` |
| Install or upgrade | `.\tazama.cmd apply -Profile core -Cloud onprem` | `./tazama.sh apply core onprem` |
| Core plus CMS | `.\tazama.cmd apply -Profile core -Cloud onprem -Cms` | `./tazama.sh apply core onprem --cms` |
| Core plus extensions and tools | `.\tazama.cmd apply -Profile core -Cloud onprem -Extensions -Tools` | `./tazama.sh apply core onprem --extensions --tools` |
| Core plus BIAR (in-cluster replica) | `.\tazama.cmd apply -Profile core -Cloud onprem -Biar -PostgresReplica` | `./tazama.sh apply core onprem --biar --postgres-replica` |
| Relay EA to Kafka | `.\tazama.cmd apply -Profile core -Cloud onprem -RelayEa kafka -KafkaBrokers "kafka.example.com:9092"` | `./tazama.sh apply core onprem --relay-ea kafka --kafka-brokers kafka.example.com:9092` |
| Full profile | `.\tazama.cmd apply -Profile full -Cloud onprem` | `./tazama.sh apply full onprem` |
| Cloud EKS | `.\tazama.cmd apply -Profile core -Cloud eks` | `./tazama.sh apply core eks` |
| Managed Postgres host | `.\tazama.cmd apply -Profile core -Cloud onprem -PostgresqlHost "mydb.xxxx.rds.amazonaws.com"` | `./tazama.sh apply core onprem --postgresql-host mydb.xxxx.rds.amazonaws.com` |
| On-prem with ingress | `.\tazama.cmd apply -Profile core -Cloud onprem -Ingress -IngressDomain tazama.local` | `./tazama.sh apply core onprem --ingress --ingress-domain tazama.local` |
| Overlay tests (Floci) | `.\test\test-floci.ps1` | `./test/test-floci.sh` |
| Overlay render (no cluster) | `.\test\test-clouds.ps1` | `./test/test-clouds.sh` |
| Generate unique secrets only (no cluster) | `.\tazama.cmd secrets` | `./tazama.sh secrets` |
| Preview the diff | `.\tazama.cmd diff -Profile core -Cloud onprem` | `./tazama.sh diff core onprem` |
| Render YAML | `.\tazama.cmd template -Profile core -Cloud onprem -Cms` | `./tazama.sh template core onprem --cms` |
| Status | `.\tazama.cmd status -Profile core -Cloud onprem` | `./tazama.sh status core onprem` |
| Lint | `.\tazama.cmd lint -Profile core -Cloud onprem` | `./tazama.sh lint core onprem` |
| Uninstall everything this Helmfile owns | `.\tazama.cmd destroy -Profile core -Cloud onprem` | `./tazama.sh destroy core onprem` |
| One release only | `.\tazama.cmd destroy -Profile core -Cloud onprem -Selector "name=tms-service"` | `./tazama.sh destroy core onprem name=tms-service` |

Allowed profiles: `core`, `full`, `private-rules` (`member` is an alias for `private-rules`; `dockerhub` is an alias for `full`). Allowed clouds: `onprem`, `eks`, `gke`, `aks`. Allowed sizing tiers: `standard`, `small`, `medium`, `large`. Defaults if you omit them: `apply`, `core`, `onprem`, `standard`. Relay transports: `nats`, `kafka`, `rabbitmq`, `rest`.

`apply` is `helmfile apply` when helm-diff is installed, otherwise `helmfile sync`. `sync` always runs `helmfile sync`.

## For operators

The wrapper runs `helmfile -e <profile> -f helmfile.yaml.gotmpl` with `TAZAMA_CLOUD` set. Package and host flags become `--state-values-set` / `--state-values-set-string` (Helmfile 1.x state overrides, not Helm chart `--set`). You can call helmfile yourself from this folder. If `KUBECONFIG` is set, the wrapper passes `--kubeconfig`.

Values merge in this order (later files win):

1. `values/defaults.yaml` (namespace, image tag, hosts, every `install.*` flag, relay transports, replica counts)
2. `values/ingress.yaml` (ingress hosts, domain, class, nginx service type; still off on on-prem)
3. Profile: `environments/core.yaml`, or `environments/full.yaml`, or `full` plus `environments/private-rules.yaml`
4. Cloud: `environments/cloud/{{ TAZAMA_CLOUD }}.yaml` (default `onprem`)
5. Sizing: `values/sizing/{{ TAZAMA_SIZING }}.yaml` (default `standard`)
6. `values/secrets.yaml`
7. Wrapper `--state-values-set` / `--state-values-set-string` (only keys you passed)

`TAZAMA_SIZING` is exported by the wrapper from `-Sizing` / `--sizing`, the same way `TAZAMA_CLOUD` works.

Useful keys in `values/defaults.yaml`:

```yaml
namespace: tazama
global:
  tazamaVersion: "rc"          # pin to a tested tag for shared or production
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
  values/ingress.yaml           # ingress hosts/domain (off on on-prem)
  values/sizing/               # replica tiers: standard, small, medium, large
  values/secrets.example.yaml
  environments/                 # core, full, private-rules
  environments/cloud/           # onprem, eks, gke, aks
  charts/tazama-workload/       # generic app chart
  charts/tazama-files/          # SQL, Keycloak realm, credentials
  datastore/ auxiliary/ core/ rules/ extensions/ biar/
```

## License

Apache-2.0. SQL and env defaults are derived from [tazama-stack](https://github.com/tazama-lf/tazama-stack) (Apache-2.0).
