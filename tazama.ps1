# SPDX-License-Identifier: Apache-2.0
param(
  [Parameter(Position = 0)]
  [ValidateSet("apply", "destroy", "status", "diff", "template", "lint", "sync", "secrets", "configure")]
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
  [string]$IngressServiceType = "",

  [string]$TmsConfigPath = "",
  [string]$AdminUrl = "",
  [switch]$Newman,
  [switch]$Truncate,
  [switch]$Auth,
  [switch]$SkipRestart
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

function Resolve-RequiredBin {
  param([string]$Name, [string]$Hint)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }
  $candidates = @(
    (Join-Path $env:USERPROFILE "bin\$Name.exe"),
    (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$Name.exe"),
    "C:\ProgramData\chocolatey\bin\$Name.exe"
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) {
      return $p
    }
  }
  Write-Error "$Name is not on PATH. $Hint"
}

$helmfile = $null
$helm = $null
if ($Command -notin @("secrets", "configure")) {
  $helmfile = Resolve-RequiredBin -Name "helmfile" -Hint "Install https://github.com/helmfile/helmfile/releases and retry."
  $helm = Resolve-RequiredBin -Name "helm" -Hint "Install https://helm.sh/docs/intro/install/ and retry."
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

function Resolve-TazamaTmsConfigRoot {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($TmsConfigPath)) {
    [void]$candidates.Add($TmsConfigPath.Trim())
  }
  if (-not [string]::IsNullOrWhiteSpace($env:TAZAMA_TMS_CONFIG)) {
    [void]$candidates.Add($env:TAZAMA_TMS_CONFIG.Trim())
  }
  $parent = Split-Path -Parent $Root
  foreach ($name in @("tms-configuration", "tms-configuration-main")) {
    [void]$candidates.Add((Join-Path $parent $name))
    [void]$candidates.Add((Join-Path $parent (Join-Path ".." $name)))
  }
  foreach ($dir in $candidates) {
    if ([string]::IsNullOrWhiteSpace($dir)) {
      continue
    }
    $resolved = $dir
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
      $resolved = Join-Path $Root $resolved
    }
    $marker = Join-Path $resolved "curl\rule-configs.json"
    if (Test-Path -LiteralPath $marker) {
      return (Resolve-Path -LiteralPath $resolved).Path
    }
  }
  Write-Error @"
tms-configuration was not found. Clone the private repo (GitHub access required) next to tazama-Helms, or pass -TmsConfigPath / set TAZAMA_TMS_CONFIG.

  git clone https://github.com/frmscoe/tms-configuration

This wrapper does not vendor that repo. The collection and curl payloads stay in the private clone.
"@
}

function Get-TazamaKubectlArgs {
  param([string[]]$Rest)
  if ($env:KUBECONFIG) {
    return @("--kubeconfig", $env:KUBECONFIG) + $Rest
  }
  return $Rest
}

function Wait-TazamaTcp {
  param([string]$HostName, [int]$Port, [int]$Seconds = 30)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $client = $null
    try {
      $client = New-Object System.Net.Sockets.TcpClient
      $ok = $client.ConnectAsync($HostName, $Port).Wait(400)
      if ($ok -and $client.Connected) {
        return
      }
    } catch {
    } finally {
      if ($client) {
        $client.Dispose()
      }
    }
    Start-Sleep -Milliseconds 250
  }
  Write-Error "Timed out waiting for ${HostName}:${Port}."
}

function Start-TazamaPortForward {
  param([string]$Kubectl, [string]$Service, [int]$Port)
  $pfArgs = Get-TazamaKubectlArgs -Rest @("port-forward", "-n", "tazama", "svc/$Service", "${Port}:${Port}")
  $proc = Start-Process -FilePath $Kubectl -ArgumentList $pfArgs -NoNewWindow -PassThru
  Wait-TazamaTcp -HostName "127.0.0.1" -Port $Port
  return $proc
}

function Invoke-TazamaAdminPost {
  param(
    [string]$Url,
    [string]$BodyPath = "",
    [string]$BodyText = "",
    [string]$Token = ""
  )
  $headers = @{ "Content-Type" = "application/json" }
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $headers["Authorization"] = "Bearer $Token"
  }
  if ($BodyPath) {
    $body = [System.IO.File]::ReadAllText($BodyPath)
  } else {
    $body = $BodyText
  }
  $resp = Invoke-WebRequest -Uri $Url -Method POST -Headers $headers -Body $body -ContentType "application/json" -UseBasicParsing
  $code = [int]$resp.StatusCode
  Write-Host "  $code $Url"
  if ($code -lt 200 -or $code -ge 300) {
    Write-Error "admin-service returned $code for $Url. Body: $($resp.Content)"
  }
}

function Get-TazamaAuthToken {
  param([string]$AuthBase, [string]$KeycloakBase)
  $kcBody = @{
    client_id     = "auth-lib-client"
    client_secret = "auth-lib-client-test-secret"
    username      = "tazama-user@tazama.org"
    password      = "password"
    grant_type    = "password"
  }
  $kc = Invoke-RestMethod -Method POST -Uri "$KeycloakBase/realms/tazama/protocol/openid-connect/token" -ContentType "application/x-www-form-urlencoded" -Body $kcBody
  $login = Invoke-WebRequest -Method POST -Uri "$AuthBase/v1/auth/login" -Headers @{ Authorization = "Bearer $($kc.access_token)" } -ContentType "application/json" -Body '{"username":"tazama-user@tazama.org","password":"password"}' -UseBasicParsing
  return $login.Content.Trim()
}

function Invoke-TazamaConfigure {
  $kubectl = Resolve-RequiredBin -Name "kubectl" -Hint "Install https://kubernetes.io/docs/tasks/tools/ and retry."
  $configRoot = Resolve-TazamaTmsConfigRoot
  $adminBase = if ($AdminUrl) { $AdminUrl.Trim().TrimEnd("/") } elseif ($env:ADMIN_URL) { $env:ADMIN_URL.Trim().TrimEnd("/") } else { "http://localhost:5100" }
  $needLocalAdmin = $adminBase -match "localhost|127\.0\.0\.1"
  $forwards = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

  Write-Host "Loading TMS configuration from $configRoot"
  Write-Host "admin-service: $adminBase"
  if ($Newman) {
    Write-Host "Runner: Newman (Admin-Service API v4.0.0 folder)"
  } else {
    Write-Host "Runner: curl payloads (same inject as the Postman Admin-Service API folder)"
  }

  try {
    if ($needLocalAdmin) {
      Write-Host "Port-forwarding svc/admin-service 5100:5100 ..."
      [void]$forwards.Add((Start-TazamaPortForward -Kubectl $kubectl -Service "admin-service" -Port 5100))
    }
    if ($Auth) {
      Write-Host "Port-forwarding Keycloak and Auth for a bearer token ..."
      [void]$forwards.Add((Start-TazamaPortForward -Kubectl $kubectl -Service "keycloak" -Port 8080))
      [void]$forwards.Add((Start-TazamaPortForward -Kubectl $kubectl -Service "auth-service" -Port 3020))
    }

    if ($Truncate) {
      Write-Host "Truncating configuration.rule, typology, network_map ..."
      $sql = "TRUNCATE TABLE rule, typology, network_map;"
      $execArgs = Get-TazamaKubectlArgs -Rest @("exec", "-n", "tazama", "postgresql-0", "--", "psql", "-U", "postgres", "-d", "configuration", "-c", $sql)
      & $kubectl @execArgs
      if ($LASTEXITCODE -ne 0) {
        Write-Error "TRUNCATE failed. Check that postgresql-0 is running in namespace tazama."
      }
    }

    $token = ""
    if ($Auth) {
      $token = Get-TazamaAuthToken -AuthBase "http://localhost:3020" -KeycloakBase "http://localhost:8080"
    }

    if ($Newman) {
      $newman = Resolve-RequiredBin -Name "newman" -Hint "Install Newman: npm install -g newman"
      $collection = Join-Path $configRoot "postman\tms-configuration.postman_collection.json"
      if (-not (Test-Path -LiteralPath $collection)) {
        Write-Error "Postman collection not found at $collection"
      }
      $raw = Get-Content -LiteralPath $collection -Raw | ConvertFrom-Json
      $adminFolder = @($raw.item) | Where-Object { $_.name -eq "Admin-Service API" } | Select-Object -First 1
      if (-not $adminFolder) {
        Write-Error "Collection has no 'Admin-Service API' folder. Do not run the Hasura API folder on this stack."
      }
      $v4 = @($adminFolder.item) | Where-Object { $_.name -eq "v4.0.0" } | Select-Object -First 1
      if (-not $v4) {
        Write-Error "Collection has no Admin-Service API / v4.0.0 folder."
      }
      $slim = [pscustomobject]@{
        info = $raw.info
        item = @($v4)
      }
      $work = Join-Path ([System.IO.Path]::GetTempPath()) ("tazama-newman-" + [guid]::NewGuid().ToString("n"))
      New-Item -ItemType Directory -Path $work | Out-Null
      $slimPath = Join-Path $work "admin-v4.postman_collection.json"
      $envPath = Join-Path $work "tazama-k8s.postman_environment.json"
      $slim | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $slimPath -Encoding utf8
      $hostPart = ($adminBase -replace "^https?://", "")
      $envObj = @{
        id     = [guid]::NewGuid().ToString()
        name   = "tazama-k8s"
        values = @(
          @{ key = "tazamaAdminUrl"; value = $hostPart; enabled = $true }
          @{ key = "path-admin-api-version"; value = "/v1"; enabled = $true }
          @{ key = "tazamaAuthUrl"; value = "localhost:3020"; enabled = $true }
          @{ key = "path-auth-api-version"; value = "/v1"; enabled = $true }
          @{ key = "keycloakUrl"; value = "localhost:8080"; enabled = $true }
          @{ key = "activePain001"; value = "false"; enabled = $true }
        )
      }
      $envObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $envPath -Encoding utf8
      Write-Host "Running Newman against Admin-Service API / v4.0.0 only (Hasura folder skipped)."
      & $newman run $slimPath -e $envPath --timeout-request 120000 --delay-request 200
      $newmanCode = $LASTEXITCODE
      Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
      if ($newmanCode -ne 0) {
        Write-Error "Newman exited $newmanCode."
      }
    } else {
      $curlDir = Join-Path $configRoot "curl"
      Invoke-TazamaAdminPost -Url "$adminBase/v1/admin/configuration/rule" -BodyPath (Join-Path $curlDir "rule-configs.json") -Token $token
      Invoke-TazamaAdminPost -Url "$adminBase/v1/admin/configuration/typology" -BodyPath (Join-Path $curlDir "typology-configs.json") -Token $token
      Invoke-TazamaAdminPost -Url "$adminBase/v1/admin/configuration/network_map" -BodyPath (Join-Path $curlDir "network-map.json") -Token $token
      Invoke-TazamaAdminPost -Url "$adminBase/v1/admin/configuration/network_map/4.0.0/activate" -BodyText '{"reloadMode":"cascade"}' -Token $token
    }

    if (-not $SkipRestart) {
      Write-Host "Restarting event-director, typology-processor, event-adjudicator ..."
      $restartArgs = Get-TazamaKubectlArgs -Rest @("rollout", "restart", "-n", "tazama", "deploy/event-director", "deploy/typology-processor", "deploy/event-adjudicator")
      & $kubectl @restartArgs
      $statusArgs = Get-TazamaKubectlArgs -Rest @("rollout", "status", "-n", "tazama", "deploy/event-director", "--timeout=180s")
      & $kubectl @statusArgs
    }
    Write-Host "Configuration loaded. Processors will pick up the active network map after the rollout."
  } finally {
    foreach ($proc in $forwards) {
      if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

Ensure-TazamaPasswords -Path $secretsPath -Force:$GenerateSecrets
Ensure-TazamaAuthKeys -Path $secretsPath -Force:$GenerateSecrets

if ($Command -eq "secrets") {
  Write-Host "Secrets written to values\secrets.yaml (gitignored). Each install gets its own 20-character URL-safe secrets. Do not commit that file."
  Write-Host "Kubernetes Secret objects encode the same strings again. Keep plaintext in the YAML. Do not paste kubectl base64 data back into this file."
  exit 0
}

if ($Command -eq "configure") {
  Invoke-TazamaConfigure
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

function Clear-TazamaPendingHelmReleases {
  param([string]$Namespace, [string]$HelmBin)
  if ([string]::IsNullOrWhiteSpace($HelmBin)) {
    return
  }
  $listArgs = @("list", "-n", $Namespace, "-a", "-o", "json")
  if ($env:KUBECONFIG) {
    $listArgs = @("--kubeconfig", $env:KUBECONFIG) + $listArgs
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $raw = & $HelmBin @listArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
      return
    }
    $releases = @($raw | ConvertFrom-Json)
    foreach ($rel in $releases) {
      $st = [string]$rel.status
      $name = [string]$rel.name
      if ([string]::IsNullOrWhiteSpace($name)) {
        continue
      }
      $cmdArgs = $null
      if ($st -eq "pending-upgrade" -or $st -eq "pending-rollback") {
        Write-Host "Clearing Helm $st on $name (rollback)..."
        $cmdArgs = @("rollback", $name, "-n", $Namespace)
      } elseif ($st -eq "pending-install") {
        Write-Host "Clearing Helm $st on $name (uninstall)..."
        $cmdArgs = @("uninstall", $name, "-n", $Namespace)
      }
      if ($null -eq $cmdArgs) {
        continue
      }
      if ($env:KUBECONFIG) {
        $cmdArgs = @("--kubeconfig", $env:KUBECONFIG) + $cmdArgs
      }
      & $HelmBin @cmdArgs | Out-Host
    }
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

if ($Command -in @("apply", "sync")) {
  Clear-TazamaPendingHelmReleases -Namespace "tazama" -HelmBin $helm
}

switch ($Command) {
  "apply" {
    $diff = helm plugin list 2>$null | Select-String -Pattern "^\s*diff\b"
    if ($diff) {
      & $helmfile @hfArgs apply
    } else {
      [Console]::Error.WriteLine("helm-diff plugin not found; using helmfile sync instead of apply.")
      [Console]::Error.WriteLine("helm-diff can also skip nested helmfiles; for a first install prefer: .\tazama.ps1 sync -Profile $Profile -Cloud $Cloud")
      & $helmfile @hfArgs sync
    }
  }
  "sync" { & $helmfile @hfArgs sync }
  "destroy" { & $helmfile @hfArgs destroy }
  "diff" { & $helmfile @hfArgs diff }
  "status" { & $helmfile @hfArgs status }
  "template" { & $helmfile @hfArgs template }
  "lint" { & $helmfile @hfArgs lint }
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
