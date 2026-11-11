# Tazama Helmfile command extras

Read this only when the user wants packages beyond default core, a non-onprem cloud, relays, selectors, or uninstall.

Run from the repo root. Windows: `.\tazama.cmd`. bash: `./tazama.sh <command> <profile> <cloud> [flags]`.

Shape:

```text
.\tazama.cmd <command> -Profile <profile> -Cloud <cloud> [-Sizing <tier>] [package flags...] [-Selector "<label>"]
./tazama.sh  <command> <profile> <cloud> [--sizing <tier>] [package flags...] [--selector <label>]
```

Commands: `sync` (first install) | `apply` | `diff` | `template` | `status` | `lint` | `destroy` | `secrets` | `configure` | `tenant` | `e2e`.

Profiles: `core` | `full` | `private-rules` (`member` = private-rules, `dockerhub` = full).
Clouds: `onprem` | `eks` | `gke` | `aks`.
Sizing: `standard` | `small` | `medium` | `large`.

## Package flags

| Windows | bash | Effect |
| --- | --- | --- |
| `-Cms` | `--cms` | CMS + Flowable + CouchDB + OpenSearch |
| `-Extensions` | `--extensions` | DEMS + DEAPI |
| `-Tools` | `--tools` | Connection Studio + Rule Studio |
| `-Biar` | `--biar` | NiFi. Also pass `-PostgresReplica` or `-PostgresqlReplicaHost` |
| `-Ingress` | `--ingress` | ingress-nginx + Ingress objects (onprem default NodePort) |
| `-GenerateSecrets` | `--generate-secrets` | Rotate `values/secrets.yaml` |

## Recipes

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem -Cms
.\tazama.cmd sync -Profile core -Cloud onprem -Extensions -Tools
.\tazama.cmd sync -Profile full -Cloud onprem
.\tazama.cmd sync -Profile core -Cloud onprem -Biar -PostgresReplica
.\tazama.cmd sync -Profile core -Cloud onprem -Ingress -IngressDomain tazama.local
.\tazama.cmd sync -Profile core -Cloud eks -IngressDomain tm.example.com
.\tazama.cmd sync -Profile core -Cloud onprem -RelayEa kafka -KafkaBrokers "kafka.example.com:9092"
.\tazama.cmd destroy -Profile core -Cloud onprem -Selector "name=tms-service"
.\tazama.cmd configure -Truncate
.\tazama.cmd tenant
.\tazama.cmd e2e
```

```bash
./tazama.sh sync core onprem --cms
./tazama.sh sync full onprem --sizing medium --biar --postgres-replica
./tazama.sh destroy core onprem name=tms-service
./tazama.sh configure --truncate
./tazama.sh tenant
./tazama.sh e2e
```

Helm does not install Kafka or RabbitMQ. Relays still consume from in-cluster NATS.
