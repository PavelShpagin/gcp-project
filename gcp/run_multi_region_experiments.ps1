param(
  [string]$ProjectId = "maps-demo-486815",

  # Targets as array of hashtables: @{ region="us-central1"; zone="us-central1-a" }
  [hashtable[]]$Targets = @(
    @{ region = "us-east1"; zones = @("us-east1-c", "us-east1-b", "us-east1-d") },
    @{ region = "us-west1"; zones = @("us-west1-a", "us-west1-b", "us-west1-c") },
    @{ region = "europe-west1"; zones = @("europe-west1-b", "europe-west1-c", "europe-west1-d") }
  ),

  [int]$DaemonsPerRegion = 3,
  [int[]]$Points = @(1, 3),

  [string]$MachineTypeHost = "n1-standard-1",
  [string]$MachineTypeDaemon = "n1-standard-1",

  [string[]]$Inputs = @(
    "tests\small_city_block.txt",
    "tests\medium_district.txt"
  ),

  [string]$ClusterNamePrefix = "parcsnet-mr",

  [switch]$SkipDockerBuild,
  [switch]$DownloadOutputs,
  [switch]$AggregateOnly,
  [switch]$Cleanup
)

$ErrorActionPreference = "Stop"

Write-Host "Multi-region PARCS.NET run (costs increase with region count)."
Write-Host ""

function Get-InUseAddressesQuota([string]$region, [string]$projectId) {
  $json = & gcloud.cmd compute regions describe $region --project $projectId --format=json
  if ($LASTEXITCODE -ne 0) {
    throw "gcloud compute regions describe failed for $region."
  }

  $obj = $json | ConvertFrom-Json
  $q = $obj.quotas | Where-Object { $_.metric -eq "IN_USE_ADDRESSES" } | Select-Object -First 1
  if (-not $q) {
    throw "IN_USE_ADDRESSES quota not found for region $region."
  }

  return [pscustomobject]@{
    limit = [int]$q.limit
    usage = [int]$q.usage
  }
}

function Get-GlobalCpuQuota([string]$projectId) {
  $json = & gcloud.cmd compute project-info describe --project $projectId --format=json
  if ($LASTEXITCODE -ne 0) {
    throw "gcloud compute project-info describe failed."
  }

  $obj = $json | ConvertFrom-Json
  $q = $obj.quotas | Where-Object { $_.metric -eq "CPUS_ALL_REGIONS" } | Select-Object -First 1
  if (-not $q) {
    throw "CPUS_ALL_REGIONS quota not found."
  }

  return [pscustomobject]@{
    limit = [int]$q.limit
    usage = [int]$q.usage
  }
}

function Get-MachineTypeCpus([string]$machineType, [string]$zone, [string]$projectId) {
  $cpus = & gcloud.cmd compute machine-types describe $machineType --zone $zone --project $projectId --format="get(guestCpus)"
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cpus)) {
    throw "Failed to resolve guestCpus for $machineType in $zone."
  }
  return [int]$cpus.Trim()
}

if (-not $AggregateOnly) {
  Write-Host "Publishing runner once..."
  dotnet publish .\csharp\ParcsNetMapsStitcher\ParcsNetMapsStitcher.csproj -c Release -f netcoreapp2.1 -r linux-x64 --self-contained true
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit code $LASTEXITCODE)." }

  # IMPORTANT: keep this as a relative path (Windows absolute paths include ':' which breaks scp syntax).
  $publishDir = ".\csharp\ParcsNetMapsStitcher\bin\Release\netcoreapp2.1\linux-x64\publish"
  if (-not (Test-Path $publishDir)) {
    throw "Publish output not found: $publishDir"
  }
}

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$multiOutDir = Join-Path "csharp" ("results_multi_region_" + $stamp)
New-Item -ItemType Directory -Force -Path $multiOutDir | Out-Null

$regionResults = @()
$cpuQuota = Get-GlobalCpuQuota $ProjectId
$plannedCpuUsage = $cpuQuota.usage

foreach ($t in $Targets) {
  $region = $t.region
  $zonesToTry = @()
  if ($t.zones) { $zonesToTry = @($t.zones) }
  if ($t.zone) { $zonesToTry = @($t.zone) }
  if ([string]::IsNullOrWhiteSpace($region) -or $zonesToTry.Count -eq 0) {
    throw "Each target must include 'region' and at least one zone."
  }

  $clusterName = "$ClusterNamePrefix-$region"
  $hostInstance = "$clusterName-host"

  Write-Host ""
  Write-Host "== Region: $region =="

  if ($AggregateOnly) {
    $regionDir = Get-ChildItem "csharp" -Directory |
      Where-Object { $_.Name -like ("results_gcp_*_" + $region) } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($regionDir) {
      $regionResults += $regionDir.FullName
    } else {
      Write-Host "No existing results for region: $region"
    }
    continue
  }

  $quota = Get-InUseAddressesQuota $region $ProjectId
  $needed = 1 + $DaemonsPerRegion
  if (($quota.usage + $needed) -gt $quota.limit) {
    Write-Host "Skipping ${region}: IN_USE_ADDRESSES $($quota.usage)/$($quota.limit), need $needed"
    continue
  }

  $selectedZone = $null
  foreach ($zone in $zonesToTry) {
    $hostCpus = Get-MachineTypeCpus $MachineTypeHost $zone $ProjectId
    $daemonCpus = Get-MachineTypeCpus $MachineTypeDaemon $zone $ProjectId
    $cpuNeeded = $hostCpus + ($daemonCpus * $DaemonsPerRegion)
    if (($plannedCpuUsage + $cpuNeeded) -gt $cpuQuota.limit) {
      Write-Host "Skipping ${region} zone ${zone}: CPUS_ALL_REGIONS $plannedCpuUsage/$($cpuQuota.limit), need $cpuNeeded"
      continue
    }

    Write-Host "Bringing up cluster: $clusterName (daemons=$DaemonsPerRegion) in $zone"
    $clusterCmd = @(
      "powershell -NoProfile -ExecutionPolicy Bypass -File",
      "`"$PSScriptRoot\parcsnet_cluster.ps1`"",
      "-Action", "up",
      "-ProjectId", $ProjectId,
      "-Zone", $zone,
      "-ClusterName", $clusterName,
      "-Daemons", $DaemonsPerRegion,
      "-MachineTypeHost", $MachineTypeHost,
      "-MachineTypeDaemon", $MachineTypeDaemon
    ) -join " "

    $oldErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $clusterOut = cmd /c $clusterCmd 2>&1
    $ErrorActionPreference = $oldErr
    $clusterOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
      $msg = ($clusterOut | Out-String)
      if ($msg -match "does not have enough resources available") {
        Write-Host "Zone $zone lacks capacity, trying next..."
        continue
      }
      throw "parcsnet_cluster.ps1 failed for zone $zone."
    }

    $selectedZone = $zone
    $plannedCpuUsage += $cpuNeeded
    break
  }

  if (-not $selectedZone) {
    Write-Host "Skipping ${region}: no zone had capacity."
    continue
  }

  $pointsForRegion = @($Points | Where-Object { $_ -le $DaemonsPerRegion })
  $skippedPoints = @($Points | Where-Object { $_ -gt $DaemonsPerRegion })
  if ($skippedPoints.Count -gt 0) {
    Write-Host "Skipping points > ${DaemonsPerRegion}: $($skippedPoints -join ', ')"
  }
  if ($pointsForRegion.Count -eq 0) {
    throw "No points <= $DaemonsPerRegion. Adjust -Points or -DaemonsPerRegion."
  }

  Write-Host "Running experiments in $region with points: $($pointsForRegion -join ', ')"

  & "$PSScriptRoot\run_experiments_gcp.ps1" `
    -ProjectId $ProjectId `
    -Zone $selectedZone `
    -HostInstance $hostInstance `
    -Inputs $Inputs `
    -Points $pointsForRegion `
    -SkipDockerBuild:$SkipDockerBuild `
    -SkipPublish `
    -PublishDir $publishDir `
    -DownloadOutputs:$DownloadOutputs `
    -RegionLabel $region

  $regionDir = Get-ChildItem "csharp" -Directory |
    Where-Object { $_.Name -like ("results_gcp_*_" + $region) } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $regionDir) {
    throw "Could not find results directory for region: $region"
  }

  $regionResults += $regionDir.FullName

  if ($Cleanup) {
    Write-Host "Cleaning up cluster: $clusterName"
    & "$PSScriptRoot\parcsnet_cluster.ps1" `
      -Action down `
      -ProjectId $ProjectId `
      -Zone $zone `
      -ClusterName $clusterName `
      -Daemons $DaemonsPerRegion
  }
}

Write-Host ""
Write-Host "Aggregating results..."

$allRows = @()
foreach ($dir in $regionResults) {
  $csv = Join-Path $dir "results.csv"
  if (-not (Test-Path $csv)) { throw "Missing results.csv: $csv" }

  $rows = Import-Csv $csv
  foreach ($r in $rows) {
    if (-not $r.region) {
      $r | Add-Member -NotePropertyName region -NotePropertyValue "unknown"
    }
    $allRows += $r
  }
}

$aggCsv = Join-Path $multiOutDir "results.csv"
$allRows | Export-Csv -NoTypeInformation -Path $aggCsv

$summary = @()
$groups = $allRows | Group-Object dataset, points
foreach ($g in $groups) {
  $items = $g.Group
  $avgDownload = ($items | Measure-Object download_s -Average).Average
  $avgMosaic = ($items | Measure-Object mosaic_s -Average).Average
  $avgTotal = ($items | Measure-Object total_s -Average).Average

  $dataset = $items[0].dataset
  $pointValue = [int]$items[0].points

  $summary += [pscustomobject]@{
    dataset = $dataset
    points = $pointValue
    avg_download_s = [math]::Round($avgDownload, 3)
    avg_mosaic_s = [math]::Round($avgMosaic, 3)
    avg_total_s = [math]::Round($avgTotal, 3)
  }
}

$summary = $summary | Sort-Object dataset, points

foreach ($d in ($summary | Select-Object -ExpandProperty dataset -Unique)) {
  $base = ($summary | Where-Object { $_.dataset -eq $d -and $_.points -eq 1 })
  if ($base) {
    foreach ($row in ($summary | Where-Object { $_.dataset -eq $d })) {
      $row | Add-Member -NotePropertyName speedup_download -NotePropertyValue ([math]::Round(($base.avg_download_s / $row.avg_download_s), 3))
      $row | Add-Member -NotePropertyName speedup_total -NotePropertyValue ([math]::Round(($base.avg_total_s / $row.avg_total_s), 3))
    }
  }
}

$summaryCsv = Join-Path $multiOutDir "summary.csv"
$summary | Export-Csv -NoTypeInformation -Path $summaryCsv

Write-Host ""
Write-Host "Multi-region results saved:"
Write-Host "  $aggCsv"
Write-Host "  $summaryCsv"
