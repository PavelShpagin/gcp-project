<#
.SYNOPSIS
  Run a TRUE FEDERATED experiment - split tiles across regions.
  Each region downloads only its portion of tiles, then we merge locally.
#>
param(
  [string]$ProjectId = "maps-demo-486815",
  [string]$InputFile = "tests\medium_district.txt",
  [string]$OutputDir = "csharp\federated_results",
  [int]$PointsPerRegion = 1,
  [switch]$ForceRebuild,
  [int]$Concurrency = 16,
  [int]$MaxRegions = 0,
  [switch]$Optimized
)

$ErrorActionPreference = "Continue"

# Discover running multi-region clusters (external + internal IP in one call)
$instances = & gcloud.cmd compute instances list --project $ProjectId --filter="name~'parcsnet-mr.*-host'" --format="csv[no-heading](name,zone,networkInterfaces[0].accessConfigs[0].natIP,networkInterfaces[0].networkIP)"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($instances)) {
  throw "No multi-region host instances found."
}

$hosts = @()
foreach ($line in ($instances -split "`n")) {
  $line = $line.Trim()
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line -split ","
  if ($parts.Count -ge 3) {
    $internalIp = if ($parts.Count -ge 4 -and $parts[3] -match "^\d+\.\d+\.\d+\.\d+$") { $parts[3] } else { $null }
    $hosts += [pscustomobject]@{
      name = $parts[0]
      zone = $parts[1]
      ip   = $parts[2]
      internalIp = $internalIp
    }
  }
}

$totalFound = $hosts.Count
if ($MaxRegions -gt 0 -and $totalFound -gt $MaxRegions) {
  $hosts = $hosts[0..($MaxRegions - 1)]
  Write-Host "Using $MaxRegions of $totalFound regional clusters (-Regions limit)"
} else {
  Write-Host "Found $totalFound regional clusters"
}

# Calculate total tiles
$inputLines = Get-Content $InputFile | Where-Object { $_.Trim() -ne "" }
$heightM = [double]$inputLines[2]
$widthM = [double]$inputLines[3]
$numRows = [Math]::Max(1, [int]($heightM / 100))
$numCols = [Math]::Max(1, [int]($widthM / 100))
$totalTiles = $numRows * $numCols

Write-Host "Total tiles: $totalTiles"
Write-Host "Splitting across $($hosts.Count) regions"

# Calculate tile ranges
$tilesPerRegion = [Math]::Ceiling($totalTiles / $hosts.Count)
$assignments = @()
$idx = 0
foreach ($h in $hosts) {
  $start = $idx
  $end = [Math]::Min($idx + $tilesPerRegion, $totalTiles)
  $assignments += @{
    host = $h
    start = $start
    end = $end
    count = $end - $start
  }
  $idx = $end
}

Write-Host ""
Write-Host "Tile assignments:"
foreach ($a in $assignments) {
  $region = ($a.host.name -replace "parcsnet-mr-", "" -replace "-host", "")
  Write-Host "  ${region}: tiles [$($a.start), $($a.end)) = $($a.count) tiles"
}

# Prepare output
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$baseDir = Join-Path (Get-Location).Path $OutputDir
if (-not (Test-Path $baseDir)) { New-Item -ItemType Directory -Force -Path $baseDir | Out-Null }
$outDir = Join-Path $baseDir ("federated_split_" + $stamp)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "Output: $outDir"

$publishDir = ".\csharp\ParcsNetMapsStitcher\bin\Release\netcoreapp2.1\linux-x64\publish"
$sshKey = "C:\Users\Pavel\.ssh\google_compute_engine"
$inputName = [System.IO.Path]::GetFileName($InputFile)
$sshOpts = "-i `"$sshKey`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=60 -o LogLevel=ERROR"

# Check if Docker image exists on first host (assume all hosts are in sync)
$firstHost = $hosts[0]
Write-Host ""
Write-Host "Checking if runner image exists on $($firstHost.name)..."
$checkCmd = "ssh.exe $sshOpts Pavel@$($firstHost.ip) `"docker images -q parcsnet-maps-runner:latest 2>/dev/null`""
$checkOut = cmd /c $checkCmd 2>&1
$checkOutput = ($checkOut -join " ")
# Extract Docker image ID (12 hex chars) from output (may contain SSH warnings)
$imageExists = $false
if ($checkOutput -match "([a-f0-9]{12})") {
  $imageId = $Matches[1]
  $imageExists = $true
}

if ($imageExists -and -not $ForceRebuild) {
  Write-Host "  Runner image already exists (ID: $imageId). Skipping upload/build."
  Write-Host "  (Use -ForceRebuild to update code)"
} else {
  if ($ForceRebuild) {
    Write-Host "  ForceRebuild requested. Rebuilding..."
  } else {
    Write-Host "  Runner image not found. Will upload and build."
  }
  Write-Host "Uploading and building Docker image on each host..."
  
  foreach ($h in $hosts) {
    $region = ($h.name -replace "parcsnet-mr-", "" -replace "-host", "")
    Write-Host "  Building on $region ($($h.ip))..."
    
    # Upload new publish folder to bin/ (Dockerfile expects ./bin/)
    Write-Host "    Uploading..."
    $scpCmd = "scp.exe $sshOpts -r `"$publishDir\*`" `"Pavel@$($h.ip):/home/Pavel/parcsnet_run/bin/`""
    $scpOut = cmd /c $scpCmd 2>&1
    
    # Build Docker image
    $buildCmd = "cd /home/Pavel/parcsnet_run && docker build -t parcsnet-maps-runner:latest -f Dockerfile ."
    $sshCmd = "ssh.exe $sshOpts Pavel@$($h.ip) `"$buildCmd`""
    Write-Host "    Building Docker..."
    $buildOut = cmd /c $sshCmd 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host "    Build output: $($buildOut | Select-Object -Last 5)"
    } else {
      Write-Host "    Done."
    }
  }
}

Write-Host ""
Write-Host "Starting PARALLEL federated downloads..."
Write-Host "Execution settings: pointsPerRegion=$PointsPerRegion, concurrency=$Concurrency, optimized=$($Optimized.IsPresent)"

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

# Pre-fetch any missing internal IPs (batch; avoids sequential calls in loop)
foreach ($h in $hosts) {
  if (-not $h.internalIp) {
    $out = & gcloud.cmd compute instances describe $h.name --project $ProjectId --zone $h.zone --format="get(networkInterfaces[0].networkIP)" 2>&1
    $h.internalIp = ($out | Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" } | Select-Object -First 1)
  }
}

# Launch jobs (all internal IPs ready; no sequential gcloud in loop)
$jobs = @()
foreach ($a in $assignments) {
  $h = $a.host
  $region = ($h.name -replace "parcsnet-mr-", "" -replace "-host", "")
  $logFile = [System.IO.Path]::GetFullPath((Join-Path $outDir "log_${region}.txt"))
  $hostInternalIp = $h.internalIp

  Write-Host "Launching $region (tiles $($a.start)-$($a.end), host IP: $hostInternalIp, optimized=$($Optimized.IsPresent))..."
  
  $optArg = if ($Optimized) { "--optimized" } else { "" }
  
  $job = Start-Job -Name $region -ArgumentList $h.ip, $sshKey, $PointsPerRegion, $Concurrency, $logFile, $hostInternalIp, $inputName, $a.start, $a.end, $optArg -ScriptBlock {
    param($ip, $key, $points, $concurrency, $logPath, $hostIntIp, $inputFileName, $tileStart, $tileEnd, $optFlag)
    
    $sshOpts = "-i `"$key`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=120 -o ServerAliveInterval=30 -o LogLevel=ERROR"
    
    $dockerCmd = "docker run --rm --network host -e PARCS_POINT_START_DELAY_MS=0 -v /home/Pavel/parcsnet_run/out:/out parcsnet-maps-runner:latest --serverip $hostIntIp --user parcs-user --input /app/tests/$inputFileName --output /out/tiles.txt --points $points --downloadonly --tilestart $tileStart --tileend $tileEnd --concurrency $concurrency $optFlag"
    $sshFullCmd = "ssh.exe $sshOpts Pavel@$ip `"$dockerCmd`""
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = cmd /c $sshFullCmd 2>&1
    $sw.Stop()
    
    $logDir = [System.IO.Path]::GetDirectoryName($logPath)
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $output | Out-File -FilePath $logPath -Encoding UTF8
    
    $downloadTime = 0
    foreach ($line in $output) {
      if ($line -match "Download phase:\s*([\d.]+)s") {
        $downloadTime = [double]$Matches[1]
      }
    }
    
    return @{
      elapsed = $sw.Elapsed.TotalSeconds
      download = $downloadTime
      output = ($output -join "`n")
    }
  }
  
  $jobs += @{ job = $job; region = $region; tiles = $a.count }
}

Write-Host ""
Write-Host "Waiting for all regions..."

$results = @()
foreach ($j in $jobs) {
  $result = Receive-Job -Job $j.job -Wait
  Remove-Job -Job $j.job
  
  $results += [pscustomobject]@{
    region = $j.region
    tiles = $j.tiles
    download_s = $result.download
    elapsed_s = $result.elapsed
  }
  
  Write-Host "$($j.region): $($j.tiles) tiles in $($result.download.ToString('F3'))s"
}

$swTotal.Stop()

Write-Host ""
Write-Host "============================================"
Write-Host "=== FEDERATED SPLIT EXPERIMENT COMPLETE ==="
Write-Host "============================================"
Write-Host ""
Write-Host "Wall-clock time: $($swTotal.Elapsed.TotalSeconds.ToString('F3'))s"
Write-Host ""

$maxDownload = ($results | Measure-Object -Property download_s -Maximum).Maximum
$sumDownload = ($results | Measure-Object -Property download_s -Sum).Sum

Write-Host "Per-region times (each downloading ~$tilesPerRegion tiles):"
foreach ($r in $results) {
  Write-Host "  $($r.region): $($r.download_s.ToString('F3'))s ($($r.tiles) tiles)"
}

Write-Host ""
# Baseline: 1 point downloading all 144 tiles (~60s, no cache)
# With federation: max region time (since parallel) = effective download time
$baseline = 60.0
$speedup = $baseline / $maxDownload

Write-Host "Speedup vs 1-point baseline (~${baseline}s for $totalTiles tiles):"
Write-Host "  Download speedup: $($speedup.ToString('F2'))x"
Write-Host ""
Write-Host "Results saved to: $outDir"

# Save CSV
$csvFile = Join-Path $outDir "results.csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation

@"
Federated Split Experiment
==========================
Total tiles: $totalTiles
Regions: $($hosts.Count)
Tiles per region: ~$tilesPerRegion
Points per region: $PointsPerRegion

Wall-clock time: $($swTotal.Elapsed.TotalSeconds)s
Max region download: ${maxDownload}s

Speedup vs 1-point baseline (~60s): ${speedup}x
"@ | Out-File -FilePath (Join-Path $outDir "summary.txt") -Encoding UTF8
