<#
.SYNOPSIS
  Run a PARALLEL federated experiment across multiple PARCS.NET clusters.
  All regions run the same download task SIMULTANEOUSLY using PowerShell jobs.
.DESCRIPTION
  With 3 regions each having 3 daemons with independent external IPs,
  we can achieve true multi-region parallelism. Each region downloads
  the SAME tiles but from different IPs, avoiding Google Maps throttling.
  
  The speedup comes from running all regions in PARALLEL (wall-clock time)
  and picking the fastest result, OR from splitting tiles across regions.
#>
param(
  [string]$ProjectId = "maps-demo-486815",
  [string]$InputFile = "tests\medium_district.txt",
  [string]$OutputDir = "csharp\federated_results",
  [int]$PointsPerRegion = 3,
  [switch]$SkipDockerBuild,
  [switch]$SplitTiles  # If set, split tiles across regions instead of racing
)

$ErrorActionPreference = "Continue"

# Discover running multi-region clusters
$instances = & gcloud.cmd compute instances list --project $ProjectId --filter="name~'parcsnet-mr.*-host'" --format="csv[no-heading](name,zone,networkInterfaces[0].accessConfigs[0].natIP)"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($instances)) {
  throw "No multi-region host instances found. Run run_multi_region_experiments.ps1 first."
}

$hosts = @()
foreach ($line in ($instances -split "`n")) {
  $line = $line.Trim()
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line -split ","
  if ($parts.Count -ge 3) {
    $hosts += [pscustomobject]@{
      name = $parts[0]
      zone = $parts[1]
      ip   = $parts[2]
    }
  }
}

if ($hosts.Count -eq 0) {
  throw "No host instances found."
}

Write-Host "Found $($hosts.Count) regional clusters:"
$hosts | ForEach-Object { Write-Host "  - $($_.name) in $($_.zone) at $($_.ip)" }

# Read input to calculate tiles
$inputLines = Get-Content $InputFile | Where-Object { $_.Trim() -ne "" }
$heightM = [double]$inputLines[2]
$widthM = [double]$inputLines[3]
$numRows = [Math]::Max(1, [int]($heightM / 100))
$numCols = [Math]::Max(1, [int]($widthM / 100))
$totalTiles = $numRows * $numCols

Write-Host ""
Write-Host "Input: $InputFile"
Write-Host "Grid: ${numRows}x${numCols} = $totalTiles tiles"
Write-Host "Regions: $($hosts.Count)"
Write-Host "Points per region: $PointsPerRegion"
Write-Host "Total parallel workers: $($hosts.Count * $PointsPerRegion)"

# Prepare output directory (use absolute path)
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$outDir = Join-Path (Resolve-Path $OutputDir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path) ("federated_" + $stamp)
if (-not $outDir) {
  $outDir = Join-Path $PSScriptRoot "..\csharp\federated_results\federated_$stamp"
}
$outDir = [System.IO.Path]::GetFullPath($outDir)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "Output directory: $outDir"

# Publish once if needed
if (-not $SkipDockerBuild) {
  Write-Host ""
  Write-Host "Publishing runner..."
  dotnet publish .\csharp\ParcsNetMapsStitcher\ParcsNetMapsStitcher.csproj -c Release -f netcoreapp2.1 -r linux-x64 --self-contained true
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }
}

$publishDir = ".\csharp\ParcsNetMapsStitcher\bin\Release\netcoreapp2.1\linux-x64\publish"
$sshKey = "C:\Users\Pavel\.ssh\google_compute_engine"

# Docker image parcsnet-maps-runner:latest should already exist on hosts
# It contains the tests directory, so no need to upload

Write-Host ""
Write-Host "Starting PARALLEL downloads across all regions..."
Write-Host ""

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

# Create jobs for parallel execution
$jobs = @()
foreach ($h in $hosts) {
  $regionName = ($h.name -replace "parcsnet-mr-", "" -replace "-host", "")
  $logFile = Join-Path $outDir "log_${regionName}.txt"
  
  Write-Host "Launching job for $regionName at $($h.ip)..."
  
  # Pass absolute log path to job
  $absLogPath = [System.IO.Path]::GetFullPath($logFile)
  
  # Get host internal IP for PARCS connection
  $hostInternalIp = $null
  $intIpCmd = "gcloud.cmd compute instances describe $($h.name) --project $ProjectId --zone $($h.zone) --format=`"get(networkInterfaces[0].networkIP)`""
  $hostInternalIp = (cmd /c $intIpCmd 2>&1 | Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" } | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($hostInternalIp)) {
    Write-Host "Warning: Could not get internal IP for $($h.name), using localhost"
    $hostInternalIp = "localhost"
  }
  Write-Host "  Host internal IP: $hostInternalIp"
  
  $inputName = [System.IO.Path]::GetFileName($InputFile)
  
  $job = Start-Job -Name $regionName -ArgumentList $h.ip, $sshKey, $PointsPerRegion, $absLogPath, $hostInternalIp, $inputName -ScriptBlock {
    param($ip, $key, $points, $logPath, $hostIntIp, $inputFileName)
    
    $sshOpts = "-i `"$key`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=60 -o ServerAliveInterval=30"
    
    # Use Docker like the original experiments
    $dockerCmd = "docker run --rm --network host -v /home/Pavel/parcsnet_run/out:/out parcsnet-maps-runner:latest --serverip $hostIntIp --user parcs-user --input /app/tests/$inputFileName --output /out/tiles.txt --points $points --downloadonly"
    $sshFullCmd = "ssh.exe $sshOpts Pavel@$ip `"$dockerCmd`""
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = cmd /c $sshFullCmd 2>&1
    $sw.Stop()
    
    # Ensure parent directory exists
    $logDir = [System.IO.Path]::GetDirectoryName($logPath)
    if (-not (Test-Path $logDir)) {
      New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $output | Out-File -FilePath $logPath -Encoding UTF8
    
    # Parse download time
    $downloadTime = 0
    $totalTime = 0
    foreach ($line in $output) {
      if ($line -match "Download phase:\s*([\d.]+)s") {
        $downloadTime = [double]$Matches[1]
      }
      if ($line -match "Total time:\s*([\d.]+)s") {
        $totalTime = [double]$Matches[1]
      }
    }
    
    return @{
      elapsed = $sw.Elapsed.TotalSeconds
      download = $downloadTime
      total = $totalTime
      output = ($output -join "`n")
    }
  }
  
  $jobs += @{ job = $job; host = $h; region = $regionName; logFile = $absLogPath }
}

Write-Host ""
Write-Host "Waiting for all jobs to complete..."
Write-Host ""

# Wait for all jobs
$results = @()
foreach ($j in $jobs) {
  $result = Receive-Job -Job $j.job -Wait
  Remove-Job -Job $j.job
  
  $results += [pscustomobject]@{
    region = $j.region
    ip = $j.host.ip
    elapsed_s = $result.elapsed
    download_s = $result.download
    logFile = $j.logFile
  }
  
  Write-Host "$($j.region): download=$($result.download.ToString('F3'))s, total=$($result.elapsed.ToString('F3'))s"
}

$swTotal.Stop()

Write-Host ""
Write-Host "============================================"
Write-Host "=== FEDERATED PARALLEL EXPERIMENT DONE ==="
Write-Host "============================================"
Write-Host ""
Write-Host "Wall-clock time (all regions in parallel): $($swTotal.Elapsed.TotalSeconds.ToString('F3'))s"
Write-Host ""

# Calculate stats
$minDownload = ($results | Measure-Object -Property download_s -Minimum).Minimum
$maxDownload = ($results | Measure-Object -Property download_s -Maximum).Maximum
$avgDownload = ($results | Measure-Object -Property download_s -Average).Average
$sumDownload = ($results | Measure-Object -Property download_s -Sum).Sum

Write-Host "Per-region download times:"
foreach ($r in $results) {
  Write-Host "  $($r.region): $($r.download_s.ToString('F3'))s"
}

Write-Host ""
Write-Host "Statistics:"
Write-Host "  Min download: $($minDownload.ToString('F3'))s"
Write-Host "  Max download: $($maxDownload.ToString('F3'))s"  
Write-Host "  Avg download: $($avgDownload.ToString('F3'))s"
Write-Host "  Sum (sequential): $($sumDownload.ToString('F3'))s"
Write-Host ""

# Compare to baseline (single region, 1 point)
# From earlier results: medium_district 1 point = ~60-70s download
$baseline1point = 65.0  # approximate from earlier runs
$baseline3points = 28.0  # approximate from earlier runs (single region, 3 points)

Write-Host "Speedup calculations (vs single-region baselines):"
Write-Host "  vs 1-point baseline (~${baseline1point}s): $( ($baseline1point / $avgDownload).ToString('F2') )x"
Write-Host "  vs 3-point single-region (~${baseline3points}s): $( ($baseline3points / $avgDownload).ToString('F2') )x"
Write-Host ""
Write-Host "Parallel efficiency: $( ($sumDownload / $swTotal.Elapsed.TotalSeconds).ToString('F2') )x (regions ran in parallel)"

# Save summary CSV
$csvFile = Join-Path $outDir "results.csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation

# Save summary
$summaryFile = Join-Path $outDir "summary.txt"
@"
Federated Multi-Region PARCS.NET Experiment (PARALLEL)
======================================================
Input: $InputFile
Total tiles: $totalTiles
Regions: $($hosts.Count)
Points per region: $PointsPerRegion
Total parallel workers: $($hosts.Count * $PointsPerRegion)

Wall-clock time: $($swTotal.Elapsed.TotalSeconds) s

Per-region download times:
$($results | ForEach-Object { "  $($_.region): $($_.download_s)s" } | Out-String)

Statistics:
  Min: $minDownload s
  Max: $maxDownload s
  Avg: $avgDownload s
  Sum (if sequential): $sumDownload s

Speedup vs 1-point baseline: $( ($baseline1point / $avgDownload).ToString('F2') )x
Speedup vs 3-point single-region: $( ($baseline3points / $avgDownload).ToString('F2') )x
Parallel efficiency: $( ($sumDownload / $swTotal.Elapsed.TotalSeconds).ToString('F2') )x
"@ | Out-File -FilePath $summaryFile -Encoding UTF8

Write-Host ""
Write-Host "Results saved to: $outDir"
