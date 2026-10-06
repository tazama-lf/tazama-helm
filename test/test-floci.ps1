# SPDX-License-Identifier: Apache-2.0
#
# Install each cloud overlay on a Floci-backed k3s cluster.
#
# Floci (https://floci.io) emulates AWS, GCP, and Azure on localhost. EKS,
# GKE, and AKS each start a real rancher/k3s container. That is not the
# managed control plane, CSI driver, or cloud load balancer. What this
# proves is that the overlay YAML, StorageClass names, and Helmfile sync
# work against a Kubernetes API that was created through the cloud's own
# cluster API.
#
# Clouds run one after another so their k3s API port ranges do not overlap.
# Between clouds this script destroys Tazama releases and PVCs, then stops
# the emulator. Alias StorageClasses (gp3, standard-rwo, managed-csi) are
# created against k3s local-path so PVCs can bind.
#
# Needs Docker Desktop (socket mounted into the emulator), kubectl, Helm,
# Helmfile, and for EKS the AWS CLI. GKE and AKS talk HTTP to Floci so
# gcloud / az are optional.
#
#   .\test\test-floci.ps1
#   .\test\test-floci.ps1 -Clouds eks,gke
#   .\test\test-floci.ps1 -KeepReleases -KeepEmulators

param(
  [string[]]$Clouds = @("eks", "gke", "aks"),

  [ValidateSet("core", "full", "private-rules", "member", "dockerhub")]
  [string]$Profile = "core",

  [ValidateSet("standard", "small", "medium", "large")]
  [string]$Sizing = "standard",

  [switch]$IncludeRules,
  [switch]$RealLoadBalancer,
  [switch]$KeepReleases,
  [switch]$KeepEmulators,
  [int]$ClusterTimeoutSeconds = 180,
  [int]$ReadyTimeoutSeconds = 600
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$Allowed = @("eks", "gke", "aks")
foreach ($c in $Clouds) {
  if ($Allowed -notcontains $c) {
    throw "Unknown cloud '$c'. Floci covers eks, gke, aks (not onprem)."
  }
}

foreach ($tool in @("docker", "kubectl", "helm", "helmfile")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool is not on PATH."
  }
}
$Launcher = Join-Path $Root "tazama.cmd"
if (-not (Test-Path $Launcher)) {
  throw "tazama.cmd not found in $Root."
}

$AliasClassNames = @("gp3", "standard-rwo", "managed-csi")
$TeardownCloud = "aks"
$KubeDir = Join-Path $env:USERPROFILE ".kube"
New-Item -ItemType Directory -Force -Path $KubeDir | Out-Null

function Invoke-Json {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    [string]$Body
  )
  $params = @{
    Method      = $Method
    Uri         = $Uri
    TimeoutSec  = 60
  }
  if ($Body) {
    $params.ContentType = "application/json"
    $params.Body = $Body
  }
  try {
    return Invoke-RestMethod @params
  } catch {
    throw "HTTP $Method $Uri failed: $($_.Exception.Message)"
  }
}

function Wait-Port {
  param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][int]$Port, [int]$Seconds = 90)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $client = New-Object System.Net.Sockets.TcpClient
      $iar = $client.BeginConnect($HostName, $Port, $null, $null)
      $ok = $iar.AsyncWaitHandle.WaitOne(2000, $false)
      if ($ok -and $client.Connected) {
        $client.Close()
        return
      }
      $client.Close()
    } catch {
      # still starting
    }
    Start-Sleep -Seconds 2
  }
  throw "Timed out waiting for ${HostName}:${Port}"
}

function Wait-HttpOk {
  param([Parameter(Mandatory)][string]$Uri, [int]$Seconds = 90)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try {
      Invoke-WebRequest -Uri $Uri -TimeoutSec 5 -UseBasicParsing | Out-Null
      return
    } catch {
      if ($_.Exception.Response) {
        return
      }
      Start-Sleep -Seconds 2
    }
  }
  throw "Timed out waiting for HTTP on $Uri"
}

function Wait-KubectlNodes {
  $deadline = (Get-Date).AddSeconds(90)
  $last = ""
  while ((Get-Date) -lt $deadline) {
    $output = kubectl get nodes --no-headers 2>&1 | Out-String
    $ready = @()
    foreach ($line in @($output -split "`n")) {
      $cols = ($line.Trim() -split '\s+')
      if ($cols.Count -ge 2 -and $cols[1] -eq "Ready") {
        $ready += $cols[0]
      }
    }
    if ($LASTEXITCODE -eq 0 -and $ready.Count -gt 0) {
      kubectl get nodes | Out-Host
      return
    }
    $last = ($output -replace '\s+', ' ').Trim()
    Start-Sleep -Seconds 5
  }
  throw "kubectl cannot reach the Floci k3s API or no node is Ready. $last"
}

function Install-LocalPathStorage {
  Write-Host "  installing rancher local-path provisioner (k3s has no StorageClass yet)"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply local-path-storage.yaml."
  }
}

function Start-FlociAws {
  docker rm -f tazama-floci-aws 2>$null | Out-Null
  docker run -d --name tazama-floci-aws `
    -p 4566:4566 `
    -v /var/run/docker.sock:/var/run/docker.sock `
    floci/floci:latest | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to start floci/floci. Is Docker running?"
  }
  Wait-Port "127.0.0.1" 4566 90
  Wait-HttpOk "http://localhost:4566/" 60
}

function Start-FlociGcp {
  docker rm -f tazama-floci-gcp 2>$null | Out-Null
  docker run -d --name tazama-floci-gcp `
    -p 4588:4588 `
    -v /var/run/docker.sock:/var/run/docker.sock `
    floci/floci-gcp:latest | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to start floci/floci-gcp."
  }
  Wait-Port "127.0.0.1" 4588 90
  Wait-HttpOk "http://localhost:4588/" 60
}

function Start-FlociAz {
  docker rm -f tazama-floci-az 2>$null | Out-Null
  docker run -d --name tazama-floci-az `
    -p 4577:4577 `
    -v /var/run/docker.sock:/var/run/docker.sock `
    floci/floci-az:latest | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to start floci/floci-az."
  }
  Wait-Port "127.0.0.1" 4577 90
  Wait-HttpOk "http://localhost:4577/" 60
}

function Remove-LeftoverFloci {
  Write-Host "Removing leftover Floci / k3s containers..."
  foreach ($n in @("tazama-floci-aws", "tazama-floci-gcp", "tazama-floci-az", "floci-ecr-registry")) {
    docker rm -f $n 2>$null | Out-Null
  }
  foreach ($filter in @("floci-eks", "floci-gcp-gke", "floci-az-aks")) {
    foreach ($id in @(docker ps -aq --filter "name=$filter")) {
      if ($id) {
        docker rm -f $id 2>$null | Out-Null
      }
    }
  }
  foreach ($vol in @(docker volume ls -q)) {
    if ($vol -match '^floci-(eks|gcp|az|ecr)') {
      docker volume rm $vol 2>$null | Out-Null
    }
  }
}

function Stop-Floci {
  param(
    [string]$Name,
    [string[]]$SidecarFilters = @()
  )
  if ($KeepEmulators) {
    return
  }
  docker rm -f $Name 2>$null | Out-Null
  foreach ($filter in $SidecarFilters) {
    foreach ($id in @(docker ps -aq --filter "name=$filter")) {
      if ($id) {
        docker rm -f $id 2>$null | Out-Null
      }
    }
    foreach ($vol in @(docker volume ls -q)) {
      if ($vol -like "$filter*") {
        docker volume rm $vol 2>$null | Out-Null
      }
    }
  }
}

function Export-K3sKubeconfig {
  param(
    [Parameter(Mandatory)][string]$ContainerFilter,
    [Parameter(Mandatory)][string]$KubePath
  )
  $deadline = (Get-Date).AddSeconds($ClusterTimeoutSeconds)
  $id = $null
  $text = ""
  while ((Get-Date) -lt $deadline) {
    $id = @(docker ps -q --filter "name=$ContainerFilter") | Where-Object { $_ } | Select-Object -First 1
    if ($id) {
      $raw = docker exec $id cat /etc/rancher/k3s/k3s.yaml 2>$null
      if ($LASTEXITCODE -eq 0 -and $raw) {
        if ($raw -is [array]) {
          $text = $raw -join "`n"
        } else {
          $text = [string]$raw
        }
        if ($text -match "server:") {
          break
        }
      }
    }
    Start-Sleep -Seconds 3
  }
  if (-not $id -or -not $text) {
    throw "No k3s kubeconfig yet from container matching $ContainerFilter."
  }
  $portLines = docker port $id 6443 2>$null
  $hostPort = $null
  foreach ($line in @($portLines)) {
    if ($line -match '127\.0\.0\.1:(\d+)') {
      $hostPort = $Matches[1]
      break
    }
  }
  if (-not $hostPort) {
    foreach ($line in @($portLines)) {
      if ($line -match '0\.0\.0\.0:(\d+)') {
        $hostPort = $Matches[1]
        break
      }
    }
  }
  if (-not $hostPort) {
    throw "Could not parse host port for k3s API from: $portLines"
  }
  $text = $text -replace 'https://127\.0\.0\.1:6443', "https://127.0.0.1:$hostPort"
  $text = $text -replace 'https://localhost:6443', "https://127.0.0.1:$hostPort"
  $text = $text -replace 'https://0\.0\.0\.0:6443', "https://127.0.0.1:$hostPort"
  [System.IO.File]::WriteAllText($KubePath, $text)
  $env:KUBECONFIG = $KubePath
  $view = kubectl config view --kubeconfig $KubePath --raw -o json 2>$null | ConvertFrom-Json
  if ($view -and $view.clusters) {
    $cn = $view.clusters[0].name
    kubectl config --kubeconfig $KubePath set-cluster $cn --insecure-skip-tls-verify=true *> $null
  }
  Write-Host "  kubeconfig from k3s container $id on localhost:$hostPort"
  Wait-KubectlNodes
  $stale = kubectl get nodes --no-headers 2>$null
  foreach ($line in @($stale)) {
    $cols = ($line -split '\s+')
    if ($cols.Count -ge 2 -and $cols[1] -ne "Ready") {
      Write-Host "  deleting stale node $($cols[0]) ($($cols[1]))"
      kubectl delete node $cols[0] --wait=false *> $null
    }
  }
}

function New-AliasStorageClasses {
  $items = $null
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    $raw = kubectl get storageclass -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $raw) {
      $parsed = $raw | ConvertFrom-Json
      if ($parsed.items -and @($parsed.items).Count -gt 0) {
        $items = $parsed.items
        break
      }
    }
    Start-Sleep -Seconds 3
  }
  if (-not $items) {
    Install-LocalPathStorage
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
      $raw = kubectl get storageclass -o json 2>$null
      if ($LASTEXITCODE -eq 0 -and $raw) {
        $parsed = $raw | ConvertFrom-Json
        if ($parsed.items -and @($parsed.items).Count -gt 0) {
          $items = $parsed.items
          break
        }
      }
      Start-Sleep -Seconds 3
    }
  }
  if (-not $items) {
    throw "k3s has no StorageClass after installing local-path."
  }
  $default = $items | Where-Object {
    $_.metadata.annotations."storageclass.kubernetes.io/is-default-class" -eq "true"
  } | Select-Object -First 1
  if (-not $default) {
    $default = $items | Select-Object -First 1
  }
  if (-not $default) {
    throw "k3s has no StorageClass. Real-mode Floci clusters should ship local-path."
  }
  $provisioner = $default.provisioner
  Write-Host "  aliasing cloud StorageClass names onto $provisioner"
  foreach ($name in $AliasClassNames) {
    kubectl get storageclass $name *> $null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  $name already exists"
      continue
    }
    $manifest = @"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $name
  labels:
    tazama.io/cloud-test-alias: "true"
provisioner: $provisioner
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
"@
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      Set-Content -LiteralPath $tmp -Value $manifest -Encoding ascii
      kubectl apply -f $tmp | Out-Null
    } finally {
      Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
  }
}

function Clear-TazamaState {
  param([string]$Cloud)
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

function Wait-EksActive {
  param([string]$Name)
  if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI is required for -Clouds eks. Install it, then retry."
  }
  $env:AWS_ENDPOINT_URL = "http://localhost:4566"
  $env:AWS_ACCESS_KEY_ID = "tazama"
  $env:AWS_SECRET_ACCESS_KEY = "tazama-not-test"
  $env:AWS_DEFAULT_REGION = "us-east-1"
  $env:AWS_EC2_METADATA_DISABLED = "true"
  $deadline = (Get-Date).AddSeconds($ClusterTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $json = aws eks describe-cluster --name $Name --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $json) {
      $status = ($json | ConvertFrom-Json).cluster.status
      Write-Host "  EKS status: $status"
      if ($status -eq "ACTIVE") {
        return
      }
    }
    Start-Sleep -Seconds 5
  }
  throw "EKS cluster $Name did not become ACTIVE."
}

function Connect-Eks {
  $name = "tazama-eks"
  $kube = Join-Path $KubeDir "tazama-floci-eks.yaml"
  if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI is required for EKS. Install aws.exe and retry."
  }
  $env:AWS_ENDPOINT_URL = "http://localhost:4566"
  $env:AWS_DEFAULT_REGION = "us-east-1"
  $env:AWS_EC2_METADATA_DISABLED = "true"

  # test/test and floci/floci are rejected by Floci's EKS token webhook.
  aws iam create-user --user-name tazama-eks *> $null
  $keyJson = aws iam create-access-key --user-name tazama-eks --output json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $keyJson) {
    throw "Could not create an IAM access key in Floci. The EKS webhook will not accept dummy test/test keys."
  }
  $key = ($keyJson | ConvertFrom-Json).AccessKey
  $env:AWS_ACCESS_KEY_ID = $key.AccessKeyId
  $env:AWS_SECRET_ACCESS_KEY = $key.SecretAccessKey

  aws eks create-cluster `
    --name $name `
    --role-arn arn:aws:iam::000000000000:role/eks-role `
    --resources-vpc-config "subnetIds=[],securityGroupIds=[]" *> $null
  Wait-EksActive -Name $name
  Write-Host "  reading kubeconfig from the Floci EKS k3s container..."
  Export-K3sKubeconfig -ContainerFilter "floci-eks-$name" -KubePath $kube
}

function Connect-Gke {
  $name = "tazama-gke"
  $kube = Join-Path $KubeDir "tazama-floci-gke.yaml"
  $create = Invoke-Json -Method POST `
    -Uri "http://localhost:4588/container/v1/projects/floci-local/locations/us-central1/clusters" `
    -Body (@{ cluster = @{ name = $name } } | ConvertTo-Json -Compress)

  $deadline = (Get-Date).AddSeconds($ClusterTimeoutSeconds)
  $cluster = $null
  while ((Get-Date) -lt $deadline) {
    try {
      $cluster = Invoke-Json -Method GET `
        -Uri "http://localhost:4588/container/v1/projects/floci-local/locations/us-central1/clusters/$name"
    } catch {
      Start-Sleep -Seconds 5
      continue
    }
    $status = $cluster.status
    if (-not $status) {
      $status = $cluster.cluster.status
      if ($cluster.cluster) {
        $cluster = $cluster.cluster
      }
    }
    Write-Host "  GKE status: $status"
    if ($status -eq "RUNNING") {
      break
    }
    Start-Sleep -Seconds 5
    $cluster = $null
  }
  if (-not $cluster) {
    throw "GKE cluster $name did not become RUNNING."
  }

  Write-Host "  reading kubeconfig from the Floci GKE k3s container..."
  Export-K3sKubeconfig -ContainerFilter "floci-gcp-gke" -KubePath $kube
}

function Connect-Aks {
  $name = "tazama-aks"
  $sub = "tazama-sub"
  $rg = "tazama-rg"
  $kube = Join-Path $KubeDir "tazama-floci-aks.yaml"
  $api = "http://localhost:4577/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ContainerService/managedClusters/$name" + "?api-version=2024-04-01"
  $body = @{
    location   = "eastus"
    properties = @{
      kubernetesVersion = "1.29"
      dnsPrefix         = "tazama-aks"
      agentPoolProfiles = @(
        @{
          name   = "nodepool1"
          count  = 1
          vmSize = "Standard_DS2_v2"
          osType = "Linux"
          mode   = "System"
        }
      )
    }
  } | ConvertTo-Json -Depth 6

  $created = $false
  foreach ($attempt in 1..12) {
    try {
      Invoke-Json -Method PUT -Uri $api -Body $body | Out-Null
      $created = $true
      break
    } catch {
      Write-Host "  AKS create attempt $attempt failed: $($_.Exception.Message)"
      Start-Sleep -Seconds 5
    }
  }
  if (-not $created) {
    throw "AKS create did not succeed after retries."
  }

  Write-Host "  Floci ARM often stays Creating on Docker Desktop; using the k3s sidecar kubeconfig."
  Export-K3sKubeconfig -ContainerFilter "floci-az-aks" -KubePath $kube
}

function Get-FirstError {
  param($Output)
  $lines = @($Output | ForEach-Object { "$_" })
  $failedIdx = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'Failed Releases') {
      $failedIdx = $i
      break
    }
  }
  if ($failedIdx -ge 0) {
    $chunk = $lines[$failedIdx..([Math]::Min($failedIdx + 12, $lines.Count - 1))]
    $text = ($chunk | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_ }) -join " | "
    if ($text.Length -gt 400) {
      $text = $text.Substring(0, 400) + "..."
    }
    return $text
  }
  $hit = $lines | Where-Object { $_ -match 'Error:|error:' } | Select-Object -First 1
  if ($hit) {
    $line = ($hit -replace '\s+', ' ').Trim()
    if ($line.Length -gt 200) {
      $line = $line.Substring(0, 200) + "..."
    }
    return $line
  }
  return "helmfile sync failed (no error line captured)"
}

Write-Host ""
Write-Host "Floci cloud overlay test"
Write-Host "  profile : $Profile"
Write-Host "  sizing  : $Sizing"
Write-Host "  clouds  : $($Clouds -join ', ')"
Write-Host ""
Write-Host "This starts a k3s cluster per cloud through Floci's EKS / GKE / AKS APIs."
Write-Host "It does not talk to a real AWS, GCP, or Azure account."
if (-not $IncludeRules) {
  Write-Host "Rules tier excluded for capacity. Pass -IncludeRules to install every rule pod."
}

$Results = New-Object System.Collections.Generic.List[object]
Remove-LeftoverFloci

foreach ($cloud in $Clouds) {
  Write-Host ""
  Write-Host ("-" * 62)
  Write-Host "$cloud (floci)"
  Write-Host ("-" * 62)

  $status = "PASS"
  $detail = ""
  $started = Get-Date
  $emulator = $null
  $sidecars = @()

  try {
    switch ($cloud) {
      "eks" {
        $emulator = "tazama-floci-aws"
        $sidecars = @("floci-eks", "floci-ecr")
        Write-Host "Starting Floci AWS on :4566..."
        Start-FlociAws
        Write-Host "Creating EKS (k3s) cluster tazama-eks..."
        Connect-Eks
      }
      "gke" {
        $emulator = "tazama-floci-gcp"
        $sidecars = @("floci-gcp-gke")
        Write-Host "Starting Floci GCP on :4588..."
        Start-FlociGcp
        Write-Host "Creating GKE (k3s) cluster tazama-gke..."
        Connect-Gke
      }
      "aks" {
        $emulator = "tazama-floci-az"
        $sidecars = @("floci-az-aks")
        Write-Host "Starting Floci Azure on :4577..."
        Start-FlociAz
        Write-Host "Creating AKS (k3s) cluster tazama-aks..."
        Connect-Aks
      }
    }

    New-AliasStorageClasses

    Write-Host "Clearing any leftover Tazama releases..."
    Clear-TazamaState -Cloud $cloud

    $cmdArgs = @("sync", "-Profile", $Profile, "-Cloud", $cloud, "-Sizing", $Sizing)
    if (-not $IncludeRules) {
      $cmdArgs += @("-Selector", "tier!=rules")
    }
    if (-not $RealLoadBalancer) {
      $cmdArgs += @("-IngressServiceType", "NodePort")
    }

    Write-Host "Installing Tazama ($cloud overlay)..."
    $output = & $Launcher @cmdArgs 2>&1
    $code = $LASTEXITCODE
    $logPath = Join-Path $env:TEMP "tazama-floci-sync-$cloud.log"
    $output | ForEach-Object { "$_" } | Set-Content -LiteralPath $logPath -Encoding utf8
    if ($code -ne 0) {
      Write-Host "  helmfile log: $logPath"
      throw (Get-FirstError $output)
    }

    Write-Host "Waiting for pods..."
    kubectl wait --for=condition=Ready pods --all -n tazama --timeout="${ReadyTimeoutSeconds}s" *> $null
    $bad = Get-UnhealthyPods
    if ($bad.Count -gt 0) {
      $detail = ($bad | Select-Object -First 3 | ForEach-Object { "$($_.Name)=$($_.Reason)" }) -join ", "
      throw "$($bad.Count) pod(s) never became ready: $detail"
    }
    Write-Host "PASS, all pods Ready"
  } catch {
    $status = "FAIL"
    $detail = $_.Exception.Message
    Write-Host "FAIL: $detail"
  }

  $elapsed = [int]((Get-Date) - $started).TotalSeconds
  $Results.Add([pscustomobject]@{
      Cloud   = $cloud
      Status  = $status
      Seconds = $elapsed
      Detail  = $detail
    })

  if (-not $KeepReleases) {
    Write-Host "Tearing down Tazama..."
    Clear-TazamaState -Cloud $cloud
  }
  if ($emulator) {
    Stop-Floci -Name $emulator -SidecarFilters $sidecars
  }
}

Write-Host ""
Write-Host "Summary"
$Results | Format-Table -AutoSize Cloud, Status, Seconds, Detail

$failed = @($Results | Where-Object { $_.Status -ne "PASS" })
if ($failed.Count -gt 0) {
  Write-Host "$($failed.Count) of $($Results.Count) Floci clouds failed."
  exit 1
}
Write-Host "All $($Results.Count) Floci clouds passed."
exit 0
