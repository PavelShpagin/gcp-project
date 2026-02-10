param(
  [ValidateSet("up", "down", "info")]
  [string]$Action = "up",

  [string]$ClusterName = "parcsnet",

  [Parameter(Mandatory = $false)]
  [string]$ProjectId,

  [string]$Zone = "us-central1-a",

  [int]$Daemons = 7,

  [string]$MachineTypeHost = "e2-small",
  [string]$MachineTypeDaemon = "e2-small",
  [string]$MachineTypeRunner = "e2-medium",

  [switch]$CreateRunner,

  # If true, daemons get external IPs (separate IP per daemon).
  # This allows independent outbound IPs for Google Maps API.
  # Set to $false only if you have Cloud NAT configured.
  [string]$DaemonExternalIp = "true",

  # If set, opens HostServer (1234) and Daemons (2222) from this CIDR.
  # Recommended: keep this to YOUR public /32 if you want to run module locally.
  [string]$ClientCidr,

  # If set, runner VM is created in same VPC and no external daemon access is needed.
  # If you don't create a runner, you must either run your module inside the VPC (VPN/IAP)
  # or set ClientCidr and allow external daemon access.
  [switch]$AllowExternalClient
)

$ErrorActionPreference = "Stop"

function Parse-Bool([string]$value, [bool]$default) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $default }
  switch ($value.Trim().ToLowerInvariant()) {
    "1" { return $true }
    "true" { return $true }
    "yes" { return $true }
    "y" { return $true }
    "0" { return $false }
    "false" { return $false }
    "no" { return $false }
    "n" { return $false }
    default { return $default }
  }
}

$daemonExternalIpBool = Parse-Bool $DaemonExternalIp $true

function Require-Gcloud {
  # Prefer gcloud.cmd on Windows. The gcloud PowerShell wrapper (gcloud.ps1)
  # can break depending on environment variables (notably when no venv is active).
  $cmd = Get-Command gcloud.cmd -ErrorAction SilentlyContinue
  if (-not $cmd) { $cmd = Get-Command gcloud -ErrorAction SilentlyContinue }
  if (-not $cmd) {
    throw "gcloud CLI not found. Install Google Cloud SDK and re-run."
  }
  $script:GcloudCmdPath = $cmd.Source
}

function Invoke-Gcloud {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GcloudArgs)
  & $script:GcloudCmdPath @GcloudArgs
  if ($LASTEXITCODE -ne 0) {
    # IMPORTANT: avoid leaking secrets (e.g., GMAPS_KEY) in error messages.
    $safe = @()
    for ($i = 0; $i -lt $GcloudArgs.Length; $i++) {
      $a = $GcloudArgs[$i]

      # Don't print full container env in case it contains secrets.
      if ($a -eq "--container-env") {
        $safe += $a
        if ($i + 1 -lt $GcloudArgs.Length) {
          $safe += "<redacted>"
          $i++
        }
        continue
      }

      # Generic redaction for common env-var style secrets.
      $a = $a -replace '(GMAPS_KEY|GOOGLE_MAPS_API_KEY)=([^,\s]+)', '$1=<redacted>'
      $safe += $a
    }

    throw "gcloud command failed: gcloud $($safe -join ' ')"
  }
}

function Try-Describe {
  param([string[]]$GcloudArgs)
  # This is an existence check: suppress all output and don't fail the script.
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $script:GcloudCmdPath @GcloudArgs 2>$null >$null
    return ($LASTEXITCODE -eq 0)
  } finally {
    $ErrorActionPreference = $old
  }
}

function Get-GMapsKey {
  $k = $env:GMAPS_KEY
  if ([string]::IsNullOrWhiteSpace($k)) { $k = $env:GOOGLE_MAPS_API_KEY }

  if ([string]::IsNullOrWhiteSpace($k) -and (Test-Path ".env")) {
    # Minimal .env parsing: KEY=VALUE per line, no expansion, no echo.
    $lines = Get-Content ".env" -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
      $t = $line.Trim()
      if ($t.StartsWith("#") -or $t.Length -eq 0) { continue }
      $parts = $t.Split("=", 2)
      if ($parts.Length -ne 2) { continue }
      $name = $parts[0].Trim()
      $val = $parts[1].Trim().Trim('"')
      if ($name -eq "GMAPS_KEY" -and -not [string]::IsNullOrWhiteSpace($val)) { return $val }
      if ($name -eq "GOOGLE_MAPS_API_KEY" -and -not [string]::IsNullOrWhiteSpace($val)) { $k = $val }
    }
  }

  return $k
}

function Ensure-FirewallRule {
  param(
    [string]$Name,
    [string]$Network,
    [string]$Direction,
    [string]$Action,
    [string]$Rules,
    [string]$SourceRanges,
    [string]$TargetTags
  )

  if (Try-Describe @("compute","firewall-rules","describe",$Name)) {
    Write-Host "Firewall rule exists: $Name"
    return
  }

  Write-Host "Creating firewall rule: $Name"
  Invoke-Gcloud compute firewall-rules create $Name `
    --network $Network `
    --direction $Direction `
    --action $Action `
    --rules $Rules `
    --source-ranges $SourceRanges `
    --target-tags $TargetTags `
    --quiet
}

Require-Gcloud

if ($ProjectId) {
  Invoke-Gcloud config set project $ProjectId | Out-Null
}

$hostName   = "$ClusterName-host"
$runnerName = "$ClusterName-runner"

$hostImage   = "registry.hub.docker.com/andriikhavro/parcshostserver:dotnetcore-2.1"
$daemonImage = "registry.hub.docker.com/andriikhavro/parcsdaemon:dotnetcore-2.1"

if ($Action -eq "down") {
  Write-Host "Deleting instances..."
  $names = @($hostName) + (1..$Daemons | ForEach-Object { "$ClusterName-daemon$_" })
  if ($CreateRunner) { $names += $runnerName }

  foreach ($n in $names) {
    if (Try-Describe @("compute","instances","describe",$n,"--zone",$Zone)) {
      Invoke-Gcloud compute instances delete $n --zone $Zone --quiet
    } else {
      Write-Host "Instance not found: $n"
    }
  }

  Write-Host "Done."
  exit 0
}

if ($Action -eq "info") {
  Write-Host "HostServer:"
  Invoke-Gcloud compute instances describe $hostName --zone $Zone --format="get(networkInterfaces[0].networkIP)"
  Write-Host "Daemons:"
  1..$Daemons | ForEach-Object {
    $n = "$ClusterName-daemon$_"
    if (Try-Describe @("compute","instances","describe",$n,"--zone",$Zone)) {
      Invoke-Gcloud compute instances describe $n --zone $Zone --format="get(networkInterfaces[0].networkIP)"
    }
  }
  exit 0
}

# Action == up

$gmapsKey = Get-GMapsKey
if ([string]::IsNullOrWhiteSpace($gmapsKey)) {
  Write-Warning "GMAPS_KEY is not set (nor GOOGLE_MAPS_API_KEY, nor present in .env). Live runs will fail on daemons."
}

$throttle = $env:GMAPS_THROTTLE_SECONDS

Write-Host "Ensuring firewall rules..."

# Internal comms (default network already has allow-internal; keep explicit for custom networks).
Ensure-FirewallRule `
  -Name "$ClusterName-allow-internal" `
  -Network "default" `
  -Direction "INGRESS" `
  -Action "ALLOW" `
  -Rules "tcp:1234,tcp:1236,tcp:2222" `
  -SourceRanges "10.128.0.0/9" `
  -TargetTags "$ClusterName"

if ($AllowExternalClient) {
  if ([string]::IsNullOrWhiteSpace($ClientCidr)) {
    throw "AllowExternalClient requires -ClientCidr (recommend: your public IP /32)."
  }

  Ensure-FirewallRule `
    -Name "$ClusterName-allow-client-host" `
    -Network "default" `
    -Direction "INGRESS" `
    -Action "ALLOW" `
    -Rules "tcp:1234,tcp:1236" `
    -SourceRanges $ClientCidr `
    -TargetTags "$ClusterName-host"

  Ensure-FirewallRule `
    -Name "$ClusterName-allow-client-daemon" `
    -Network "default" `
    -Direction "INGRESS" `
    -Action "ALLOW" `
    -Rules "tcp:2222" `
    -SourceRanges $ClientCidr `
    -TargetTags "$ClusterName-daemon"
}

Write-Host "Creating HostServer instance (container)..."
if (-not (Try-Describe @("compute","instances","describe",$hostName,"--zone",$Zone))) {
  Invoke-Gcloud compute instances create-with-container $hostName `
    --zone $Zone `
    --machine-type $MachineTypeHost `
    --tags "$ClusterName,$ClusterName-host" `
    --container-image $hostImage `
    --container-restart-policy always `
    --quiet
} else {
  Write-Host "HostServer already exists: $hostName"
}

$hostInternalIp = (& $script:GcloudCmdPath compute instances describe $hostName --zone $Zone --format="get(networkInterfaces[0].networkIP)").Trim()
if ([string]::IsNullOrWhiteSpace($hostInternalIp)) {
  throw "Cannot determine HostServer internal IP."
}

Write-Host "HostServer internal IP: $hostInternalIp"

Write-Host "Creating $Daemons daemon instance(s) (containers)..."
for ($i = 1; $i -le $Daemons; $i++) {
  $daemonName = "$ClusterName-daemon$i"
  $exists = Try-Describe @("compute","instances","describe",$daemonName,"--zone",$Zone)

  # By default, keep daemons private (no public IP). This avoids external IP quota
  # and matches the recommended "runner-in-VPC" workflow.
  $daemonNoAddressFlag = @()
  if (-not $daemonExternalIpBool) { $daemonNoAddressFlag = @("--no-address") }

  $envPairs = @("PARCS_HOST_SERVER_IP_ADDRESS=$hostInternalIp")
  if ($gmapsKey) { $envPairs += "GMAPS_KEY=$gmapsKey" }
  if ($throttle) { $envPairs += "GMAPS_THROTTLE_SECONDS=$throttle" }
  $envJoined = [string]::Join(",", $envPairs)

  if ($exists) {
    Write-Host "Daemon already exists: $daemonName"

    # IMPORTANT: updating container env without GMAPS_KEY would remove it from the container.
    # Only update when we have a key (or when we're explicitly allowing external client mode and
    # want to ensure the daemons see the correct HostServer IP).
    if ([string]::IsNullOrWhiteSpace($gmapsKey) -and -not $AllowExternalClient) {
      Write-Host "Skipping daemon env update (GMAPS_KEY missing): $daemonName"
      continue
    }

    Write-Host "Updating daemon container env: $daemonName"
    Invoke-Gcloud compute instances update-container $daemonName `
      --zone $Zone `
      --container-image $daemonImage `
      --container-env $envJoined `
      --container-restart-policy always `
      --quiet
    continue
  }

  Invoke-Gcloud compute instances create-with-container $daemonName `
    --zone $Zone `
    --machine-type $MachineTypeDaemon `
    --tags "$ClusterName,$ClusterName-daemon" `
    --container-image $daemonImage `
    --container-env $envJoined `
    --container-restart-policy always `
    $daemonNoAddressFlag `
    --quiet
}

if ($CreateRunner) {
  Write-Host "Creating runner VM (no container)..."
  if (-not (Try-Describe @("compute","instances","describe",$runnerName,"--zone",$Zone))) {
    # Windows runner is recommended if you want to run the existing net48 module without changing it.
    # For minimal boot time, use Windows Server 2022 (runner only).
    Invoke-Gcloud compute instances create $runnerName `
      --zone $Zone `
      --machine-type $MachineTypeRunner `
      --image-family "windows-2022" `
      --image-project "windows-cloud" `
      --tags "$ClusterName" `
      --quiet
  } else {
    Write-Host "Runner already exists: $runnerName"
  }
}

Write-Host ""
Write-Host "Cluster is up."
Write-Host "HostServer internal IP (use as --serverip from a VM in the same VPC): $hostInternalIp"
Write-Host ""
Write-Host "IMPORTANT:"
Write-Host "  - PARCS.NET client connects directly to daemons on port 2222."
Write-Host "  - If you want to run your module from your laptop, you must use -AllowExternalClient and set -ClientCidr,"
Write-Host "    AND make daemons advertise external IPs (EXTERNAL_LOCAL_IP_ADDRESS). Runner-in-VPC is simpler."

