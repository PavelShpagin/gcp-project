$ErrorActionPreference = "Stop"

param(
  [Parameter(Mandatory = $true)]
  [string]$ServerIp,

  [int[]]$Points = @(1, 4, 7),

  [string[]]$Inputs = @(
    "tests\\small_city_block.txt",
    "tests\\medium_district.txt",
    "tests\\large_metro.txt"
  ),

  [string]$Exe = "csharp\\ParcsNetMapsStitcher\\bin\\Release\\net48\\ParcsNetMapsStitcher.exe",

  [switch]$DryRun
)

function Parse-Seconds([string]$content, [string]$label) {
  $m = [regex]::Match($content, [regex]::Escape($label) + "\\s*(\\d+\\.?\\d*)s")
  if ($m.Success) { return [double]$m.Groups[1].Value }
  return $null
}

if (-not (Test-Path $Exe)) {
  Write-Host "Executable not found; building..."
  dotnet build .\\csharp\\ParcsNetMapsStitcher.sln -c Release | Out-Null
}

if (-not (Test-Path $Exe)) {
  throw "Still cannot find module exe at: $Exe"
}

if (-not $DryRun) {
  $hasKey = -not [string]::IsNullOrWhiteSpace($env:GMAPS_KEY) -or -not [string]::IsNullOrWhiteSpace($env:GOOGLE_MAPS_API_KEY)
  if (-not $hasKey) {
    Write-Warning "GMAPS_KEY is not set in this shell. If your daemons also don't have it, live runs will fail."
  }
}

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$outDir = Join-Path "csharp" ("results_" + $stamp)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$rows = @()

foreach ($input in $Inputs) {
  foreach ($p in $Points) {
    $name = [IO.Path]::GetFileNameWithoutExtension($input)
    $outFile = Join-Path $outDir ("out_{0}_{1}.txt" -f $name, $p)
    $logFile = Join-Path $outDir ("log_{0}_{1}.txt" -f $name, $p)

    $args = @(
      "--serverip", $ServerIp,
      "--input", $input,
      "--output", $outFile,
      "--points", "$p"
    )
    if ($DryRun) { $args += "--dryrun" }

    Write-Host ("Running {0} with p={1}..." -f $input, $p)

    # Capture console output to a log file for parsing.
    & $Exe @args 2>&1 | Tee-Object -FilePath $logFile | Out-Host

    $content = Get-Content $logFile -Raw
    $download = Parse-Seconds $content "Download phase:"
    $mosaic = Parse-Seconds $content "Mosaic phase:"
    $total = Parse-Seconds $content "Total time:"

    $rows += [pscustomobject]@{
      dataset = $name
      points = $p
      download_s = $download
      mosaic_s = $mosaic
      total_s = $total
      output_file = $outFile
      log_file = $logFile
    }
  }
}

$csvPath = Join-Path $outDir "results.csv"
$rows | Export-Csv -NoTypeInformation -Path $csvPath

Write-Host ""
Write-Host "Saved results to: $csvPath"

