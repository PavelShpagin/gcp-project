@echo off
setlocal EnableExtensions

REM One-click automation:
REM - Provision PARCS.NET HostServer + Daemons on GCP (idempotent)
REM - Run experiment sweep (p=1,4,7; small/medium/large)
REM - Update report_c#.tex with measured times + speedups
REM
REM Optional flags:
REM   --dryrun         Run without Google Maps API calls
REM   --no-download    Don't scp remote output files back
REM   --teardown       Delete the cluster at the end (stop billing)

set "REPO_ROOT=%~dp0"
pushd "%REPO_ROOT%"

set "PROJECT_ID=maps-demo-486815"
set "ZONE=us-central1-a"
set "CLUSTER_NAME=parcsnet"
set "DAEMONS=7"
set "HOST_INSTANCE=parcsnet-host"

set "DRYRUN=0"
set "DOWNLOAD_OUTPUTS=1"
set "TEARDOWN=0"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="--dryrun" set "DRYRUN=1"
if /I "%~1"=="--no-download" set "DOWNLOAD_OUTPUTS=0"
if /I "%~1"=="--teardown" set "TEARDOWN=1"
shift
goto parse_args
:args_done

echo.
echo === [1/4] Provisioning PARCS.NET cluster on GCP ===
powershell -NoProfile -ExecutionPolicy Bypass -File ".\gcp\parcsnet_cluster.ps1" ^
  -Action up ^
  -ProjectId "%PROJECT_ID%" ^
  -ClusterName "%CLUSTER_NAME%" ^
  -Zone "%ZONE%" ^
  -Daemons %DAEMONS%
if errorlevel 1 goto fail

echo.
echo === [2/4] Running experiment sweep (this can take a while) ===
set "DRYRUN_FLAG="
if "%DRYRUN%"=="1" set "DRYRUN_FLAG=-DryRun"
set "DL_FLAG="
if "%DOWNLOAD_OUTPUTS%"=="1" set "DL_FLAG=-DownloadOutputs"

echo Resolving host IPs (for SSH + HostServer)...
for /f "usebackq delims=" %%I in (`gcloud.cmd compute instances describe %HOST_INSTANCE% --project %PROJECT_ID% --zone %ZONE% --format^="get(networkInterfaces[0].accessConfigs[0].natIP)" --quiet`) do set "HOST_NAT_IP=%%I"
for /f "usebackq delims=" %%I in (`gcloud.cmd compute instances describe %HOST_INSTANCE% --project %PROJECT_ID% --zone %ZONE% --format^="get(networkInterfaces[0].networkIP)" --quiet`) do set "HOST_INTERNAL_IP=%%I"

if "%HOST_NAT_IP%"=="" goto fail
if "%HOST_INTERNAL_IP%"=="" goto fail

powershell -NoProfile -ExecutionPolicy Bypass -File ".\gcp\run_experiments_gcp.ps1" ^
  -ProjectId "%PROJECT_ID%" ^
  -Zone "%ZONE%" ^
  -HostInstance "%HOST_INSTANCE%" ^
  -HostNatIp "%HOST_NAT_IP%" ^
  -HostInternalIp "%HOST_INTERNAL_IP%" ^
  %DRYRUN_FLAG% ^
  %DL_FLAG%
if errorlevel 1 goto fail

echo.
echo === [3/4] Locating latest results directory ===
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-ChildItem -Directory '.\\csharp' -Filter 'results_gcp_*' ^| Sort-Object LastWriteTime -Descending ^| Select-Object -First 1).FullName"`) do set "LATEST_DIR=%%A"
if "%LATEST_DIR%"=="" goto fail_no_results
set "RESULTS_CSV=%LATEST_DIR%\results.csv"
if not exist "%RESULTS_CSV%" goto fail_no_results

echo.
echo === [4/4] Updating LaTeX report (report_c#.tex) ===
powershell -NoProfile -ExecutionPolicy Bypass -File ".\gcp\update_report_csharp.ps1" ^
  -ResultsCsv "%RESULTS_CSV%" ^
  -ReportPath ".\report_c#.tex"
if errorlevel 1 goto fail

echo.
echo DONE.
echo - Results CSV: "%RESULTS_CSV%"
echo - Report updated: ".\report_c#.tex"

echo.
echo Preparing PDF...
copy /Y "report_c#.tex" "report_csharp.tex"

where pdflatex.exe >nul 2>nul
if "%ERRORLEVEL%"=="0" (
  echo Compiling PDF with pdflatex...
  pdflatex -interaction=nonstopmode -halt-on-error -jobname report_csharp "report_csharp.tex"
) else (
  echo pdflatex not found; downloading/using tectonic...
  powershell -NoProfile -ExecutionPolicy Bypass -File ".\gcp\ensure_tectonic.ps1"
  if errorlevel 1 goto fail
  ".\.tools\tectonic\tectonic.exe" "report_csharp.tex"
  if errorlevel 1 goto fail
)

if exist "report_csharp.pdf" (
  copy /Y "report_csharp.pdf" "report_c#.pdf"
  echo PDF ready: "report_csharp.pdf" (copy: "report_c#.pdf")
) else (
  echo WARNING: PDF was not generated (check LaTeX output above).
)

if "%TEARDOWN%"=="1" (
  echo.
  echo Tearing down cluster (stop billing)...
  powershell -NoProfile -ExecutionPolicy Bypass -File ".\gcp\parcsnet_cluster.ps1" ^
    -Action down ^
    -ProjectId "%PROJECT_ID%" ^
    -ClusterName "%CLUSTER_NAME%" ^
    -Zone "%ZONE%" ^
    -Daemons %DAEMONS%
)

popd
exit /b 0

:fail_no_results
echo ERROR: could not find results.csv under csharp\results_gcp_*
goto fail

:fail
echo ERROR: run_all failed.
popd
exit /b 1

