# SPDX-License-Identifier: Apache-2.0
param(
  [Parameter(Position = 0)]
  [ValidateSet("apply", "destroy", "status", "diff", "template", "lint", "sync")]
  [string]$Command = "apply",

  [ValidateSet("core", "dockerhub", "member")]
  [string]$Profile = "core",

  [ValidateSet("onprem", "eks", "gke", "aks")]
  [string]$Cloud = "onprem",

  [string]$Selector = "",
  [switch]$SkipSecretsPrompt,

  [switch]$Cms,
  [switch]$Extensions,
  [switch]$Dems,
  [switch]$Deapi,
  [switch]$Tools,
  [switch]$ConnectionStudio,
  [switch]$RuleStudio,
  [switch]$Biar,
  [switch]$PostgresReplica,

  [string]$RelayEfrup = "",
  [string]$RelayTp = "",
  [string]$RelayEa = "",
  [string]$KafkaBrokers = "",
  [string]$RabbitmqUrl = "",
  [string]$RestUrl = "",

  [string]$PostgresqlHost = "",
  [string]$PostgresqlReplicaHost = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$env:TAZAMA_CLOUD = $Cloud

function Test-RelayTransport {
  param([string]$Name, [string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }
  $allowed = @("nats", "kafka", "rabbitmq", "rest")
  $normalized = $Value.Trim().ToLowerInvariant()
  if ($allowed -notcontains $normalized) {
    Write-Error "$Name must be nats, kafka, rabbitmq, or rest. Got '$Value'."
  }
}

Test-RelayTransport -Name "-RelayEfrup" -Value $RelayEfrup
Test-RelayTransport -Name "-RelayTp" -Value $RelayTp
Test-RelayTransport -Name "-RelayEa" -Value $RelayEa

$helmfile = Get-Command helmfile -ErrorAction SilentlyContinue
if (-not $helmfile) {
  Write-Error "helmfile is not on PATH. Install https://github.com/helmfile/helmfile/releases and retry."
}

$helm = Get-Command helm -ErrorAction SilentlyContinue
if (-not $helm) {
  Write-Error "helm is not on PATH. Install https://helm.sh/docs/intro/install/ and retry."
}

$secretsPath = Join-Path $Root "values\secrets.yaml"
$examplePath = Join-Path $Root "values\secrets.example.yaml"
if (-not (Test-Path $secretsPath)) {
  Copy-Item $examplePath $secretsPath
  Write-Host "Created values\secrets.yaml from the example file."
  Write-Host "Default passwords match tazama-stack docker defaults (postgres / unused)."
  Write-Host "Change them before installing on a shared or cloud cluster."
}

$stateSets = New-Object System.Collections.Generic.List[string]
$stringSets = New-Object System.Collections.Generic.List[string]

if ($Cms) {
  [void]$stateSets.Add("install.cms=true")
  [void]$stateSets.Add("install.flowable=true")
  [void]$stateSets.Add("install.couchdb=true")
  [void]$stateSets.Add("install.opensearch=true")
}
if ($Extensions) {
  [void]$stateSets.Add("install.dems=true")
  [void]$stateSets.Add("install.deapi=true")
}
if ($Dems) {
  [void]$stateSets.Add("install.dems=true")
}
if ($Deapi) {
  [void]$stateSets.Add("install.deapi=true")
}
if ($Tools) {
  [void]$stateSets.Add("install.connectionStudio=true")
  [void]$stateSets.Add("install.ruleStudio=true")
}
if ($ConnectionStudio) {
  [void]$stateSets.Add("install.connectionStudio=true")
}
if ($RuleStudio) {
  [void]$stateSets.Add("install.ruleStudio=true")
}
if ($Biar) {
  [void]$stateSets.Add("install.biar=true")
}
if ($PostgresReplica) {
  [void]$stateSets.Add("install.postgresqlReplica=true")
}

if (-not [string]::IsNullOrWhiteSpace($RelayEfrup)) {
  [void]$stringSets.Add("relay.efrup.transport=$($RelayEfrup.Trim().ToLowerInvariant())")
}
if (-not [string]::IsNullOrWhiteSpace($RelayTp)) {
  [void]$stringSets.Add("relay.tp.transport=$($RelayTp.Trim().ToLowerInvariant())")
}
if (-not [string]::IsNullOrWhiteSpace($RelayEa)) {
  [void]$stringSets.Add("relay.ea.transport=$($RelayEa.Trim().ToLowerInvariant())")
}
if (-not [string]::IsNullOrWhiteSpace($KafkaBrokers)) {
  [void]$stringSets.Add("relay.kafka.brokers=$($KafkaBrokers.Trim())")
}
if (-not [string]::IsNullOrWhiteSpace($RabbitmqUrl)) {
  [void]$stringSets.Add("relay.rabbitmq.url=$($RabbitmqUrl.Trim())")
}
if (-not [string]::IsNullOrWhiteSpace($RestUrl)) {
  [void]$stringSets.Add("relay.rest.url=$($RestUrl.Trim())")
}

if (-not [string]::IsNullOrWhiteSpace($PostgresqlHost)) {
  [void]$stringSets.Add("hosts.postgresql=$($PostgresqlHost.Trim())")
  [void]$stateSets.Add("install.postgresql=false")
}
if (-not [string]::IsNullOrWhiteSpace($PostgresqlReplicaHost)) {
  [void]$stringSets.Add("hosts.postgresqlReplica=$($PostgresqlReplicaHost.Trim())")
  [void]$stateSets.Add("install.postgresqlReplica=false")
}

Write-Host "Profile: $Profile"
Write-Host "Cloud:   $Cloud"
Write-Host "Command: $Command"

$hfArgs = @("-e", $Profile, "-f", "helmfile.yaml.gotmpl")
if ($env:KUBECONFIG) {
  $hfArgs = @("--kubeconfig", $env:KUBECONFIG) + $hfArgs
}
if ($Selector) {
  $hfArgs += @("-l", $Selector)
}
foreach ($pair in $stateSets) {
  $hfArgs += @("--state-values-set", $pair)
}
foreach ($pair in $stringSets) {
  $hfArgs += @("--state-values-set-string", $pair)
}

if ($stateSets.Count -gt 0 -or $stringSets.Count -gt 0) {
  Write-Host "Overrides (helmfile --state-values-set):"
  foreach ($pair in $stateSets) {
    Write-Host "  --state-values-set $pair"
  }
  foreach ($pair in $stringSets) {
    Write-Host "  --state-values-set-string $pair"
  }
}

switch ($Command) {
  "apply" {
    $diff = helm plugin list 2>$null | Select-String -Pattern "^\s*diff\b"
    if ($diff) {
      & helmfile @hfArgs apply
    } else {
      Write-Host "helm-diff plugin not found; using helmfile sync instead of apply."
      & helmfile @hfArgs sync
    }
  }
  "sync" { & helmfile @hfArgs sync }
  "destroy" { & helmfile @hfArgs destroy }
  "diff" { & helmfile @hfArgs diff }
  "status" { & helmfile @hfArgs status }
  "template" { & helmfile @hfArgs template }
  "lint" { & helmfile @hfArgs lint }
}

if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

if ($Command -eq "apply") {
  Write-Host ""
  Write-Host "Install submitted. Watch pods with:"
  Write-Host "  kubectl get pods -n tazama -w"
  Write-Host "Port-forward TMS (core profile / on-prem without ingress):"
  Write-Host "  kubectl port-forward -n tazama svc/tms-service 3000:3000"
  Write-Host "  kubectl port-forward -n tazama svc/admin-service 5100:5100"
}
