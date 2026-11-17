# GCP k3s test cluster

One Compute Engine VM running **k3s** (not GKE). OpenTofu creates it; Helmfile from this repo installs Tazama; Lens uses the kubeconfig; SSH is for the box.

This is a disposable test cluster. Tear it down when you are done.

## Sizing

`-Sizing` picks both the **machine type** and the Helm replica file in `values/sizing/`.

| `-Sizing` | GCE | vCPU / RAM |
| --- | --- | --- |
| `small` | `e2-medium` | 2 / 4 GB |
| `medium` | `e2-standard-2` | 2 / 8 GB |
| `large` | `e2-standard-4` | 4 / 16 GB |

Default is `medium`. `large` is the most comfortable size for a `core` install.

## What you get

- VPC network, subnet `10.42.1.0/24`, static external IP
- Ubuntu 22.04, k3s (Traefik off so Helmfile can install ingress-nginx)
- SSH as `ubuntu` with a generated key (`id_rsa`, gitignored)
- Kubernetes API on `https://<external-ip>:6443`
- `kubeconfig.yaml` for Lens and `kubectl`
- SSH and :6443 limited to your current public IP (`/32`)

## How login works

There are three separate logins. None of them is a username/password prompt inside `up.ps1`.

### 1. GCP project (this is how OpenTofu bills your project)

OpenTofu uses **Application Default Credentials** from the `gcloud` CLI already on your laptop.

```powershell
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gcloud services enable compute.googleapis.com --project YOUR_PROJECT_ID
gcloud auth application-default print-access-token
```

The account needs permission to create Compute Engine VMs, addresses, networks, and firewalls. `roles/compute.admin` on the project is enough for this stack. You do not need GKE or Cloud SQL permissions.

Org policies that block external IPs will fail `google_compute_address`. Ask an admin to allow a static IP in the region, or pick a project without that constraint.

### 2. SSH into the VM (this is not your Google password)

OpenTofu generates an SSH key pair on apply and puts the public half in instance metadata (`ssh-keys`). The private half is written to `infra/gcp/id_rsa` (gitignored):

```powershell
ssh -i .\infra\gcp\id_rsa -o StrictHostKeyChecking=no ubuntu@<external-ip>
```

### 3. Kubernetes / Lens (this is not GCP login either)

After k3s is up, `up.ps1` copies `kubeconfig.yaml` off the instance over SSH. Point Lens or `kubectl` at it.

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) 1.6+ (`tofu version`), or Terraform
- Google Cloud SDK (`gcloud`) with ADC (`gcloud auth application-default login`)
- Compute Engine API enabled on the project
- OpenSSH client (`ssh`)
- This repo’s usual tools for the Helmfile step: `kubectl`, Helm, Helmfile

## Bring it up

From the repo root:

```powershell
.\infra\gcp\up.cmd -Sizing small -Project YOUR_PROJECT_ID
.\infra\gcp\up.cmd -Sizing medium -Project YOUR_PROJECT_ID
.\infra\gcp\up.cmd -Sizing large -Project YOUR_PROJECT_ID
```

```bash
./infra/gcp/up.sh --sizing small --project YOUR_PROJECT_ID
./infra/gcp/up.sh --sizing medium --project YOUR_PROJECT_ID
./infra/gcp/up.sh --sizing large --project YOUR_PROJECT_ID
```

That runs `tofu apply -var sizing=...`, waits until k3s is Ready, and copies kubeconfig next to the stack.

Optional: copy `terraform.tfvars.example` to `terraform.tfvars` to pin region, zone, or `allowed_cidr`.

## Point Lens and Helmfile at it

```powershell
$env:KUBECONFIG = "$PWD\infra\gcp\kubeconfig.yaml"
kubectl get nodes
```

```bash
export KUBECONFIG="$PWD/infra/gcp/kubeconfig.yaml"
kubectl get nodes
```

In Lens: **File > Add Cluster** and choose `infra/gcp/kubeconfig.yaml`.

Install Tazama with the **same** sizing you passed to `up.cmd`:

```powershell
$env:KUBECONFIG = "$PWD\infra\gcp\kubeconfig.yaml"
.\tazama.cmd sync -Profile core -Cloud onprem -Sizing medium
```

```bash
export KUBECONFIG="$PWD/infra/gcp/kubeconfig.yaml"
./tazama.sh sync core onprem --sizing medium
```

Do **not** use `-Cloud gke`. That overlay expects a GKE StorageClass and a cloud load balancer. This node is k3s.

## Tear down

```powershell
.\infra\gcp\down.cmd
```

```bash
./infra/gcp/down.sh
```

That destroys Helm releases if the API still answers, then `tofu destroy` (VM, address, VPC). GCP cost stops when destroy finishes.

## If SSH or Lens is refused

`up.ps1` opens ports 22 and 6443 to the public IP seen at apply time. A laptop on another network needs a new CIDR:

```hcl
# terraform.tfvars
allowed_cidr = "YOUR.NEW.IP/32"
```

Then `tofu apply` again (no need to rebuild the instance).
