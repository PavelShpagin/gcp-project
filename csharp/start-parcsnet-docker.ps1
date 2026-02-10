$ErrorActionPreference = "Stop"

param(
  [int]$Daemons = 7,
  [string]$HostServerImage = "andriikhavro/parcshostserver:windowsservercore-1709",
  [string]$DaemonImage = "andriikhavro/parcsdaemon:windowsservercore-1709"
)

function Get-GMapsKey {
  $k = $env:GMAPS_KEY
  if ([string]::IsNullOrWhiteSpace($k)) { $k = $env:GOOGLE_MAPS_API_KEY }

  if (-not [string]::IsNullOrWhiteSpace($k)) { return $k }

  $repoRoot = Split-Path $PSScriptRoot -Parent
  $envPath = Join-Path $repoRoot ".env"
  if (-not (Test-Path $envPath)) { return $null }

  $lines = Get-Content $envPath -ErrorAction SilentlyContinue
  foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t.StartsWith("#") -or $t.Length -eq 0) { continue }
    $parts = $t.Split("=", 2)
    if ($parts.Length -ne 2) { continue }
    $name = $parts[0].Trim()
    $val = $parts[1].Trim().Trim('"')
    if ($name -eq "GMAPS_KEY" -and -not [string]::IsNullOrWhiteSpace($val)) { return $val }
    if ($name -eq "GOOGLE_MAPS_API_KEY" -and -not [string]::IsNullOrWhiteSpace($val)) { $k = $val }
  }

  return $k
}

Write-Host "Starting PARCS.NET HostServer container..."

docker run -d --name=hostserver --rm $HostServerImage | Out-Null

$hostServerIp = (docker inspect -f '{{.NetworkSettings.Networks.nat.IPAddress}}' hostserver) | Out-String
if (-not $hostServerIp) {
  throw "HostServer hasn't started successfully."
}
$hostServerIp = $hostServerIp.Trim()

Write-Host "HostServer IP (NAT): $hostServerIp"
Write-Host "Starting $Daemons daemon container(s)..."

$gmapsKey = Get-GMapsKey
$throttle = $env:GMAPS_THROTTLE_SECONDS

for ($i = 1; $i -le $Daemons; $i++) {
  $name = "daemon$i"

  $envArgs = @(
    "-e", "PARCS_HOST_SERVER_IP_ADDRESS=$hostServerIp"
  )

  if ($gmapsKey) {
    $envArgs += @("-e", "GMAPS_KEY=$gmapsKey")
  } else {
    Write-Warning "GMAPS_KEY is not set; live runs will fail on daemons. Set GMAPS_KEY (or GOOGLE_MAPS_API_KEY)."
  }

  if ($throttle) {
    $envArgs += @("-e", "GMAPS_THROTTLE_SECONDS=$throttle")
  }

  docker run -d --name=$name --rm @envArgs $DaemonImage | Out-Null
}

Write-Host ""
Write-Host "Containers:"
docker ps

Write-Host ""
Write-Host "Use this HostServer IP when running the module:"
Write-Host "  --serverip $hostServerIp"

