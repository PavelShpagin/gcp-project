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
  $output = & $script:GcloudCmdPath @GcloudArgs 2>&1
  $exitCode = $LASTEXITCODE
  
  # Output to console (filter out error objects for display)
  $output | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
      Write-Host $_.Exception.Message
    } else {
      Write-Host $_
    }
  }
  
  if ($exitCode -ne 0) {
    # Capture error message for exception
    $errorMsg = ($output | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
      else { $_ }
    }) -join "`n"
    
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

    throw "gcloud command failed: $errorMsg"
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

# Get host external IP for SSH
$hostNatIp = (& $script:GcloudCmdPath compute instances describe $hostName --zone $Zone --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>$null)
if ([string]::IsNullOrWhiteSpace($hostNatIp)) {
  Write-Host "WARNING: Host has no external IP. Cannot build runner image automatically."
  Write-Host "Cluster is up (without runner image)."
  exit 0
}
$hostNatIp = $hostNatIp.Trim()

# Build and deploy runner Docker image
Write-Host ""
Write-Host "Building and deploying runner Docker image..."

$sshUser = $env:USERNAME
$sshKeyPath = Join-Path $env:USERPROFILE ".ssh\google_compute_engine"
$publishDir = ".\csharp\ParcsNetMapsStitcher\bin\Release\netcoreapp2.1\linux-x64\publish"

# Publish C# code
Write-Host "Publishing C# module..."
dotnet publish .\csharp\ParcsNetMapsStitcher\ParcsNetMapsStitcher.csproj -c Release -f netcoreapp2.1 -r linux-x64 --self-contained true
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

if (-not (Test-Path $publishDir)) {
  throw "Publish output not found: $publishDir"
}

$sshOpts = "-i `"$sshKeyPath`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=30 -o LogLevel=ERROR"

# Wait for VM to be ready for SSH
Write-Host "Waiting for host VM to be SSH-ready..."
$maxRetries = 12
for ($retry = 1; $retry -le $maxRetries; $retry++) {
  $testCmd = "ssh.exe $sshOpts -T -n $sshUser@$hostNatIp `"echo ready`""
  $testOut = cmd /c $testCmd 2>&1
  if ($LASTEXITCODE -eq 0) { break }
  Write-Host "  Attempt $retry/$maxRetries - waiting..."
  Start-Sleep -Seconds 10
}

# Create directories
Write-Host "Preparing remote workspace..."
$mkdirCmd = "ssh.exe $sshOpts -T -n $sshUser@$hostNatIp `"mkdir -p ~/parcsnet_run/bin ~/parcsnet_run/tests ~/parcsnet_run/out`""
cmd /c $mkdirCmd 2>&1 | Out-Null

# Upload files
Write-Host "Uploading runner binaries (~80MB)..."
$scpCmd = "scp.exe $sshOpts -r `"$publishDir\*`" `"$sshUser@$hostNatIp`:~/parcsnet_run/bin/`""
cmd /c $scpCmd 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "SCP (runner upload) failed." }

Write-Host "Uploading test inputs..."
$scpCmd = "scp.exe $sshOpts -r `".\tests\*`" `"$sshUser@$hostNatIp`:~/parcsnet_run/tests/`""
cmd /c $scpCmd 2>&1 | Out-Null

Write-Host "Uploading Dockerfile..."
$scpCmd = "scp.exe $sshOpts `".\gcp\parcsnet_runner.Dockerfile`" `"$sshUser@$hostNatIp`:~/parcsnet_run/Dockerfile`""
cmd /c $scpCmd 2>&1 | Out-Null

Write-Host "Building Docker image on VM (this may take a minute)..."
$buildCmd = "ssh.exe $sshOpts -T -n $sshUser@$hostNatIp `"docker build -t parcsnet-maps-runner:latest ~/parcsnet_run`""
cmd /c $buildCmd 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw "Docker build failed." }

Write-Host ""
Write-Host "============================================="
Write-Host "Cluster is ready!"
Write-Host "============================================="
Write-Host "HostServer: $hostName ($hostNatIp)"
Write-Host "Daemons: $Daemons"
Write-Host "Runner image: parcsnet-maps-runner:latest (built)"
Write-Host ""
Write-Host "Run experiments with:"
Write-Host "  .\gcp\run.ps1 -Run -Regions 1 -PointsPerRegion $Daemons -Concurrency 16"

