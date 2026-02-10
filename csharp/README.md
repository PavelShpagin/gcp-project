# PARCS.NET (C#) – Google Maps Tile Stitcher

This folder contains a **C# / Parcs.NET** adaptation of the Python `solver.py` (Google Maps parallel tile download + stitching).

## What you need (secrets / infra)

- **Google Maps API key**: required for live runs.
  - Set **on every daemon/worker** as `GMAPS_KEY` (or `GOOGLE_MAPS_API_KEY`).
- **PARCS.NET infrastructure**: HostServer + at least one Daemon must be running.
  - Parcs.NET upstream repo: `https://github.com/AndriyKhavro/Parcs.NET`
  - Docker images in that repo are **Windows containers** (Windows Server Core).

## Build the module

```powershell
dotnet build .\csharp\ParcsNetMapsStitcher.sln -c Release
```

The executable will be at:

- `csharp\ParcsNetMapsStitcher\bin\Release\net48\ParcsNetMapsStitcher.exe`

## Start HostServer + Daemons (Docker, Windows containers)

Parcs.NET provides Windows-container images. On Windows you must:

- run Docker Desktop
- **switch to Windows containers**

Then you can use the helper script:

```powershell
.\csharp\start-parcsnet-docker.ps1 -Daemons 7
```

It prints the **HostServer IP** you should pass as `--serverip` when running the module.

## GCP automation

If you want to provision PARCS.NET infra on Google Cloud with `gcloud`, see:

- `gcp/README.md`
- `gcp/parcsnet_cluster.ps1`

## One-command GCP run (recommended)

From the repository root, run:

```powershell
.\run_all.bat
```

This will:
- provision (idempotently) HostServer + 7 daemons on GCP
- run the benchmark sweep (small/medium/large with points=1/4/7)
- write `csharp/results_gcp_*/results.csv`
- auto-fill `report_c#.tex` with measured times + speedups (and create a `.bak_*` backup)

Optional flags:
- `--dryrun` (no Google Maps API calls)
- `--no-download` (skip downloading large output files)
- `--teardown` (delete the cluster at the end)

## Run the module

Example (7 points, large dataset, compression enabled in input file):

```powershell
$serverIp = "<HOSTSERVER_CONTAINER_IP>"
$env:GMAPS_KEY = "<YOUR_KEY>"   # only needed if daemons inherit env from your shell; prefer passing it to daemon containers

.\csharp\ParcsNetMapsStitcher\bin\Release\net48\ParcsNetMapsStitcher.exe `
  --serverip $serverIp `
  --input .\tests\large_metro.txt `
  --output .\out_large_7.txt `
  --points 7
```

### Output decoding

The output file contains base64 between:

- `PNG_BASE64_START`
- `PNG_BASE64_END`

The first line also includes `FORMAT=PNG` or `FORMAT=JPEG`.

Decode using the existing helper (works for PNG/JPEG; choose extension accordingly):

```powershell
python .\decode_output.py .\out_large_7.txt .\map_large_7.jpg
```

## Benchmarks / experiments

Run the experiment driver (produces a CSV + logs):

```powershell
.\csharp\run_experiments.ps1 -ServerIp "<HOSTSERVER_IP>" -Points 1,4,7
```

