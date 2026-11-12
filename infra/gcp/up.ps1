# SPDX-License-Identifier: Apache-2.0
# Stand up the k3s GCE VM, copy kubeconfig, print SSH and Helmfile next steps.
#
#   .\infra\gcp\up.cmd -Sizing small -Project YOUR_PROJECT_ID
#   .\infra\gcp\up.cmd -Sizing medium -Project YOUR_PROJECT_ID
#   .\infra\gcp\up.cmd -Sizing large -Project YOUR_PROJECT_ID

param(
  [ValidateSet("small", "medium", "large")]
  [string]$Sizing = "medium",
  [string]$Project = ""
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
Test-Bin gcloud

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Host "kubectl is not on PATH yet. Install it before running tazama.cmd, or use Lens with the kubeconfig this script writes."
}

if (-not $Project -and $env:GOOGLE_CLOUD_PROJECT) {
  $Project = $env:GOOGLE_CLOUD_PROJECT
}
if (-not $Project -and $env:CLOUDSDK_CORE_PROJECT) {
  $Project = $env:CLOUDSDK_CORE_PROJECT
}
if ($Project) {
  $env:GOOGLE_CLOUD_PROJECT = $Project
  Set-Content -LiteralPath (Join-Path $Here "project.auto.tfvars") -Value "project = `"$Project`"" -Encoding ascii
} elseif (Test-Path (Join-Path $Here "project.auto.tfvars")) {
  Write-Host "Using project already saved in project.auto.tfvars"
  $saved = Get-Content -LiteralPath (Join-Path $Here "project.auto.tfvars") -Raw
  if ($saved -match 'project\s*=\s*"([^"]+)"') {
    $Project = $Matches[1]
    $env:GOOGLE_CLOUD_PROJECT = $Project
  }
}

Write-Host "Checking GCP credentials (application-default)..."
$adc = & gcloud auth application-default print-access-token 2>&1
if ($LASTEXITCODE -ne 0) {
  throw @"
GCP application-default credentials are missing.

  gcloud auth login
  gcloud auth application-default login
  gcloud config set project YOUR_PROJECT_ID
  gcloud services enable compute.googleapis.com --project YOUR_PROJECT_ID

Then:

  .\infra\gcp\up.cmd -Sizing medium -Project YOUR_PROJECT_ID
"@
}

if (-not $Project) {
  $cfgProject = (& gcloud config get-value project 2>$null)
  if ($LASTEXITCODE -eq 0 -and $cfgProject -and $cfgProject -ne "(unset)") {
    $Project = $cfgProject.Trim()
    $env:GOOGLE_CLOUD_PROJECT = $Project
    Set-Content -LiteralPath (Join-Path $Here "project.auto.tfvars") -Value "project = `"$Project`"" -Encoding ascii
    Write-Host "  GCP project: $Project  (from gcloud config)"
  } else {
    throw "Pass -Project YOUR_PROJECT_ID (or set gcloud config set project)."
  }
} else {
  Write-Host "  GCP project: $Project"
}

Write-Host "OpenTofu init..."
& $script:Tofu init -input=false
if ($LASTEXITCODE -ne 0) { throw "$script:Tofu init failed." }

$gce = @{ small = "e2-medium"; medium = "e2-standard-2"; large = "e2-standard-4" }[$Sizing]
Write-Host "Sizing $Sizing ($gce)"
Set-Content -LiteralPath (Join-Path $Here "sizing.auto.tfvars") -Value "sizing = `"$Sizing`"" -Encoding ascii
Write-Host "OpenTofu apply (GCE + k3s). This takes several minutes..."
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
Write-Host "Do not use -Cloud gke. This node is k3s (local-path), not GKE."
Write-Host ""
Write-Host "Tear down GCP later:"
Write-Host "  .\infra\gcp\down.cmd"
