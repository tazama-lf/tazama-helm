# SPDX-License-Identifier: Apache-2.0
param(
  [Parameter(Position = 0)]
  [ValidateSet("apply", "destroy", "status", "diff", "template", "lint", "sync", "secrets")]
  [string]$Command = "apply",

  [ValidateSet("core", "full", "private-rules", "member", "dockerhub")]
  [string]$Profile = "core",

  [ValidateSet("onprem", "eks", "gke", "aks")]
  [string]$Cloud = "onprem",

  [ValidateSet("standard", "small", "medium", "large")]
  [string]$Sizing = "standard",

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
  [switch]$GenerateSecrets,

  [string]$RelayEfrup = "",
  [string]$RelayTp = "",
  [string]$RelayEa = "",
  [string]$KafkaBrokers = "",
  [string]$RabbitmqUrl = "",
  [string]$RestUrl = "",

  [string]$PostgresqlHost = "",
  [string]$PostgresqlReplicaHost = "",

  [switch]$Ingress,
  [string]$IngressDomain = "",
  [string]$IngressClass = "",
  [string]$IngressServiceType = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

if ($Profile -eq "dockerhub") {
  [Console]::Error.WriteLine("Profile 'dockerhub' was renamed to 'full'. Using full.")
  $Profile = "full"
}
if ($Profile -eq "member") {
  [Console]::Error.WriteLine("Profile 'member' was renamed to 'private-rules'. Using private-rules.")
  $Profile = "private-rules"
}

$env:TAZAMA_CLOUD = $Cloud
$env:TAZAMA_SIZING = $Sizing

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

if (-not [string]::IsNullOrWhiteSpace($IngressServiceType)) {
  $svcType = $IngressServiceType.Trim()
  $allowedSvc = @("LoadBalancer", "NodePort")
  if ($allowedSvc -notcontains $svcType) {
    Write-Error "-IngressServiceType must be LoadBalancer or NodePort. Got '$IngressServiceType'."
  }
}

$helmfile = Get-Command helmfile -ErrorAction SilentlyContinue
if ($Command -ne "secrets" -and -not $helmfile) {
  Write-Error "helmfile is not on PATH. Install https://github.com/helmfile/helmfile/releases and retry."
}

$helm = Get-Command helm -ErrorAction SilentlyContinue
if ($Command -ne "secrets" -and -not $helm) {
  Write-Error "helm is not on PATH. Install https://helm.sh/docs/intro/install/ and retry."
}

$secretsPath = Join-Path $Root "values\secrets.yaml"
$examplePath = Join-Path $Root "values\secrets.example.yaml"
if (-not (Test-Path $secretsPath)) {
  Copy-Item $examplePath $secretsPath
  Write-Host "Created values\secrets.yaml from the example file."
}

function Get-OpenSslPath {
  $cmd = Get-Command openssl -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }
  $git = "C:\Program Files\Git\usr\bin\openssl.exe"
  if (Test-Path $git) {
    return $git
  }
  return $null
}

function Get-TazamaRandomSecret {
  # 15 random bytes encode to exactly 20 base64 characters (no padding).
  param([int]$Length = 20)
  $bytes = [Math]::Ceiling($Length * 3 / 4.0)
  $openssl = Get-OpenSslPath
  if ($openssl) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $out = & $openssl rand -base64 $bytes 2>&1 | Where-Object { $_ -is [string] -or $_.ToString() }
      $out = ($out | Out-String).Trim()
    } finally {
      $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -eq 0 -and $out) {
      $s = (($out | Out-String).Trim() -replace '\s', '')
      $s = $s.Replace('+', '-').Replace('/', '_').Replace('=', '')
      if ($s.Length -ge $Length) {
        return $s.Substring(0, $Length)
      }
    }
  }
  $buf = New-Object byte[] $bytes
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($buf)
  $rng.Dispose()
  $s = [Convert]::ToBase64String($buf).Replace('+', '-').Replace('/', '_').Replace('=', '')
  if ($s.Length -ge $Length) {
    return $s.Substring(0, $Length)
  }
  return $s
}

function Test-TazamaDummySecret {
  param([string]$Value)
  $v = $Value.Trim().Trim('"').Trim("'")
  return @("unused", "password", "tazama", "auth-lib-client-test-secret", "") -contains $v
}

function Ensure-TazamaPasswords {
  param([string]$Path, [bool]$Force)
  $targets = @{
    postgres = @("password", "replicationPassword")
    keycloak = @("adminPassword", "clientSecret")
    valkey   = @("password")
  }
  $lines = Get-Content -Path $Path
  $section = ""
  $changed = $false
  $generated = New-Object System.Collections.Generic.List[string]
  $newLines = foreach ($line in $lines) {
    if ($line -match '^  ([A-Za-z0-9_]+):') {
      $section = $Matches[1]
    }
    if ($line -match '^(    )([A-Za-z0-9_]+):\s*(.*)$' -and $targets.ContainsKey($section) -and $targets[$section] -contains $Matches[2]) {
      $key = $Matches[2]
      $val = $Matches[3]
      if ($Force -or (Test-TazamaDummySecret $val)) {
        $secret = Get-TazamaRandomSecret
        $changed = $true
        [void]$generated.Add("$section.$key")
        "    ${key}: `"$secret`""
        continue
      }
    }
    $line
  }
  if ($changed) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, (($newLines -join "`n").TrimEnd() + "`n"), $utf8)
    Write-Host "Generated random secrets in values\secrets.yaml: $($generated -join ', ')."
    Write-Host "Those strings are 20-character URL-safe secrets. Kubernetes Secret objects encode them again; keep this file as plaintext YAML."
    Write-Host "If Postgres already initialized, changing postgres.password does not rewrite the role. Wipe the PVC or ALTER USER inside Postgres."
  }
}

function ConvertTo-YamlLiteralBlock {
  param([string]$Pem, [string]$Indent = "      ")
  $lines = $Pem -replace "`r", "" -split "`n" | Where-Object { $_.Trim() -ne "" }
  return (($lines | ForEach-Object { "$Indent$_" }) -join "`n")
}

function Test-TazamaDummyAuthKey {
  param([string]$Raw)
  if ($Raw -notmatch "BEGIN (RSA )?PRIVATE KEY") {
    return $true
  }
  # Published tazama-stack test pair. Never ship this on a shared cluster.
  if ($Raw -match "AQDQZ9laLMsoNk8q") {
    return $true
  }
  return $false
}

function Ensure-TazamaAuthKeys {
  param([string]$Path, [bool]$Force)
  $raw = Get-Content -Raw -Path $Path
  if (-not $Force -and -not (Test-TazamaDummyAuthKey $raw)) {
    return
  }
  $openssl = Get-OpenSslPath
  if (-not $openssl) {
    Write-Error "Auth needs an RSA key pair in values\secrets.yaml. openssl was not found (install Git for Windows, or put openssl on PATH). Or paste a matching publicKey and privateKey yourself. Never commit the private key."
  }
  $work = Join-Path $env:TEMP ("tazama-auth-" + [guid]::NewGuid().ToString("n"))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $keyFile = Join-Path $work "private.pem"
    $pubFile = Join-Path $work "public.pem"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      & $openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $keyFile 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Error "openssl genpkey failed."
      }
      & $openssl rsa -in $keyFile -pubout -out $pubFile 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Error "openssl rsa -pubout failed."
      }
    } finally {
      $ErrorActionPreference = $prevEap
    }
    $pub = ConvertTo-YamlLiteralBlock -Pem (Get-Content -Raw $pubFile)
    $pri = ConvertTo-YamlLiteralBlock -Pem (Get-Content -Raw $keyFile)
    $authBlock = @"
  auth:
    publicKey: |
$pub
    privateKey: |
$pri
"@
    $updated = [regex]::Replace($raw, '(?ms)^  auth:.*?^(  valkey:)', ($authBlock.TrimEnd() + "`r`n`$1"), 1)
    if ($updated -eq $raw) {
      Write-Error "Could not insert generated Auth keys into values\secrets.yaml. Add publicKey and privateKey under secrets.auth."
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, ($updated.TrimEnd() + "`n"), $utf8)
    Write-Host "Generated an Auth RSA key pair in values\secrets.yaml (gitignored). Do not commit that file."
  } finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  }
}

Ensure-TazamaPasswords -Path $secretsPath -Force:$GenerateSecrets
Ensure-TazamaAuthKeys -Path $secretsPath -Force:$GenerateSecrets

if ($Command -eq "secrets") {
  Write-Host "Secrets written to values\secrets.yaml (gitignored). Each install gets its own 20-character URL-safe secrets. Do not commit that file."
  Write-Host "Kubernetes Secret objects encode the same strings again. Keep plaintext in the YAML. Do not paste kubectl base64 data back into this file."
  exit 0
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

if ($Ingress) {
  [void]$stateSets.Add("ingress.enabled=true")
  [void]$stateSets.Add("install.ingressNginx=true")
}
if (-not [string]::IsNullOrWhiteSpace($IngressDomain)) {
  [void]$stringSets.Add("ingress.domain=$($IngressDomain.Trim())")
}
if (-not [string]::IsNullOrWhiteSpace($IngressClass)) {
  [void]$stringSets.Add("ingress.className=$($IngressClass.Trim())")
}
if (-not [string]::IsNullOrWhiteSpace($IngressServiceType)) {
  [void]$stringSets.Add("ingressNginx.serviceType=$($IngressServiceType.Trim())")
  [void]$stringSets.Add("ingress.nginx.serviceType=$($IngressServiceType.Trim())")
}

Write-Host "Profile: $Profile"
Write-Host "Cloud:   $Cloud"
Write-Host "Sizing:  $Sizing"
Write-Host "Command: $Command"

if ($Sizing -ne "standard" -and $Command -in @("apply", "sync")) {
  Write-Host "Sizing '$Sizing' raises replica counts. Confirm the cluster has capacity:"
  Write-Host "  kubectl get nodes"
  Write-Host "  kubectl top nodes"
}

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
      [Console]::Error.WriteLine("helm-diff plugin not found; using helmfile sync instead of apply.")
      [Console]::Error.WriteLine("helm-diff can also skip nested helmfiles; for a first install prefer: .\tazama.ps1 sync -Profile $Profile -Cloud $Cloud")
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
  if ($Ingress -or $Cloud -ne "onprem") {
    Write-Host "Ingress: kubectl get ingress -n tazama"
    Write-Host "Map hosts (tms.<domain>, admin.<domain>, ...) in C:\Windows\System32\drivers\etc\hosts or /etc/hosts if DNS is not set."
  } else {
    Write-Host "Port-forward TMS (core profile / on-prem without ingress):"
    Write-Host "  kubectl port-forward -n tazama svc/tms-service 3000:3000"
    Write-Host "  kubectl port-forward -n tazama svc/admin-service 5100:5100"
  }
}
