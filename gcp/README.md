# GCP automation (PARCS.NET)

This folder contains scripts to provision PARCS.NET infrastructure on Google Cloud using `gcloud`.

## Why a "runner" VM is recommended

In PARCS.NET, the module (client) connects to:

- HostServer (TCP 1234) to allocate points
- then directly to each Daemon (TCP 2222) returned by HostServer

So the client must be able to reach every daemon. The easiest way is to run the client **inside the same VPC** (runner VM).

## Important: there is no "PARCS website" here

This GCP setup is **headless** (HostServer + Daemons in containers). You don’t upload code via a web UI.
You run the module from a machine inside the VPC (we do that via SSH + Docker on the host VM) and collect logs/results locally.

## Prerequisites

- Google Cloud SDK (`gcloud`) installed
- Billing enabled for the project (required for Compute Engine)
- Compute Engine API enabled:

```powershell
gcloud services enable compute.googleapis.com
```

- Authenticated:

```powershell
gcloud auth login
gcloud config set project <YOUR_PROJECT_ID>
```

- Optional (API key):
  - set `GMAPS_KEY` in your shell or in `.env` (never commit it).

## Create cluster

```powershell
.\gcp\parcsnet_cluster.ps1 -Action up -ClusterName parcsnet -Zone us-central1-a -Daemons 7
```

## One-command workflow (recommended)

From the repository root:

```powershell
.\run_all.bat
```

This provisions the cluster (if needed), runs the full sweep, and auto-fills `report_c#.tex`.

Optional flags:
- `--dryrun` (no Google Maps API calls)
- `--no-download` (skip downloading large output files)
- `--teardown` (delete the cluster at the end)

## Run experiments (PowerShell only)

Run everything end-to-end (build → upload → run p=1/4/7 → collect logs → write `results.csv`):

```powershell
.\gcp\run_experiments_gcp.ps1 -ProjectId maps-demo-486815 -Zone us-central1-a -HostInstance parcsnet-host
```

Quick “no API calls” sanity check:

```powershell
.\gcp\run_experiments_gcp.ps1 -ProjectId maps-demo-486815 -Zone us-central1-a -HostInstance parcsnet-host -DryRun
```

Notes:
- By default it saves `csharp\results_gcp_YYYYMMDD_HHMMSS\results.csv` plus per-run logs.
- Add `-DownloadOutputs` if you also want the large output text files copied back (can be tens of MB each).

## Delete cluster

```powershell
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName parcsnet -Zone us-central1-a -Daemons 7
```

