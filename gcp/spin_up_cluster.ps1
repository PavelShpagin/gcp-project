param(
  [int]$Daemons = 7,
  [string]$ProjectId = "maps-demo-486815",
  [string]$Zone = "us-central1-a",
  [string]$ClusterName = "parcsnet",
  [bool]$DaemonExternalIp = $true
)

$ErrorActionPreference = "Stop"

Write-Host "Spinning up PARCS.NET cluster with $Daemons daemons..."
Write-Host ""

& "$PSScriptRoot\parcsnet_cluster.ps1" `
  -Action up `
  -ProjectId $ProjectId `
  -Zone $Zone `
  -ClusterName $ClusterName `
  -Daemons $Daemons `
  -DaemonExternalIp $DaemonExternalIp

Write-Host ""
Write-Host "Cluster is ready. Run experiments with:"
Write-Host "  .\gcp\run_all_experiments.ps1"
