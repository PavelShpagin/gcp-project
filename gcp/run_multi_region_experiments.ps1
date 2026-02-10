param(
  [string]$ProjectId = "maps-demo-486815",

  # Targets as array of hashtables: @{ region="us-central1"; zone="us-central1-a" }
  [hashtable[]]$Targets = @(
    @{ region = "us-west1"; zones = @("us-west1-a", "us-west1-b", "us-west1-c") },
    @{ region = "europe-west1"; zones = @("europe-west1-b", "europe-west1-c", "europe-west1-d") },
    @{ region = "us-east1"; zones = @("us-east1-c", "us-east1-b", "us-east1-d") },
    @{ region = "us-central1"; zones = @("us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f") },
    @{ region = "europe-west4"; zones = @("europe-west4-a", "europe-west4-b", "europe-west4-c") },
    @{ region = "asia-east1"; zones = @("asia-east1-a", "asia-east1-b", "asia-east1-c") },
    @{ region = "asia-northeast1"; zones = @("asia-northeast1-a", "asia-northeast1-b", "asia-northeast1-c") },
    @{ region = "southamerica-east1"; zones = @("southamerica-east1-a", "southamerica-east1-b", "southamerica-east1-c") }
  ),

  [int]$DaemonsPerRegion = 1,
  [int]$TargetClusterCount = 5,
  [string]$MachineTypeHost = "n1-standard-1",
  [string]$MachineTypeDaemon = "n1-standard-1",
  [string]$ClusterNamePrefix = "parcsnet-mr",
  
  [switch]$Cleanup
)

$ErrorActionPreference = "Stop"

Write-Host "Multi-region PARCS.NET Infrastructure Setup"
Write-Host "==========================================="
Write-Host "Daemons per region: $DaemonsPerRegion"
Write-Host ""

if ($Cleanup) {
    Write-Host "Running cleanup mode..."
    foreach ($t in $Targets) {
        $region = $t.region
        $clusterName = "$ClusterNamePrefix-$region"
        
        # Try to find which zone has the cluster (simple check)
        $zones = @($t.zones)
        foreach ($z in $zones) {
            Write-Host "Checking cleanup for $clusterName in $z..."
            & "$PSScriptRoot\parcsnet_cluster.ps1" -Action down -ProjectId $ProjectId -Zone $z -ClusterName $clusterName -Daemons $DaemonsPerRegion -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Cleanup done."
    exit 0
}

# --- Quota Helper Functions ---

function Get-InUseAddressesQuota([string]$region, [string]$projectId) {
  $json = & gcloud.cmd compute regions describe $region --project $projectId --format=json
  if ($LASTEXITCODE -ne 0) { throw "gcloud compute regions describe failed for $region." }
  $obj = $json | ConvertFrom-Json
  $q = $obj.quotas | Where-Object { $_.metric -eq "IN_USE_ADDRESSES" } | Select-Object -First 1
  if (-not $q) { throw "IN_USE_ADDRESSES quota not found for region $region." }
  return [pscustomobject]@{ limit = [int]$q.limit; usage = [int]$q.usage }
}

function Get-GlobalCpuQuota([string]$projectId) {
  $json = & gcloud.cmd compute project-info describe --project $projectId --format=json
  if ($LASTEXITCODE -ne 0) { throw "gcloud compute project-info describe failed." }
  $obj = $json | ConvertFrom-Json
  $q = $obj.quotas | Where-Object { $_.metric -eq "CPUS_ALL_REGIONS" } | Select-Object -First 1
  if (-not $q) { throw "CPUS_ALL_REGIONS quota not found." }
  return [pscustomobject]@{ limit = [int]$q.limit; usage = [int]$q.usage }
}

function Get-MachineTypeCpus([string]$machineType, [string]$zone, [string]$projectId) {
  $cpus = & gcloud.cmd compute machine-types describe $machineType --zone $zone --project $projectId --format="get(guestCpus)"
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cpus)) { throw "Failed to resolve guestCpus for $machineType in $zone." }
  return [int]$cpus.Trim()
}

# --- Main Setup Loop ---

$cpuQuota = Get-GlobalCpuQuota $ProjectId
$plannedCpuUsage = $cpuQuota.usage
$activeClusters = @()

foreach ($t in $Targets) {
  if ($activeClusters.Count -ge $TargetClusterCount) {
    Write-Host "Reached target cluster count ($TargetClusterCount). Stopping setup."
    break
  }
  
  $region = $t.region
  $zonesToTry = @()
  if ($t.zones) { $zonesToTry = @($t.zones) }
  if ($t.zone) { $zonesToTry = @($t.zone) }
  
  if ([string]::IsNullOrWhiteSpace($region)) { continue }

  $clusterName = "$ClusterNamePrefix-$region"
  Write-Host ""
  Write-Host "== Region: $region =="

  # Check if cluster already exists
  $existingHost = & gcloud.cmd compute instances describe "$clusterName-host" --zone "$($t.zones[0])" --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>$null
  # Try checking other zones if first fails? Or simpler: list instances matching name
  $checkCmd = "gcloud.cmd compute instances list --filter=`"name~'^$clusterName-host$'`" --format=`"csv[no-heading](name,zone,networkInterfaces[0].accessConfigs[0].natIP)`""
  $checkOut = Invoke-Expression $checkCmd
  
  if (-not [string]::IsNullOrWhiteSpace($checkOut)) {
      $parts = $checkOut -split ","
      $foundName = $parts[0]
      $foundZone = $parts[1]
      $foundIp = $parts[2]
      
      Write-Host "Cluster $clusterName already exists in $foundZone. reusing."
      $activeClusters += [pscustomobject]@{
          Region = $region
          Zone = $foundZone
          ClusterName = $clusterName
          HostIP = $foundIp
      }
      continue
  }

  # Check IP quota
  $quota = Get-InUseAddressesQuota $region $ProjectId
  $needed = 1 + $DaemonsPerRegion
  if (($quota.usage + $needed) -gt $quota.limit) {
    Write-Host "Skipping ${region}: IN_USE_ADDRESSES $($quota.usage)/$($quota.limit), need $needed"
    continue
  }

  $selectedZone = $null
  
  foreach ($zone in $zonesToTry) {
    # Check CPU quota
    $hostCpus = Get-MachineTypeCpus $MachineTypeHost $zone $ProjectId
    $daemonCpus = Get-MachineTypeCpus $MachineTypeDaemon $zone $ProjectId
    $cpuNeeded = $hostCpus + ($daemonCpus * $DaemonsPerRegion)
    
    if (($plannedCpuUsage + $cpuNeeded) -gt $cpuQuota.limit) {
      Write-Host "Skipping ${region} zone ${zone}: CPUS_ALL_REGIONS $plannedCpuUsage/$($cpuQuota.limit), need $cpuNeeded"
      continue
    }

    Write-Host "Bringing up cluster: $clusterName (daemons=$DaemonsPerRegion) in $zone"
    
    # Run cluster script directly
    $clusterScript = "$PSScriptRoot\parcsnet_cluster.ps1"
    $clusterArgs = @{
      Action = "up"
      ProjectId = $ProjectId
      Zone = $zone
      ClusterName = $clusterName
      Daemons = $DaemonsPerRegion
      MachineTypeHost = $MachineTypeHost
      MachineTypeDaemon = $MachineTypeDaemon
    }
    
    $clusterFailed = $false
    $capacityError = $false
    
    try {
      & $clusterScript @clusterArgs
    } catch {
      $clusterFailed = $true
      if ($_.Exception.Message -match "does not have enough resources available") {
        $capacityError = $true
      } else {
        Write-Error $_
      }
    }
    
    if ($clusterFailed) {
      if ($capacityError) {
        Write-Host "Zone $zone lacks capacity, trying next..."
        continue
      }
      throw "parcsnet_cluster.ps1 failed for zone $zone."
    }

    $selectedZone = $zone
    $plannedCpuUsage += $cpuNeeded
    
    # Get Host IP for summary
    $hostIp = & gcloud.cmd compute instances describe "$clusterName-host" --zone $zone --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
    $activeClusters += [pscustomobject]@{
        Region = $region
        Zone = $zone
        ClusterName = $clusterName
        HostIP = $hostIp
    }
    
    break # Success, move to next region
  }

  if (-not $selectedZone) {
    Write-Host "Skipping ${region}: no zone had capacity."
  }
}

Write-Host ""
Write-Host "Setup Complete."
Write-Host "Active Clusters:"
$activeClusters | Format-Table -AutoSize

Write-Host ""
Write-Host "Now run: .\gcp\run_federated_split.ps1 -InputFile tests\medium_district.txt"
