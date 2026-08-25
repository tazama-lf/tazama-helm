# Tazama Helm chart

This chart deploys a sandbox-style Tazama stack based on the DockerHub full-install path from the `tazama/feat/mono-repo-phased-deployment` branch of [Full-Stack-Docker-Tazama](https://github.com/tazama-lf/Full-Stack-Docker-Tazama).

It includes core Tazama services, configurable rule deployments, extensions, BIAR services, PostgreSQL bootstrap scripts, ingress, and persistent storage. It is a development and reference chart, not a production-ready platform distribution.

## Prerequisites

- Kubernetes 1.27 or newer
- Helm 3
- `kubectl` configured for the target cluster
- An ingress controller if browser access through hostnames is required
- A storage class that supports the requested PVCs
- Access to the configured container registries

Check the local tools and cluster before installing:

```powershell
helm version
kubectl cluster-info
kubectl get storageclass
```

## Before the first install

The default values are suitable only for a local sandbox. Review these items first:

1. **Replace every default credential.** This includes PostgreSQL, CouchDB, Flowable, NiFi, Keycloak, Hasura, and SFTP credentials in `values.yaml` and `values-full-dockerhub.yaml`.
2. **Replace the example authentication keypair.** The repository currently contains example RSA key material in `values.yaml`, `tazama-auth-rsa`, and `tazama-auth-rsa.pub`. Generate a new pair and do not commit private keys.
3. **Keep secrets out of source control.** Put secret overrides in a local, ignored values file or use an external secrets solution. Helm release values can still be stored in the cluster, so use your organization's secret-management policy.
4. **Pin image versions.** Replace the default `rc` Tazama version and `Always` pull policy with tested release tags or digests.
5. **Choose storage.** Set `global.storageClass` or the component-specific storage classes and review the PVC sizes.
6. **Review ingress.** Change `ingress.domain`, TLS settings, hostnames, and annotations for the target cluster. Set `ingress.enabled: false` when using port-forwarding or an external gateway.
7. **Decide which infrastructure is managed here.** PostgreSQL, Valkey, NATS, OpenSearch, Solr, and Ozone are deployed by this chart. For production, consider managed services or dedicated operators and configure Tazama to use them instead.

## Values that must be supplied

Do not commit real values for any field listed below. The defaults in `values.yaml` are placeholders or development settings and must be overridden in a local ignored file, through your deployment pipeline, or with an external secrets provider.

### Kubernetes Secret values

These fields are copied into the `tazama-credentials` Secret by `templates/secrets.yaml`:

| Values path | Used for |
| --- | --- |
| `secrets.postgres.username` / `password` | Core PostgreSQL |
| `secrets.extensionsPostgres.username` / `password` | Extensions PostgreSQL |
| `secrets.couchdb.username` / `password` | CouchDB |
| `secrets.flowable.username` / `password` | Flowable |
| `secrets.nifi.username` / `password` | NiFi single-user login |
| `secrets.keycloak.adminUser` / `adminPassword` | Keycloak administrator |
| `secrets.hasura.adminSecret` | Hasura administrator secret |

The authentication key values are stored in the separate `tazama-auth-public-key` Secret:

| Values path | Used for |
| --- | --- |
| `secrets.auth.publicKey` | Auth certificate mounted by Admin, TMS, TCS, TRS, and CMS |
| `secrets.auth.privateKey` | Private signing key mounted by the Auth service |

The private key must never be committed. The public key is also environment-specific and should be replaced when rotating the pair.

### Extension environment values

The following values are currently rendered into component configuration and must be replaced when the related feature is enabled:

| Values path | Fields to provide |
| --- | --- |
| `extensions.sftp.user` / `password` | SFTP login used by the SFTP StatefulSet |
| `extensionsApis.env.deapi` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `DB_USER`, `DB_PASSWORD`, `REDIS_PASSWORD`, `ENCRYPTION_KEY`, `APM_SECRET_TOKEN` |
| `extensionsApis.env.dems` | `DB_USER`, `DB_PASSWORD`, `DYNAMIC_HISTORY_DB_USER`, `DYNAMIC_HISTORY_DB_PASSWORD`, `EVENT_HISTORY_DB_USER`, `EVENT_HISTORY_DB_PASSWORD`, `REDIS_PASSWORD` |
| `extensions.env.tcs` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `CONFIGURATION_DATABASE_USER`, `CONFIGURATION_DATABASE_PASSWORD`, `ENCRYPTION_KEY`, `SFTP_USERNAME_CONSUMER`, `SFTP_PASSWORD_CONSUMER`, `SFTP_USERNAME_PRODUCER`, `SFTP_PASSWORD_PRODUCER`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM_EMAIL`, `OPENSEARCH_USERNAME`, `OPENSEARCH_PASSWORD`, `TAZAMA_AUTH_ADMIN_USERNAME`, `TAZAMA_AUTH_ADMIN_PASSWORD` |
| `extensions.env.trs` | `CRYPTO_SECRET_KEY`, `ENCRYPTION_KEY`, `OPENSEARCH_USERNAME`, `OPENSEARCH_PASSWORD`, `VITE_CRYPTO_KEY`, `TAZAMA_AUTH_ADMIN_USERNAME`, `TAZAMA_AUTH_ADMIN_PASSWORD`, `DOCKERHUB_TOKEN`, `DOCKERHUB_USERNAME`, `DOCKERHUB_NAMESPACE` |
| `extensions.env.cms` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `DWH_DATABASE_URL`, `FLOWABLE_USERNAME`, `FLOWABLE_PASSWORD`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`, `REDIS_PASSWORD`, `SMTP_USER`, `SMTP_PASS`, `MAIL_FROM`, `TAZAMA_AUTH_ADMIN_USERNAME`, `TAZAMA_AUTH_ADMIN_PASSWORD`, `COUCHDB_USER`, `COUCHDB_PASSWORD`, `OPENSEARCH_USERNAME`, `OPENSEARCH_PASSWORD`, `VITE_CRYPTO_KEY` |

The `DOCKERHUB_TOKEN` is a registry access token, not an application setting. It should normally be configured as an image-pull Secret through `imagePullSecrets`, rather than exposed as a pod environment variable. Revoke any token that has ever been committed to Git and create a replacement with the minimum required scope.

### Private-key generation

Generate a new RSA keypair with OpenSSL. Run this outside the repository or write the files only to an ignored secrets directory:

```powershell
New-Item -ItemType Directory -Force .secrets | Out-Null
openssl genrsa -out .secrets/tazama-auth-rsa 2048
openssl rsa -in .secrets/tazama-auth-rsa -pubout -out .secrets/tazama-auth-rsa.pub
```

Use the generated files without placing their contents in `values.yaml`:

```powershell
helm upgrade --install tazama . `
	--namespace tazama --create-namespace `
	-f values-full-dockerhub.yaml `
	-f values-local.yaml `
	--set-file secrets.auth.privateKey=.secrets/tazama-auth-rsa `
	--set-file secrets.auth.publicKey=.secrets/tazama-auth-rsa.pub
```

For an existing keypair, verify that the public key matches the private key before deploying:

```powershell
openssl rsa -in .secrets/tazama-auth-rsa -pubout |
	Compare-Object (Get-Content .secrets/tazama-auth-rsa.pub)
```

Also add `.secrets/`, `values-local.yaml`, and rendered manifests such as `rendered.yaml` to `.gitignore`. A secret removed from the working tree remains exposed in Git history and must be revoked or rotated.

Example local override file:

```yaml
# values-local.yaml; keep this file outside source control

	tazamaVersion: "4.0.0"
	imagePullPolicy: IfNotPresent
	storageClass: "your-storage-class"

secrets:
	postgres:
		username: "replace-me"
		password: "replace-me"
	keycloak:
		adminUser: "replace-me"
		adminPassword: "replace-me"
	auth:
		publicKey: |
			-----BEGIN PUBLIC KEY-----
			replace-me
			-----END PUBLIC KEY-----
		privateKey: |
			-----BEGIN RSA PRIVATE KEY-----
			replace-me
			-----END RSA PRIVATE KEY-----

scheduling:
	workerOnly: true
```

For local key files, Helm can load the values without putting the key contents in the command history:

```powershell
helm upgrade --install tazama . `
	--namespace tazama --create-namespace `
	-f values-full-dockerhub.yaml `
	-f values-local.yaml `
	--set-file secrets.auth.privateKey=./tazama-auth-rsa `
	--set-file secrets.auth.publicKey=./tazama-auth-rsa.pub
```

## Validate and render

Run these commands from this chart directory:

```powershell
helm lint .
helm template tazama . -f values-full-dockerhub.yaml > rendered.yaml
```

Inspect `rendered.yaml` before applying it. A Kubernetes API dry run is also useful:

```powershell
kubectl apply --dry-run=server -f rendered.yaml
```

## Install or upgrade

The DockerHub overlay enables the full extensions and BIAR paths:

```powershell
helm upgrade --install tazama . `
	--namespace tazama --create-namespace `
	-f values-full-dockerhub.yaml `
	-f values-local.yaml
```

The last values file wins when the same setting appears in multiple files. For a smaller core-only installation, omit `values-full-dockerhub.yaml` and disable components in a separate override file.

Watch the rollout and inspect storage:

```powershell
kubectl get pods -n tazama -w
kubectl get services,ingress,pvc -n tazama
helm status tazama -n tazama
```

Core application and rule pods wait for the PostgreSQL schema, Valkey, and NATS before starting. These checks are enabled by default and can be configured under `global.startupChecks`. Set `global.startupChecks.enabled: false` only when those dependencies are managed and readiness is handled elsewhere.

## Accessing the deployment

When ingress is enabled, use the configured hostnames under `ingress.hosts` and ensure DNS resolves them to the ingress controller. For a local cluster without ingress, use port-forwarding:

```powershell
kubectl port-forward -n tazama service/tazama-core-admin 5100:5100
kubectl port-forward -n tazama service/tazama-core-tms 3000:3000
```

The exact service names include the Helm release and chart name. Check them with `kubectl get services -n tazama`.

## Common operations

Show the effective chart values:

```powershell
helm show values .
```

List the installed resources:

```powershell
kubectl get all -n tazama
kubectl get statefulsets,jobs,pvc -n tazama
```

View logs for a workload:

```powershell
kubectl logs -n tazama deployment/tazama-core-admin
kubectl logs -n tazama deployment/tazama-core-ed
```

Uninstall the release:

```powershell
helm uninstall tazama -n tazama
```

StatefulSet PVCs are intentionally retained by Kubernetes after uninstall. Delete them only after confirming that the stored data is no longer needed:

```powershell
kubectl get pvc -n tazama
kubectl delete pvc <pvc-name> -n tazama
```

## Configuration reference

- `values.yaml`: chart defaults and the complete component configuration surface.
- `values-full-dockerhub.yaml`: overlay enabling the full DockerHub extensions and BIAR deployment.
- `global.startupChecks`: dependency startup checks and schema readiness settings.
- `scheduling.workerOnly`: optional control-plane avoidance based on the remote chart's affinity pattern.
- `core.rules.enabledRules`: list of rule IDs to deploy when `core.rules.fullEnabled` is true.
- `ingress.hosts`: external hostnames and target services.

Review image tags, credentials, persistence, ingress, and resource requests for every target environment. The chart currently has no automated backup, disaster recovery, certificate rotation, or production database/operator lifecycle management.
