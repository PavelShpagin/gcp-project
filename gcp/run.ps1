param(
    [switch]$Cleanup,
    [switch]$Setup,
    [switch]$Run,
    [int]$Regions = 1,
    [int]$PointsPerRegion = 1,
    [int]$Concurrency = 1,
    [string]$InputFile = "tests\medium_district.txt",
    [string]$ProjectId = "maps-demo-486815",
    [switch]$ForceRebuild,
    [switch]$Optimized
)

$ErrorActionPreference = "Stop"

if (-not ($Cleanup -or $Setup -or $Run)) {
    Write-Host "Usage: .\gcp\run.ps1 [-Cleanup] [-Setup] [-Run] ..."
    Write-Host "  Baseline (sequential): .\gcp\run.ps1 -Run -Regions 1 -PointsPerRegion 1 -Concurrency 1"
    Write-Host "  Optimized parallel:    .\gcp\run.ps1 -Run -Regions 3 -PointsPerRegion 3 -Concurrency 16 -Optimized"
    Write-Host "  Full cycle: .\gcp\run.ps1 -Cleanup -Setup -Run -Regions 4 -PointsPerRegion 3 -Concurrency 16 -Optimized"
    return
}

if ($Cleanup) {
    Write-Host "`n>>> CLEANUP <<<" -ForegroundColor Cyan
    & "$PSScriptRoot\cleanup_regions.ps1" -ProjectId $ProjectId
    Write-Host "Waiting 30s..."
    Start-Sleep -Seconds 30
}

if ($Setup) {
    $daemons = [Math]::Min(3, [Math]::Max(1, $PointsPerRegion))
    Write-Host "`n>>> SETUP (Regions=$Regions, Daemons/Region=$daemons) <<<" -ForegroundColor Cyan
    & "$PSScriptRoot\run_multi_region_experiments.ps1" -ProjectId $ProjectId -TargetClusterCount $Regions -DaemonsPerRegion $daemons
    if ($LASTEXITCODE -ne 0) { Write-Warning "Setup had warnings/errors." }
    Write-Host "Waiting 30s..."
    Start-Sleep -Seconds 30
}

if ($Run) {
    Write-Host "`n>>> RUN (Points/Reg=$PointsPerRegion, Threads=$Concurrency) <<<" -ForegroundColor Cyan

    if ($ForceRebuild) {
        Write-Host "Publishing C#..."
        dotnet publish "$PSScriptRoot\..\csharp\ParcsNetMapsStitcher\ParcsNetMapsStitcher.csproj" -c Release -f netcoreapp2.1 -r linux-x64 --self-contained true
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }
    }

    & "$PSScriptRoot\run_federated_split.ps1" -ProjectId $ProjectId -InputFile $InputFile -PointsPerRegion $PointsPerRegion -Concurrency $Concurrency -MaxRegions $Regions -ForceRebuild:$ForceRebuild.IsPresent -Optimized:$Optimized.IsPresent
}
