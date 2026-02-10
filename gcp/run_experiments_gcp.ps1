param(
  # GCP
  [string]$ProjectId = "maps-demo-486815",
  [string]$Zone = "us-central1-a",
  [string]$HostInstance = "parcsnet-host",
  # Optional label for multi-region aggregation (e.g., "us-central1")
  [string]$RegionLabel,

  # Optional overrides (skip gcloud describe if provided)
  [string]$HostNatIp,
  [string]$HostInternalIp,

  # SSH
  [string]$SshUser = $env:USERNAME,
  [string]$SshKeyPath = (Join-Path $env:USERPROFILE ".ssh\\google_compute_engine"),

  # Experiment params
  [int[]]$Points = @(1, 4, 7),
  [string[]]$Inputs = @(
    "tests\\small_city_block.txt",
    "tests\\medium_district.txt"
  ),
  # Optional explicit run list: items like "tests\small_city_block.txt|4"
  [string[]]$RunList,
  [switch]$DryRun,

  # Outputs
  [string]$LocalOutRoot = "csharp",
  [switch]$DownloadOutputs,

  # Runner image
  [switch]$SkipDockerBuild,
  # Publish control (useful for multi-region parallel runs)
  [switch]$SkipPublish,
  # Must be a relative path (Windows drive letters break scp syntax)
  [string]$PublishDir
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "Required command not found: $Name" }
  return $cmd.Source
}

function Require-Gcloud {
  $cmd = Get-Command gcloud.cmd -ErrorAction SilentlyContinue
  if (-not $cmd) { $cmd = Get-Command gcloud -ErrorAction SilentlyContinue }
  if (-not $cmd) { throw "gcloud CLI not found. Install Google Cloud SDK and re-run." }
  return $cmd.Source
}

function Parse-Seconds([string]$content, [string]$label) {
  $m = [regex]::Match($content, [regex]::Escape($label) + '\s*(\d+\.?\d*)s')
  if ($m.Success) { return [double]$m.Groups[1].Value }
  return $null
}

function Assert-LastExit([string]$what) {
  if ($LASTEXITCODE -ne 0) {
    throw "$what failed (exit code $LASTEXITCODE)."
  }
}

function Invoke-Native([scriptblock]$Command) {
  # Prevent stderr from being treated as terminating errors (e.g., ssh warnings).
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $out = & $Command 2>&1
  $exit = $LASTEXITCODE
  $ErrorActionPreference = $old
  return [pscustomobject]@{
    Output   = $out
    ExitCode = $exit
  }
}

$ssh = Require-Command "ssh.exe"
$scp = Require-Command "scp.exe"
$gcloud = Require-Gcloud

# Make gcloud safer/non-interactive for automation (avoid update checks/prompts).
$env:CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK = "true"
$env:CLOUDSDK_CORE_DISABLE_PROMPTS = "1"

if (-not (Test-Path $SshKeyPath)) {
  throw "SSH key not found at: $SshKeyPath`nExpected gcloud-generated key. Try running: gcloud compute ssh $HostInstance --zone $Zone"
}

Write-Host "Resolving HostServer IPs from GCP..."
$hostNatIp = $HostNatIp
$hostInternalIp = $HostInternalIp

if ([string]::IsNullOrWhiteSpace($hostNatIp)) {
  $hostNatIp = & $gcloud compute instances describe $HostInstance --project $ProjectId --zone $Zone --format="get(networkInterfaces[0].accessConfigs[0].natIP)" --quiet
  Assert-LastExit "gcloud describe (natIP)"
}
if ([string]::IsNullOrWhiteSpace($hostInternalIp)) {
  $hostInternalIp = & $gcloud compute instances describe $HostInstance --project $ProjectId --zone $Zone --format="get(networkInterfaces[0].networkIP)" --quiet
  Assert-LastExit "gcloud describe (internal IP)"
}

$hostNatIp = $hostNatIp.Trim()
$hostInternalIp = $hostInternalIp.Trim()

if ([string]::IsNullOrWhiteSpace($hostNatIp)) {
  throw "Host instance '$HostInstance' has no external IP (NAT IP).`nEither add one, or adapt this script to use IAP tunneling."
}
if ([string]::IsNullOrWhiteSpace($hostInternalIp)) {
  throw "Could not resolve internal IP for host instance '$HostInstance'."
}

if (-not $SkipPublish) {
  Write-Host "Publishing runner (linux-x64, self-contained)..."
  dotnet publish .\csharp\ParcsNetMapsStitcher\ParcsNetMapsStitcher.csproj -c Release -f netcoreapp2.1 -r linux-x64 --self-contained true
  Assert-LastExit "dotnet publish"
} else {
  Write-Host "Skipping publish (using existing output)."
}

# IMPORTANT: keep this as a relative path (Windows absolute paths include ':' which breaks scp syntax).
$publishDir = ".\\csharp\\ParcsNetMapsStitcher\\bin\\Release\\netcoreapp2.1\\linux-x64\\publish"
if (-not [string]::IsNullOrWhiteSpace($PublishDir)) {
  if ($PublishDir -match "^[A-Za-z]:") {
    throw "PublishDir must be a relative path (got: $PublishDir)."
  }
  $publishDir = $PublishDir
}
if (-not (Test-Path $publishDir)) {
  throw "Publish output not found: $publishDir"
}

$sshArgsCommon = @(
  "-i", $SshKeyPath,
  "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=/dev/null",
  # Fail fast in automation (never prompt for password/passphrase)
  "-o", "BatchMode=yes",
  "-o", "ConnectTimeout=20",
  "-o", "ServerAliveInterval=15",
  "-o", "ServerAliveCountMax=3"
)

# ssh: never request TTY and don't read stdin (prevents hangs in batch contexts).
$sshArgs = @("-T", "-n") + $sshArgsCommon

# scp: batch mode (no prompts) + same ssh options.
$scpArgs = @("-B") + $sshArgsCommon

Write-Host "Preparing remote workspace on $hostNatIp..."
$sshResult = Invoke-Native { & $ssh @sshArgs "$SshUser@$hostNatIp" "mkdir -p ~/parcsnet_run/bin ~/parcsnet_run/tests ~/parcsnet_run/out" }
$sshResult.Output | ForEach-Object { Write-Host $_ }
if ($sshResult.ExitCode -ne 0) { throw "SSH (mkdir) failed (exit code $($sshResult.ExitCode))." }

Write-Host "Uploading published runner (~80MB)..."
$scpResult = Invoke-Native { & $scp @scpArgs -r "$publishDir\\*" "$SshUser@$hostNatIp`:~/parcsnet_run/bin/" }
$scpResult.Output | ForEach-Object { Write-Host $_ }
if ($scpResult.ExitCode -ne 0) { throw "SCP (runner upload) failed (exit code $($scpResult.ExitCode))." }

Write-Host "Uploading inputs..."
$scpResult = Invoke-Native { & $scp @scpArgs -r ".\\tests\\*" "$SshUser@$hostNatIp`:~/parcsnet_run/tests/" }
$scpResult.Output | ForEach-Object { Write-Host $_ }
if ($scpResult.ExitCode -ne 0) { throw "SCP (inputs upload) failed (exit code $($scpResult.ExitCode))." }

Write-Host "Uploading runner Dockerfile..."
$scpResult = Invoke-Native { & $scp @scpArgs ".\\gcp\\parcsnet_runner.Dockerfile" "$SshUser@$hostNatIp`:~/parcsnet_run/Dockerfile" }
$scpResult.Output | ForEach-Object { Write-Host $_ }
if ($scpResult.ExitCode -ne 0) { throw "SCP (Dockerfile upload) failed (exit code $($scpResult.ExitCode))." }

if (-not $SkipDockerBuild) {
  Write-Host "Building runner image on VM..."
  $sshResult = Invoke-Native { & $ssh @sshArgs "$SshUser@$hostNatIp" "docker build -t parcsnet-maps-runner:latest ~/parcsnet_run" }
  $sshResult.Output | ForEach-Object { Write-Host $_ }
  if ($sshResult.ExitCode -ne 0) { throw "SSH (docker build) failed (exit code $($sshResult.ExitCode))." }
} else {
  Write-Host "Skipping runner image build (using existing image)..."
}

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$regionTag = $RegionLabel
if ([string]::IsNullOrWhiteSpace($regionTag)) {
  $regionTag = $Zone
}
$outDir = Join-Path $LocalOutRoot ("results_gcp_" + $stamp + "_" + $regionTag)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$rows = @()

$runs = @()
if ($RunList -and $RunList.Count -gt 0) {
  foreach ($item in $RunList) {
    $parts = $item -split "\|", 2
    if ($parts.Count -ne 2) {
      throw "Invalid RunList item: '$item'. Expected format: path|points"
    }

    $runInput = $parts[0]
    $runPoints = [int]$parts[1]
    $runs += [pscustomobject]@{ input = $runInput; points = $runPoints }
  }
} else {
  foreach ($input in $Inputs) {
    foreach ($p in $Points) {
      $runs += [pscustomobject]@{ input = $input; points = $p }
    }
  }
}

foreach ($run in $runs) {
  $input = $run.input
  $p = $run.points

  $inputName = [IO.Path]::GetFileName($input)
  $dataset = [IO.Path]::GetFileNameWithoutExtension($input)

  $remoteOut = "/out/out_{0}_{1}.txt" -f $dataset, $p
  $logFile = Join-Path $outDir ("log_{0}_{1}.txt" -f $dataset, $p)

  $remoteCmd = @(
    "docker run --rm --network host",
    ("-v /home/{0}/parcsnet_run/out:/out" -f $SshUser),
    "parcsnet-maps-runner:latest",
    "--serverip", $hostInternalIp,
    "--user", "parcs-user",
    "--input", ("/app/tests/{0}" -f $inputName),
    "--output", $remoteOut,
    "--points", $p
  ) -join " "

  if ($DryRun) { $remoteCmd += " --dryrun" }

  Write-Host ("Running {0} with points={1}..." -f $inputName, $p)
  $sshResult = Invoke-Native { & $ssh @sshArgs "$SshUser@$hostNatIp" $remoteCmd }
  $out = $sshResult.Output
  $runExit = $sshResult.ExitCode
  $out | ForEach-Object { Write-Host $_ }
  $out | Out-File -FilePath $logFile -Encoding utf8
  if ($runExit -ne 0) {
    throw "Remote run failed (exit code $runExit). See log: $logFile"
  }

  # Parse timings from log file (cleaner than parsing PS output objects)
  $content = Get-Content $logFile -Raw
  $download = Parse-Seconds $content "Download phase:"
  $mosaic = Parse-Seconds $content "Mosaic phase:"
  $total = Parse-Seconds $content "Total time:"
  if ($null -eq $download -or $null -eq $mosaic -or $null -eq $total) {
    throw "Could not parse timings from output. See log: $logFile"
  }

  $rows += [pscustomobject]@{
    region = $regionTag
    dataset = $dataset
    points = $p
    download_s = $download
    mosaic_s = $mosaic
    total_s = $total
    remote_output_file = $remoteOut
    log_file = $logFile
  }
}

$csvPath = Join-Path $outDir "results.csv"
$rows | Export-Csv -NoTypeInformation -Path $csvPath

Write-Host ""
Write-Host "Saved results to: $csvPath"

if ($DownloadOutputs) {
  Write-Host "Downloading remote outputs (can be large)..."
  $scpResult = Invoke-Native { & $scp @scpArgs -r "$SshUser@$hostNatIp`:~/parcsnet_run/out/*" $outDir }
  $scpResult.Output | ForEach-Object { Write-Host $_ }
  if ($scpResult.ExitCode -ne 0) { throw "SCP (download outputs) failed (exit code $($scpResult.ExitCode))." }
}

