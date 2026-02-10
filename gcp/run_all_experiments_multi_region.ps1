param(
  [string]$ProjectId = "maps-demo-486815",
  [string[]]$Zones = @("us-central1-a", "us-east1-b"),
  [string]$ClusterBaseName = "parcsnet",
  [int]$DaemonsPerCluster = 3,
  [string]$MachineTypeHost = "e2-small",
  [string]$MachineTypeDaemon = "e2-small",
  [switch]$SkipDockerBuild,
  [switch]$SkipClusterCreate,
  [switch]$Parallel
)

$ErrorActionPreference = "Stop"

Write-Host "Running ALL experiments (small/medium, points=1/4/7) across multiple regions"
Write-Host ""

& "$PSScriptRoot\run_multi_region_experiments.ps1" `
  -ProjectId $ProjectId `
  -Zones $Zones `
  -ClusterBaseName $ClusterBaseName `
  -DaemonsPerCluster $DaemonsPerCluster `
  -MachineTypeHost $MachineTypeHost `
  -MachineTypeDaemon $MachineTypeDaemon `
  -SkipDockerBuild:$SkipDockerBuild `
  -SkipClusterCreate:$SkipClusterCreate `
  -Parallel:$Parallel

Write-Host ""
Write-Host "All multi-region experiments completed!"
