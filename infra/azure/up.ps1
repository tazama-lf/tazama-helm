# SPDX-License-Identifier: Apache-2.0
# Stand up the k3s Azure VM, copy kubeconfig, print SSH and Helmfile next steps.
#
#   .\infra\azure\up.cmd -Sizing small -Subscription YOUR_SUBSCRIPTION_ID
#   .\infra\azure\up.cmd -Sizing medium -Subscription YOUR_SUBSCRIPTION_ID
#   .\infra\azure\up.cmd -Sizing large -Subscription YOUR_SUBSCRIPTION_ID

param(
  [ValidateSet("small", "medium", "large")]
  [string]$Sizing = "medium",
  [string]$Subscription = ""
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $Here)
Set-Location $Here

function Test-Bin([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name is not on PATH."
  }
}

$script:Tofu = "tofu"
if (-not (Get-Command tofu -ErrorAction SilentlyContinue)) {
  if (Get-Command terraform -ErrorAction SilentlyContinue) {
    $script:Tofu = "terraform"
    Write-Host "tofu not on PATH; using terraform."
  } else {
    throw "OpenTofu (tofu) is not on PATH. Install from https://opentofu.org/docs/intro/install/"
  }
}
Test-Bin ssh
Test-Bin az

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Host "kubectl is not on PATH yet. Install it before running tazama.cmd, or use Lens with the kubeconfig this script writes."
}

if (-not $Subscription -and $env:ARM_SUBSCRIPTION_ID) {
  $Subscription = $env:ARM_SUBSCRIPTION_ID
}
if ($Subscription) {
  $env:ARM_SUBSCRIPTION_ID = $Subscription
  Set-Content -LiteralPath (Join-Path $Here "subscription.auto.tfvars") -Value "subscription_id = `"$Subscription`"" -Encoding ascii
} elseif (Test-Path (Join-Path $Here "subscription.auto.tfvars")) {
  Write-Host "Using subscription already saved in subscription.auto.tfvars"
  $saved = Get-Content -LiteralPath (Join-Path $Here "subscription.auto.tfvars") -Raw
  if ($saved -match 'subscription_id\s*=\s*"([^"]+)"') {
    $Subscription = $Matches[1]
    $env:ARM_SUBSCRIPTION_ID = $Subscription
  }
}

Write-Host "Checking Azure login..."
$account = & az account show --output json 2>&1
if ($LASTEXITCODE -ne 0) {
  throw @"
Azure CLI is not logged in.

  az login
  az account set --subscription YOUR_SUBSCRIPTION_ID
  az provider register --namespace Microsoft.Compute
  az provider register --namespace Microsoft.Network

Then:

  .\infra\azure\up.cmd -Sizing medium -Subscription YOUR_SUBSCRIPTION_ID
"@
}

if (-not $Subscription) {
  $Subscription = (& az account show --query id --output tsv).Trim()
  if (-not $Subscription) {
    throw "Pass -Subscription YOUR_SUBSCRIPTION_ID (or az account set --subscription)."
  }
  $env:ARM_SUBSCRIPTION_ID = $Subscription
  Set-Content -LiteralPath (Join-Path $Here "subscription.auto.tfvars") -Value "subscription_id = `"$Subscription`"" -Encoding ascii
  Write-Host "  Azure subscription: $Subscription  (from az account show)"
} else {
  & az account set --subscription $Subscription | Out-Null
  Write-Host "  Azure subscription: $Subscription"
}

Write-Host "OpenTofu init..."
& $script:Tofu init -input=false
if ($LASTEXITCODE -ne 0) { throw "$script:Tofu init failed." }

$sku = @{ small = "Standard_B2s"; medium = "Standard_D2s_v5"; large = "Standard_D4s_v5" }[$Sizing]
Write-Host "Sizing $Sizing ($sku)"
Set-Content -LiteralPath (Join-Path $Here "sizing.auto.tfvars") -Value "sizing = `"$Sizing`"" -Encoding ascii
Write-Host "OpenTofu apply (Azure VM + k3s). This takes several minutes..."
& $script:Tofu apply -input=false -auto-approve
if ($LASTEXITCODE -ne 0) { throw "$script:Tofu apply failed." }

$ip = & $script:Tofu output -raw public_ip
$sshUser = & $script:Tofu output -raw ssh_user
$key = Join-Path $Here "id_rsa"
$kube = Join-Path $Here "kubeconfig.yaml"

if (-not (Test-Path $key)) {
  throw "SSH key was not written to $key."
}

icacls $key /inheritance:r | Out-Null
icacls $key /grant:r "$($env:USERNAME):R" | Out-Null

Write-Host "Copying kubeconfig from ${sshUser}@$ip ..."
$sshArgs = @(
  "-i", $key,
  "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=NUL",
  "-o", "ConnectTimeout=10",
  "${sshUser}@$ip",
  "cat kubeconfig.yaml"
)
$yaml = & ssh @sshArgs
if ($LASTEXITCODE -ne 0 -or -not $yaml) {
  throw "Could not read kubeconfig over SSH. Try: ssh -i $key ${sshUser}@$ip"
}
Set-Content -LiteralPath $kube -Value ($yaml -join "`n") -Encoding ascii

$env:KUBECONFIG = $kube
Write-Host ""
Write-Host "Cluster is up."
$instanceType = & $script:Tofu output -raw instance_type
Write-Host "  Sizing     : $Sizing ($instanceType)"
Write-Host "  SSH        : ssh -i $key -o StrictHostKeyChecking=no ${sshUser}@$ip"
Write-Host "  Kubeconfig : $kube"
Write-Host "  Operator IP: $(& $script:Tofu output -raw operator_cidr)"
Write-Host ""
Write-Host "Lens: File > Add Cluster > pick $kube"
Write-Host "This shell:"
Write-Host "  `$env:KUBECONFIG = '$kube'"
Write-Host "  kubectl get nodes"
Write-Host ""
Write-Host "Install Tazama from the repo root (same sizing as this VM):"
Write-Host "  cd $Root"
Write-Host "  `$env:KUBECONFIG = '$kube'"
Write-Host "  .\tazama.cmd sync -Profile core -Cloud onprem -Sizing $Sizing"
Write-Host ""
Write-Host "Do not use -Cloud aks. This node is k3s (local-path), not AKS."
Write-Host ""
Write-Host "Tear down Azure later:"
Write-Host "  .\infra\azure\down.cmd"
