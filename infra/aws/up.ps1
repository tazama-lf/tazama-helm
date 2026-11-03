# SPDX-License-Identifier: Apache-2.0
# Stand up the k3s EC2, copy kubeconfig, print SSH and Helmfile next steps.
#
#   .\infra\aws\up.cmd -Sizing small
#   .\infra\aws\up.cmd -Sizing medium -AwsProfile tazama
#   .\infra\aws\up.cmd -Sizing large

param(
  [ValidateSet("small", "medium", "large")]
  [string]$Sizing = "medium",
  [string]$AwsProfile = ""
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
Test-Bin aws

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Host "kubectl is not on PATH yet. Install it before running tazama.cmd, or use Lens with the kubeconfig this script writes."
}

if (-not $AwsProfile -and $env:AWS_PROFILE) {
  $AwsProfile = $env:AWS_PROFILE
}
if ($AwsProfile) {
  $env:AWS_PROFILE = $AwsProfile
  Set-Content -LiteralPath (Join-Path $Here "profile.auto.tfvars") -Value "aws_profile = `"$AwsProfile`"" -Encoding ascii
} elseif (Test-Path (Join-Path $Here "profile.auto.tfvars")) {
  Write-Host "Using aws_profile already saved in profile.auto.tfvars"
  $saved = Get-Content -LiteralPath (Join-Path $Here "profile.auto.tfvars") -Raw
  if ($saved -match 'aws_profile\s*=\s*"([^"]+)"') {
    $AwsProfile = $Matches[1]
    $env:AWS_PROFILE = $AwsProfile
  }
}

Write-Host "Checking AWS credentials..."
$awsIdArgs = @("sts", "get-caller-identity", "--output", "json")
if ($AwsProfile) {
  $awsIdArgs += @("--profile", $AwsProfile)
  Write-Host "  AWS profile: $AwsProfile"
} else {
  Write-Host "  AWS profile: default  (no -AwsProfile; this is often your personal account)"
}
$identity = & aws @awsIdArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  throw @"
AWS CLI is not logged in for this profile.

Keep your personal account as [default]. Add the company account as a named profile:

  aws configure --profile tazama
  aws sts get-caller-identity --profile tazama

Then:

  .\infra\aws\up.cmd -Sizing medium -AwsProfile tazama

Do not run ``aws configure`` without --profile or you will overwrite the personal default.
"@
}
Write-Host $identity

Write-Host "OpenTofu init..."
& $script:Tofu init -input=false
if ($LASTEXITCODE -ne 0) { throw "$script:Tofu init failed." }

$ec2 = @{ small = "t3.medium"; medium = "t3.large"; large = "t3.xlarge" }[$Sizing]
Write-Host "Sizing $Sizing ($ec2)"
Set-Content -LiteralPath (Join-Path $Here "sizing.auto.tfvars") -Value "sizing = `"$Sizing`"" -Encoding ascii
Write-Host "OpenTofu apply (EC2 + k3s). This takes several minutes..."
& $script:Tofu apply -input=false -auto-approve
if ($LASTEXITCODE -ne 0) { throw "$script:Tofu apply failed." }

$ip = & $script:Tofu output -raw public_ip
$key = Join-Path $Here "id_rsa"
$kube = Join-Path $Here "kubeconfig.yaml"

if (-not (Test-Path $key)) {
  throw "SSH key was not written to $key."
}

# Windows OpenSSH refuses keys that other users can read.
icacls $key /inheritance:r | Out-Null
icacls $key /grant:r "$($env:USERNAME):R" | Out-Null

Write-Host "Copying kubeconfig from ec2-user@$ip ..."
$sshArgs = @(
  "-i", $key,
  "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=NUL",
  "-o", "ConnectTimeout=10",
  "ec2-user@$ip",
  "cat kubeconfig.yaml"
)
$yaml = & ssh @sshArgs
if ($LASTEXITCODE -ne 0 -or -not $yaml) {
  throw "Could not read kubeconfig over SSH. Try: ssh -i $key ec2-user@$ip"
}
Set-Content -LiteralPath $kube -Value ($yaml -join "`n") -Encoding ascii

$env:KUBECONFIG = $kube
Write-Host ""
Write-Host "Cluster is up."
$instanceType = & $script:Tofu output -raw instance_type
Write-Host "  Sizing     : $Sizing ($instanceType)"
Write-Host "  SSH        : ssh -i $key -o StrictHostKeyChecking=no ec2-user@$ip"
Write-Host "  Kubeconfig : $kube"
Write-Host "  Operator IP: $(& $script:Tofu output -raw operator_cidr)"
Write-Host ""
Write-Host "Lens: File > Add Cluster > pick $kube"
Write-Host "This shell:"
Write-Host "  `$env:KUBECONFIG = '$kube'"
Write-Host "  kubectl get nodes"
Write-Host ""
Write-Host "Install Tazama from the repo root (same sizing as this EC2):"
Write-Host "  cd $Root"
Write-Host "  `$env:KUBECONFIG = '$kube'"
Write-Host "  .\tazama.cmd sync -Profile core -Cloud onprem -Sizing $Sizing"
Write-Host "  .\tazama.cmd apply -Profile core -Cloud onprem -Sizing $Sizing -Cms"
Write-Host ""
Write-Host "Tear down AWS later:"
Write-Host "  .\infra\aws\down.cmd"
