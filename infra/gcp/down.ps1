# SPDX-License-Identifier: Apache-2.0
# Remove Tazama releases if the API is up, then destroy the GCE VM/VPC.

$ErrorActionPreference = "Continue"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $Here)
Set-Location $Here

$kube = Join-Path $Here "kubeconfig.yaml"
$launcher = Join-Path $Root "tazama.cmd"

if ((Test-Path $kube) -and (Test-Path $launcher) -and (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  $env:KUBECONFIG = $kube
  kubectl get nodes 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Destroying Tazama Helm releases..."
    $sizing = "medium"
    if (Get-Command tofu -ErrorAction SilentlyContinue) {
      $sizingOut = tofu output -raw sizing 2>$null
      if ($LASTEXITCODE -eq 0 -and $sizingOut) { $sizing = $sizingOut.Trim() }
    } elseif (Get-Command terraform -ErrorAction SilentlyContinue) {
      $sizingOut = terraform output -raw sizing 2>$null
      if ($LASTEXITCODE -eq 0 -and $sizingOut) { $sizing = $sizingOut.Trim() }
    }
    Push-Location $Root
    & $launcher destroy -Profile core -Cloud onprem -Sizing $sizing 2>$null
    kubectl delete pvc --all -n tazama --wait=false 2>$null | Out-Null
    Pop-Location
  }
}

$tofu = "tofu"
if (-not (Get-Command tofu -ErrorAction SilentlyContinue)) {
  if (Get-Command terraform -ErrorAction SilentlyContinue) {
    $tofu = "terraform"
  } else {
    throw "OpenTofu (tofu) is not on PATH."
  }
}

Write-Host "OpenTofu destroy..."
& $tofu destroy -input=false -auto-approve
if ($LASTEXITCODE -ne 0) { throw "$tofu destroy failed." }

Remove-Item -LiteralPath $kube -ErrorAction SilentlyContinue
Write-Host "GCP k3s cluster is gone."
