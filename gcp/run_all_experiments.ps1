param(
  [string]$ProjectId = "maps-demo-486815",
  [string]$Zone = "us-central1-a",
  [string]$HostInstance = "parcsnet-host",
  [string[]]$Inputs = @(
    "tests\small_city_block.txt",
    "tests\medium_district.txt"
  ),
  [int[]]$Points = @(1, 4, 7),
  [switch]$SkipDockerBuild
)

$ErrorActionPreference = "Stop"

Write-Host "Running ALL experiments"
Write-Host ""

& "$PSScriptRoot\run_experiments_gcp.ps1" `
  -ProjectId $ProjectId `
  -Zone $Zone `
  -HostInstance $HostInstance `
  -Inputs $Inputs `
  -Points $Points `
  -SkipDockerBuild:$SkipDockerBuild `
  -DownloadOutputs

Write-Host ""
Write-Host "All experiments completed!"
