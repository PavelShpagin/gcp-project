param(
    [string]$ProjectId = "maps-demo-486815",
    [string]$ClusterNamePrefix = "parcsnet-mr"
)

$ErrorActionPreference = "Continue"

Write-Host "CLEANUP: Removing all regional PARCS.NET clusters..."
Write-Host "=================================================="

# Get all instances matching the prefix
$instances = & gcloud.cmd compute instances list --project $ProjectId --filter="name~'$ClusterNamePrefix.*'" --format="csv[no-heading](name,zone)"

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($instances)) {
    Write-Host "No matching instances found. Cleanup complete."
    exit 0
}

$clusters = @{}

foreach ($line in ($instances -split "`n")) {
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    
    $parts = $line -split ","
    $name = $parts[0]
    $zone = $parts[1]
    
    # Extract cluster name (remove -host or -daemon-X)
    if ($name -match "^(.*)-(host|daemon-\d+)$") {
        $clusterName = $Matches[1]
        
        if (-not $clusters.ContainsKey($clusterName)) {
            $clusters[$clusterName] = $zone
        }
    }
}

foreach ($cluster in $clusters.Keys) {
    $zone = $clusters[$cluster]
    Write-Host "Removing cluster: $cluster in $zone..."
    
    # Run the cluster script in 'down' mode
    # Assuming 3 daemons as default, but 'down' command tries to delete commonly named instances anyway
    & "$PSScriptRoot\parcsnet_cluster.ps1" -Action down -ProjectId $ProjectId -Zone $zone -ClusterName $cluster -Daemons 10 -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Cleanup process finished."
