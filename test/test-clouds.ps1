# SPDX-License-Identifier: Apache-2.0
#
# Test every cloud overlay against one local cluster.
#
# The overlays in environments/cloud/ differ in four ways: the storageClass
# name, the ingress-nginx Service type and its annotations, the Valkey replica
# switch, and the Postgres volume size. This exercises those differences
# locally so a broken overlay does not reach a real cluster.
#
#   render  (default) Template every overlay. Catches Go-template and chart
#           value errors in seconds and needs no cluster.
#   install Sync each overlay on the current cluster and wait for pods.
#
# Install mode destroys and deletes PVCs between clouds. StatefulSet
# volumeClaimTemplates are immutable, so Postgres cannot move from one
# storageClass or volume size to another in place.
#
# Alias StorageClasses named gp3, standard-rwo and managed-csi are created
# against the cluster's own default provisioner. Cloud load balancer
# annotations render but do nothing locally, so the ingress controller Service
# is forced to NodePort unless -RealLoadBalancer is passed.

param(
  [string[]]$Clouds = @("onprem", "eks", "gke", "aks"),

  [ValidateSet("core", "full", "private-rules", "member", "dockerhub")]
  [string]$Profile = "core",

  [ValidateSet("standard", "small", "medium", "large")]
  [string]$Sizing = "standard",

  [ValidateSet("render", "install")]
  [string]$Mode = "render",

  [switch]$IncludeRules,
  [switch]$RealLoadBalancer,
  [switch]$KeepReleases,
  [int]$ReadyTimeoutSeconds = 600
)

# Must stay Continue. Under Stop, redirecting a native command's stderr with
# 2>&1 turns ordinary progress output such as "Adding repo ..." into a
# terminating error. Every failure below is raised explicitly with throw.
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$AllowedClouds = @("onprem", "eks", "gke", "aks")
foreach ($c in $Clouds) {
  if ($AllowedClouds -notcontains $c) {
    throw "Unknown cloud '$c'. Allowed: $($AllowedClouds -join ', ')."
  }
}

foreach ($tool in @("helmfile", "helm")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool is not on PATH."
  }
}
if ($Mode -eq "install" -and -not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  throw "kubectl is not on PATH and is required for -Mode install."
}

$Launcher = Join-Path $Root "tazama.cmd"
if (-not (Test-Path $Launcher)) {
  throw "tazama.cmd not found in $Root."
}

# Cloud storageClass names, kept in sync with environments/cloud/*.yaml.
# onprem uses "" (the cluster default) so it needs no alias.
$AliasClassNames = @("gp3", "standard-rwo", "managed-csi")

# aks enables every release onprem does plus ingress-nginx, so destroying with
# it removes the superset no matter which overlay was installed last.
$TeardownCloud = "aks"

function Get-DefaultProvisioner {
  $raw = kubectl get storageclass -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) {
    return $null
  }
  $items = ($raw | ConvertFrom-Json).items
  if (-not $items) {
    return $null
  }
  $default = $items | Where-Object {
    $_.metadata.annotations."storageclass.kubernetes.io/is-default-class" -eq "true"
  } | Select-Object -First 1
  if (-not $default) {
    $default = $items | Select-Object -First 1
  }
  return $default.provisioner
}

function New-AliasStorageClasses {
  param([Parameter(Mandatory)][string]$Provisioner)

  foreach ($name in $AliasClassNames) {
    kubectl get storageclass $name *> $null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  $name already exists, left alone"
      continue
    }
    $manifest = @"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $name
  labels:
    tazama.io/cloud-test-alias: "true"
provisioner: $Provisioner
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
"@
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      Set-Content -LiteralPath $tmp -Value $manifest -Encoding ascii
      kubectl apply -f $tmp | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to create StorageClass $name."
      }
      Write-Host "  $name -> $Provisioner"
    } finally {
      Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
  }
}

function Clear-TazamaState {
  # Releases and PVCs both have to go. A surviving PVC keeps the previous
  # storageClass and size, which the next overlay cannot change in place.
  & $Launcher destroy -Profile $Profile -Cloud $TeardownCloud -Sizing $Sizing *> $null
  kubectl delete pvc --all -n tazama --wait=false *> $null
  kubectl wait --for=delete pvc --all -n tazama --timeout=120s *> $null
}

function Get-UnhealthyPods {
  $raw = kubectl get pods -n tazama -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) {
    return @()
  }
  $items = ($raw | ConvertFrom-Json).items
  $bad = @()
  foreach ($pod in @($items)) {
    if ($pod.status.phase -eq "Succeeded") {
      continue
    }
    $reason = $pod.status.phase
    $ready = $true
    foreach ($cs in @($pod.status.containerStatuses)) {
      if (-not $cs.ready) {
        $ready = $false
        if ($cs.state.waiting.reason) {
          $reason = $cs.state.waiting.reason
        }
      }
    }
    if ($pod.status.phase -ne "Running" -or -not $ready) {
      $bad += [pscustomobject]@{ Name = $pod.metadata.name; Reason = $reason }
    }
  }
  return $bad
}

function Get-FirstError {
  param($Output)
  $hit = $Output | Select-String -Pattern "Error:|error:|failed|FAILED" | Select-Object -First 1
  if (-not $hit) {
    return ""
  }
  $line = ($hit.Line -replace '\s+', ' ').Trim()
  if ($line.Length -gt 120) {
    $line = $line.Substring(0, 120) + "..."
  }
  return $line
}

Write-Host ""
Write-Host "Cloud overlay test"
Write-Host "  mode    : $Mode"
Write-Host "  profile : $Profile"
Write-Host "  sizing  : $Sizing"
Write-Host "  clouds  : $($Clouds -join ', ')"

if ($Mode -eq "install") {
  kubectl cluster-info *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "No reachable cluster. Point kubectl at one, or use -Mode render."
  }

  $provisioner = Get-DefaultProvisioner
  if (-not $provisioner) {
    throw "Could not read a StorageClass provisioner from this cluster."
  }
  Write-Host ""
  Write-Host "Alias StorageClasses (cloud names on the local provisioner):"
  New-AliasStorageClasses -Provisioner $provisioner

  if (-not $IncludeRules) {
    Write-Host ""
    Write-Host "Rules tier excluded for capacity. Pass -IncludeRules to install every rule pod."
  }
}

$Results = New-Object System.Collections.Generic.List[object]

foreach ($cloud in $Clouds) {
  Write-Host ""
  Write-Host ("-" * 62)
  Write-Host "$cloud ($Mode)"
  Write-Host ("-" * 62)

  $cmdArgs = @()
  if ($Mode -eq "render") {
    $cmdArgs += "template"
  } else {
    $cmdArgs += "sync"
  }
  $cmdArgs += @("-Profile", $Profile, "-Cloud", $cloud, "-Sizing", $Sizing)

  if ($Mode -eq "install") {
    Write-Host "Clearing previous releases and PVCs..."
    Clear-TazamaState

    if (-not $IncludeRules) {
      $cmdArgs += @("-Selector", "tier!=rules")
    }
    if (-not $RealLoadBalancer -and $cloud -ne "onprem") {
      # A local cluster assigns no external IP, so helm --wait would sit on a
      # pending LoadBalancer until it times out.
      $cmdArgs += @("-IngressServiceType", "NodePort")
    }
  }

  $started = Get-Date
  $output = & $Launcher @cmdArgs 2>&1
  $code = $LASTEXITCODE
  $elapsed = [int]((Get-Date) - $started).TotalSeconds

  $status = "PASS"
  $detail = ""

  if ($code -ne 0) {
    $status = "FAIL"
    $detail = Get-FirstError $output
    Write-Host "FAIL after ${elapsed}s"
    if ($detail) {
      Write-Host "  $detail"
    } else {
      $output | Select-Object -Last 15 | ForEach-Object { Write-Host "  $_" }
    }
  } elseif ($Mode -eq "install") {
    Write-Host "Synced in ${elapsed}s, waiting for pods..."
    kubectl wait --for=condition=Ready pods --all -n tazama --timeout="${ReadyTimeoutSeconds}s" *> $null
    $bad = Get-UnhealthyPods
    if ($bad.Count -gt 0) {
      $status = "FAIL"
      $detail = ($bad | Select-Object -First 3 | ForEach-Object { "$($_.Name)=$($_.Reason)" }) -join ", "
      Write-Host "$($bad.Count) pod(s) never became ready:"
      $bad | ForEach-Object { Write-Host "  $($_.Name)  $($_.Reason)" }
    } else {
      Write-Host "PASS, all pods Ready"
    }
  } else {
    Write-Host "PASS in ${elapsed}s"
  }

  $Results.Add([pscustomobject]@{
      Cloud   = $cloud
      Status  = $status
      Seconds = $elapsed
      Detail  = $detail
    })
}

if ($Mode -eq "install" -and -not $KeepReleases) {
  Write-Host ""
  Write-Host "Tearing down. Pass -KeepReleases to leave the last install running."
  Clear-TazamaState
}

Write-Host ""
Write-Host "Summary"
$Results | Format-Table -AutoSize Cloud, Status, Seconds, Detail

$failed = @($Results | Where-Object { $_.Status -ne "PASS" })
if ($failed.Count -gt 0) {
  Write-Host "$($failed.Count) of $($Results.Count) overlays failed."
  exit 1
}
Write-Host "All $($Results.Count) overlays passed."
exit 0
