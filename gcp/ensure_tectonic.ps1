param(
  # Directory where tectonic.exe will be installed (repo-local by default)
  [string]$OutDir = (Join-Path $PSScriptRoot "..\\.tools\\tectonic")
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host $msg }

$outDirFull = (Resolve-Path (Split-Path -Parent $OutDir) -ErrorAction SilentlyContinue)
if (-not $outDirFull) {
  $outDirFull = Resolve-Path (Join-Path $PSScriptRoot "..")
}
$outDirFull = Join-Path $outDirFull.Path (Split-Path $OutDir -Leaf)

New-Item -ItemType Directory -Force -Path $outDirFull | Out-Null

$tectonicExe = Join-Path $outDirFull "tectonic.exe"
if (Test-Path $tectonicExe) {
  Write-Info "tectonic already present: $tectonicExe"
  exit 0
}

# Ensure TLS 1.2 on older PowerShell / .NET
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$headers = @{
  "User-Agent" = "gcp-project-run_all"
  "Accept"     = "application/vnd.github+json"
}

$api = "https://api.github.com/repos/tectonic-typesetting/tectonic/releases/latest"
Write-Info "Fetching latest Tectonic release metadata..."
$rel = Invoke-RestMethod -Uri $api -Headers $headers

$asset = $rel.assets | Where-Object { $_.name -like "*x86_64-pc-windows-msvc*.zip" } | Select-Object -First 1
if (-not $asset) {
  $names = @($rel.assets | Select-Object -ExpandProperty name)
  throw "Could not find Windows (MSVC) x64 asset in latest release. Assets: $($names -join ', ')"
}

$zipUrl = [string]$asset.browser_download_url
$zipPath = Join-Path $outDirFull "tectonic.zip"
$extractDir = Join-Path $outDirFull "extract"

Write-Info "Downloading: $($asset.name)"
Invoke-WebRequest -Uri $zipUrl -Headers $headers -OutFile $zipPath

if (Test-Path $extractDir) {
  Remove-Item -Recurse -Force $extractDir
}
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

Write-Info "Extracting..."
Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

$found = Get-ChildItem -Path $extractDir -Recurse -Filter "tectonic.exe" | Select-Object -First 1
if (-not $found) {
  throw "tectonic.exe not found after extraction."
}

Copy-Item -Force $found.FullName $tectonicExe

Write-Info "Installed: $tectonicExe"

