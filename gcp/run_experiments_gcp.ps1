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
  [string]$LocalOutRoot = "csharp"
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

Write-Host "Resolving HostServer IPs from GCP..."

if ([string]::IsNullOrWhiteSpace($HostNatIp)) {
  $hostNatIp = & $gcloud compute instances describe $HostInstance --project $ProjectId --zone $Zone --format="get(networkInterfaces[0].accessConfigs[0].natIP)" --quiet
  Assert-LastExit "gcloud describe (NAT IP)"
} else {
  $hostNatIp = $HostNatIp
}

if ([string]::IsNullOrWhiteSpace($HostInternalIp)) {
  $hostInternalIp = & $gcloud compute instances describe $HostInstance --project $ProjectId --zone $Zone --format="get(networkInterfaces[0].networkIP)" --quiet
  Assert-LastExit "gcloud describe (internal IP)"
} else {
  $hostInternalIp = $HostInternalIp
}

$hostNatIp = $hostNatIp.Trim()
$hostInternalIp = $hostInternalIp.Trim()

if ([string]::IsNullOrWhiteSpace($hostNatIp)) {
  throw "Host instance '$HostInstance' has no external IP."
}
if ([string]::IsNullOrWhiteSpace($hostInternalIp)) {
  throw "Could not resolve internal IP for host instance '$HostInstance'."
}

Write-Host "Host: $HostInstance ($hostNatIp / $hostInternalIp)"

$sshArgsCommon = @(
  "-i", $SshKeyPath,
  "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=/dev/null",
  "-o", "BatchMode=yes",
  "-o", "ConnectTimeout=20",
  "-o", "ServerAliveInterval=15",
  "-o", "ServerAliveCountMax=3"
)

$sshArgs = @("-T", "-n") + $sshArgsCommon
$scpArgs = @("-B") + $sshArgsCommon

# Verify Docker image exists
Write-Host "Verifying runner image exists..."
$checkResult = Invoke-Native { & $ssh @sshArgs "$SshUser@$hostNatIp" "docker images -q parcsnet-maps-runner:latest 2>/dev/null" }
$imageId = ($checkResult.Output -join "").Trim()
if (-not ($imageId -match "^[a-f0-9]{12}")) {
  throw "Runner image not found on host. Run parcsnet_cluster.ps1 -Action up first to build it."
}
Write-Host "  Runner image OK (ID: $imageId)"

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
    $runs += @{ input = $parts[0]; points = [int]$parts[1] }
  }
} else {
  foreach ($input in $Inputs) {
    foreach ($p in $Points) {
      $runs += @{ input = $input; points = $p }
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
    "docker", "run", "--rm", "--network", "host",
    "-v", "/home/$SshUser/parcsnet_run/out:/out",
    "parcsnet-maps-runner:latest",
    "--serverip", $hostInternalIp,
    "--user", "parcs-user",
    "--input", ("/app/tests/{0}" -f $inputName),
    "--output", $remoteOut,
    "--points", $p
  ) -join " "

  Write-Host ""
  Write-Host "Running $inputName with points=$p..."

  if ($DryRun) {
    Write-Host "[DRY RUN] Would execute: $remoteCmd"
    continue
  }

  $sshResult = Invoke-Native { & $ssh @sshArgs "$SshUser@$hostNatIp" $remoteCmd }
  $sshResult.Output | ForEach-Object { Write-Host $_ }
  $sshResult.Output | Out-File -FilePath $logFile -Encoding UTF8

  $runExit = $sshResult.ExitCode
  if ($runExit -ne 0) {
    throw "Remote run failed (exit code $runExit). See log: $logFile"
  }

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

# Download and decode outputs
Write-Host "Downloading remote outputs..."
$scpResult = Invoke-Native { & $scp @scpArgs -r "$SshUser@$hostNatIp`:~/parcsnet_run/out/*" $outDir }
$scpResult.Output | ForEach-Object { Write-Host $_ }
if ($scpResult.ExitCode -ne 0) { 
  Write-Host "WARNING: SCP (download outputs) failed. Skipping decode."
} else {
  $scriptRoot = Split-Path -Parent $PSScriptRoot
  $decodeScript = Join-Path $scriptRoot "decode_output.py"
  
  if (Test-Path $decodeScript) {
    $outputFiles = Get-ChildItem -Path $outDir -Filter "out_*.txt" -ErrorAction SilentlyContinue
    foreach ($outFile in $outputFiles) {
      $baseName = [IO.Path]::GetFileNameWithoutExtension($outFile.Name) -replace "^out_", ""
      $imgFile = Join-Path $outDir "$baseName.jpg"
      
      Write-Host "Decoding $($outFile.Name) -> $baseName.jpg..."
      $decodeResult = Invoke-Native { python $decodeScript $outFile.FullName $imgFile }
      $decodeResult.Output | ForEach-Object { Write-Host $_ }
      
      if ($decodeResult.ExitCode -eq 0 -and (Test-Path $imgFile)) {
        Write-Host "  Saved: $imgFile"
        Remove-Item $outFile.FullName -Force -ErrorAction SilentlyContinue
      }
    }
  } else {
    Write-Host "WARNING: decode_output.py not found - skipping auto-decode"
  }
}

Write-Host ""
Write-Host "Results and images saved to: $outDir"
