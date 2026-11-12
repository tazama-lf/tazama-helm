# Azure k3s test cluster

One Linux VM running **k3s** (not AKS). OpenTofu creates it; Helmfile from this repo installs Tazama; Lens uses the kubeconfig; SSH is for the box.

This is a disposable test cluster. Tear it down when you are done.

## Sizing

`-Sizing` picks both the **VM size** and the Helm replica file in `values/sizing/`.

| `-Sizing` | Azure | vCPU / RAM |
| --- | --- | --- |
| `small` | `Standard_B2s` | 2 / 4 GB |
| `medium` | `Standard_D2s_v5` | 2 / 8 GB |
| `large` | `Standard_D4s_v5` | 4 / 16 GB |

Default is `medium`. `large` is the most comfortable size for a `core` install.

## What you get

- Resource group, VNet `10.42.0.0/16`, subnet, NSG, static Standard public IP
- Ubuntu 22.04, k3s (Traefik off so Helmfile can install ingress-nginx)
- SSH as `azureuser` with a generated key (`id_rsa`, gitignored)
- Kubernetes API on `https://<public-ip>:6443`
- `kubeconfig.yaml` for Lens and `kubectl`
- SSH and :6443 limited to your current public IP (`/32`)

## How login works

There are three separate logins. None of them is a username/password prompt inside `up.ps1`.

### 1. Azure subscription (this is how OpenTofu bills your subscription)

OpenTofu uses the **Azure CLI session already on your laptop**.

```powershell
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
az account show
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
```

The identity needs permission to create resource groups, VMs, public IPs, VNets, and NSGs. Contributor on the subscription (or a dedicated RG if you pin the group later) is enough. You do not need AKS permissions.

A new subscription may need public IP quota in `westeurope`. If `azurerm_public_ip` fails on quota, pick another location in `terraform.tfvars` or raise the quota.

### 2. SSH into the VM (this is not your Azure password)

OpenTofu generates an SSH key pair on apply and registers the public half as the VM admin SSH key. The private half is written to `infra/azure/id_rsa` (gitignored):

```powershell
ssh -i .\infra\azure\id_rsa -o StrictHostKeyChecking=no azureuser@<public-ip>
```

### 3. Kubernetes / Lens (this is not Azure login either)

After k3s is up, `up.ps1` copies `kubeconfig.yaml` off the instance over SSH. Point Lens or `kubectl` at it.

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) 1.6+ (`tofu version`), or Terraform
- Azure CLI (`az login`)
- OpenSSH client (`ssh`)
- This repo’s usual tools for the Helmfile step: `kubectl`, Helm, Helmfile

## Bring it up

From the repo root:

```powershell
.\infra\azure\up.cmd -Sizing small -Subscription YOUR_SUBSCRIPTION_ID
.\infra\azure\up.cmd -Sizing medium -Subscription YOUR_SUBSCRIPTION_ID
.\infra\azure\up.cmd -Sizing large -Subscription YOUR_SUBSCRIPTION_ID
```

```bash
./infra/azure/up.sh --sizing small --subscription YOUR_SUBSCRIPTION_ID
./infra/azure/up.sh --sizing medium --subscription YOUR_SUBSCRIPTION_ID
./infra/azure/up.sh --sizing large --subscription YOUR_SUBSCRIPTION_ID
```

That runs `tofu apply -var sizing=...`, waits until k3s is Ready, and copies kubeconfig next to the stack.

Optional: copy `terraform.tfvars.example` to `terraform.tfvars` to pin location or `allowed_cidr`.

## Point Lens and Helmfile at it

```powershell
$env:KUBECONFIG = "$PWD\infra\azure\kubeconfig.yaml"
kubectl get nodes
```

```bash
export KUBECONFIG="$PWD/infra/azure/kubeconfig.yaml"
kubectl get nodes
```

In Lens: **File > Add Cluster** and choose `infra/azure/kubeconfig.yaml`.

Install Tazama with the **same** sizing you passed to `up.cmd`:

```powershell
$env:KUBECONFIG = "$PWD\infra\azure\kubeconfig.yaml"
.\tazama.cmd sync -Profile core -Cloud onprem -Sizing medium
```

```bash
export KUBECONFIG="$PWD/infra/azure/kubeconfig.yaml"
./tazama.sh sync core onprem --sizing medium
```

Do **not** use `-Cloud aks`. That overlay expects Azure Disk CSI (`managed-csi`) and a cloud load balancer. This node is k3s.

## Tear down

```powershell
.\infra\azure\down.cmd
```

```bash
./infra/azure/down.sh
```

That destroys Helm releases if the API still answers, then `tofu destroy` (VM, NIC, public IP, VNet, resource group). Azure cost stops when destroy finishes.

## If SSH or Lens is refused

`up.ps1` opens ports 22 and 6443 to the public IP seen at apply time. A laptop on another network needs a new CIDR:

```hcl
# terraform.tfvars
allowed_cidr = "YOUR.NEW.IP/32"
```

Then `tofu apply` again (no need to rebuild the instance).
