# AWS k3s test cluster

One EC2 instance running **k3s** (not EKS). OpenTofu creates it; Helmfile from this repo installs Tazama; Lens uses the kubeconfig; SSH is for the box.

This is a disposable test cluster. Tear it down when you are done.

## Sizing

`-Sizing` picks both the **EC2 type** and the Helm replica file in `values/sizing/`.

| `-Sizing` | EC2 | vCPU / RAM |
| --- | --- | --- |
| `small` | `t3.medium` | 2 / 4 GB |
| `medium` | `t3.large` | 2 / 8 GB |
| `large` | `t3.xlarge` | 4 / 16 GB |

Default is `medium`. `large` is the most comfortable size for a `core` install.

## What you get

- VPC, public subnet, Elastic IP
- Amazon Linux 2023, k3s (Traefik off so Helmfile can install ingress-nginx)
- SSH as `ec2-user` with a generated key (`id_rsa`, gitignored)
- Kubernetes API on `https://<elastic-ip>:6443`
- `kubeconfig.yaml` for Lens and `kubectl`
- SSH and :6443 limited to your current public IP (`/32`)

## How login works

There are three separate logins. None of them is a username/password prompt inside `up.ps1`.

### 1. AWS account (this is how OpenTofu bills your account)

OpenTofu uses the **AWS CLI credentials already stored on your laptop**. It does not log you in by itself.

If you already ran `aws configure` (or `aws configure --profile tazama`) for the Compose AWS work, you are done. Confirm with:

```powershell
aws sts get-caller-identity
```

or, if you used a named profile:

```powershell
aws sts get-caller-identity --profile tazama
```

You should see your AWS account ID and IAM user ARN. If that fails, create an IAM user with programmatic access in the [AWS console](https://console.aws.amazon.com/), create an access key, then add a **named** profile (see below). Those values are stored in `%USERPROFILE%\.aws\credentials` and never go in this repo.

The IAM user needs permission to create EC2, VPC, Elastic IPs, security groups, and key pairs. `AmazonEC2FullAccess` plus `AmazonVPCFullAccess` is enough for this stack. You do not need EKS, Route 53, or ALB permissions.

### Personal and company accounts on the same laptop

Yes. AWS CLI supports many profiles in one credentials file. Keep personal as `[default]`. Add the company account as a second named profile. Do **not** run `aws configure` without `--profile` or you will overwrite the personal default.

```powershell
aws configure --profile tazama
```

Paste the company Access Key ID, Secret Access Key, region, and `json`. Then confirm you are looking at the company account ID, not the personal one:

```powershell
aws sts get-caller-identity --profile tazama
aws sts get-caller-identity
```

Point this stack at the company profile. `up.cmd` saves it so `down.cmd` uses the same account:

```powershell
.\infra\aws\up.cmd -Sizing medium -AwsProfile tazama
```

You can also put `aws_profile = "tazama"` in `infra/aws/terraform.tfvars` (gitignored). Your personal `[default]` profile stays as it is for everything else.

### 2. SSH into the EC2 (this is not your AWS password)

OpenTofu generates an SSH key pair on apply and registers the public half as an AWS key pair. The private half is written to `infra/aws/id_rsa` (gitignored). That is how you log into the instance:

```powershell
ssh -i .\infra\aws\id_rsa -o StrictHostKeyChecking=no ec2-user@<elastic-ip>
```

You do not type an AWS password here. If `id_rsa` is missing, run `up.ps1` again or the key was deleted.

### 3. Kubernetes / Lens (this is not AWS login either)

After k3s is up, `up.ps1` copies `/home/ec2-user/kubeconfig.yaml` off the instance over SSH. That file contains the k3s client certificate. Point Lens or `kubectl` at it. It has nothing to do with your AWS access keys.

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) 1.6+ (`tofu version`), or Terraform
- AWS CLI with credentials (`aws sts get-caller-identity`)
- OpenSSH client (`ssh`)
- This repo’s usual tools for the Helmfile step: `kubectl`, Helm, Helmfile

## Bring it up

From `tazama-Helms`:

```powershell
.\infra\aws\up.cmd -Sizing small -AwsProfile tazama
.\infra\aws\up.cmd -Sizing medium -AwsProfile tazama
.\infra\aws\up.cmd -Sizing large -AwsProfile tazama
```

```bash
./infra/aws/up.sh --sizing small --aws-profile tazama
./infra/aws/up.sh --sizing medium --aws-profile tazama
./infra/aws/up.sh --sizing large --aws-profile tazama
```

That runs `tofu apply -var sizing=...`, waits until k3s is Ready, and copies kubeconfig next to the stack. Changing `-Sizing` on an existing stack updates the instance type.

Optional: copy `terraform.tfvars.example` to `terraform.tfvars` to pin region, AWS profile, or `allowed_cidr`.

## Point Lens and Helmfile at it

```powershell
$env:KUBECONFIG = "$PWD\infra\aws\kubeconfig.yaml"
kubectl get nodes
```

In Lens: **File > Add Cluster** and choose `infra/aws/kubeconfig.yaml`.

SSH (logs, disk, `k3s kubectl` on the box):

```powershell
ssh -i .\infra\aws\id_rsa -o StrictHostKeyChecking=no ec2-user@<elastic-ip>
```

Install Tazama with the **same** sizing you passed to `up.cmd`:

```powershell
$env:KUBECONFIG = "$PWD\infra\aws\kubeconfig.yaml"
.\tazama.cmd sync -Profile core -Cloud onprem -Sizing medium
.\tazama.cmd apply -Profile core -Cloud onprem -Sizing medium -Cms
```

Do **not** use `-Cloud eks`. That overlay expects a `gp3` StorageClass and an AWS load balancer. This node is k3s.

## Tear down

```powershell
.\infra\aws\down.cmd
```

```bash
./infra/aws/down.sh
```

That destroys Helm releases if the API still answers, then `tofu destroy` (instance, EIP, VPC). AWS cost stops when destroy finishes.

## If SSH or Lens is refused

`up.ps1` opens ports 22 and 6443 to the public IP seen at apply time. A laptop on another network needs a new CIDR:

```hcl
# terraform.tfvars
allowed_cidr = "YOUR.NEW.IP/32"
```

Then `tofu apply` again (no need to rebuild the instance).
