# PARCS Google Maps Stitcher

Parallel Google Maps tile downloading and stitching using PARCS framework.

## Project Overview

This project demonstrates parallel computing for downloading and stitching Google Maps satellite tiles using two implementations:

1. **Python PARCS** (`solver.py`) - Original implementation using Pyro4-based PARCS
2. **C# PARCS.NET** (`csharp/`) - .NET Core implementation achieving **5.2x speedup** with multi-region federation

## Quick Start (PARCS.NET on GCP)

### Prerequisites

- Google Cloud SDK (`gcloud`) installed and configured
- PowerShell 5.1+ (Windows) or PowerShell Core (cross-platform)
- .NET SDK 8.0+ (for building the C# module)
- Google Maps API key with Static Maps API enabled
- GCP project with billing enabled

### 1. Set up environment

```powershell
# Set your API key
$env:GMAPS_KEY = "YOUR_GOOGLE_MAPS_API_KEY"

# Enable Compute Engine API (requires billing)
gcloud services enable compute.googleapis.com
```

### 2. Run baseline (1 region, 1 point)

This creates a cluster, runs the experiment, saves results, and tears down:

```powershell
# Create single cluster with 1 daemon
.\gcp\parcsnet_cluster.ps1 -Action up -ClusterName "parcsnet-baseline" -Daemons 1 -Zone "us-central1-a"

# Run experiment with 1 point on medium dataset
.\gcp\run_experiments_gcp.ps1 -HostInstance "parcsnet-baseline-host" -Zone "us-central1-a" -Points @(1) -Inputs @("tests\medium_district.txt")

# Results saved to: csharp\results_gcp_<timestamp>\results.csv

# Cleanup (delete cluster to stop billing)
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-baseline" -Zone "us-central1-a"
```

### 3. Run multi-region federated (5x+ speedup)

This script handles everything: creates 3 clusters, runs experiments, aggregates results, then you manually cleanup:

```powershell
# Deploy 3 clusters across regions (us-east1, us-west1, europe-west1)
# Each cluster: 1 host + 3 daemons with independent external IPs
.\gcp\run_multi_region_experiments.ps1

# Results saved to: csharp\results_multi_region_<timestamp>\

# Run federated tile-splitting experiment (splits 144 tiles across regions)
.\gcp\run_federated_split.ps1 -InputFile tests\medium_district.txt

# Results saved to: csharp\federated_results\federated_split_<timestamp>\

# Cleanup all clusters when done
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-us-east1" -Zone "us-east1-c"
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-us-west1" -Zone "us-west1-a"
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-europe-west1" -Zone "europe-west1-b"
```

## Results Location

| Experiment Type | Results Directory |
|-----------------|-------------------|
| Single-region baseline | `csharp\results_gcp_<timestamp>\` |
| Multi-region parallel | `csharp\results_multi_region_<timestamp>\` |
| Federated split | `csharp\federated_results\federated_split_<timestamp>\` |

Each results folder contains:
- `results.csv` - Timing data (input, points, download time, total time, speedup)
- `log_*.txt` - Raw experiment logs
- `summary.txt` - Human-readable summary

### Stitched Map Output

The actual stitched satellite map image is stored **on the remote GCP host** at `/home/<user>/parcsnet_run/out/`. To download it locally:

```powershell
# Download output files from host (add -DownloadOutputs flag)
.\gcp\run_experiments_gcp.ps1 -HostInstance "parcsnet-baseline-host" -Zone "us-central1-a" -Points @(1) -Inputs @("tests\medium_district.txt") -DownloadOutputs

# Or manually via SCP (while cluster is running):
scp -i ~/.ssh/google_compute_engine <user>@<host-external-ip>:~/parcsnet_run/out/* ./output/
```

The output file is a text file containing base64-encoded tile data. For the federated experiments (`--downloadonly` mode), tiles are saved as JSON for local merging.

## Performance Results

| Configuration | Download Time | Speedup |
|--------------|---------------|---------|
| 1 region, 1 point (baseline) | 65.0s | 1.0x |
| 1 region, 3 points (3 IPs) | 28.0s | 2.3x |
| **3 regions, 9 points (federated)** | **12.5s** | **5.2x** |

The key insight: Google Maps API rate-limits per external IP. Multi-region deployment with independent IPs per daemon enables true parallel scaling.

## Project Structure

```
gcp-project/
├── gcp/                          # GCP automation scripts
│   ├── parcsnet_cluster.ps1      # Create/delete single cluster
│   ├── run_experiments_gcp.ps1   # Run experiments on existing cluster
│   ├── run_multi_region_experiments.ps1  # Multi-region orchestration
│   ├── run_federated_split.ps1   # Federated tile-splitting experiment
│   └── README.md                 # GCP scripts documentation
├── csharp/                       # PARCS.NET implementation
│   ├── ParcsNetMapsStitcher/     # C# module source code
│   ├── results_gcp_*/            # Single-region results (gitignored)
│   ├── results_multi_region_*/   # Multi-region results (gitignored)
│   └── federated_results/        # Federated experiment results (gitignored)
├── tests/                        # Benchmark input files
│   ├── small_city_block.txt      # 16 tiles (400m x 400m)
│   └── medium_district.txt       # 144 tiles (1200m x 1200m)
├── report_c#.tex                 # LaTeX report (PARCS.NET results)
├── report_c#.pdf                 # Compiled report with 5.2x speedup
├── report.tex                    # Original Python PARCS report
├── solver.py                     # Python PARCS solver
└── legacy/                       # Old/deprecated files
```

## Input Format

```
<center_lat>
<center_lon>
<height_meters>
<width_meters>
<compress_flag>
```

Example (`tests/medium_district.txt`):
```
37.7749
-122.4194
1200
1200
0
```

## Script Reference

| Script | Purpose | Creates Cluster | Runs Experiment | Deletes Cluster |
|--------|---------|-----------------|-----------------|-----------------|
| `parcsnet_cluster.ps1 -Action up` | Create cluster | Yes | No | No |
| `parcsnet_cluster.ps1 -Action down` | Delete cluster | No | No | Yes |
| `run_experiments_gcp.ps1` | Run on existing cluster | No | Yes | No |
| `run_multi_region_experiments.ps1` | Full multi-region flow | Yes | Yes | No |
| `run_federated_split.ps1` | Federated experiment | No | Yes | No |

## Python PARCS (Original)

The original Python implementation using Pyro4-based PARCS:

```bash
# Install dependencies
pip install -r requirements.txt

# Run via PARCS web UI or CLI
python solver.py
```

## Reports

- `report_c#.pdf` - PARCS.NET results with 5.2x speedup (multi-region federation)
- `report.tex` - Original Python PARCS report

## References

1. [PARCS.NET Repository](https://github.com/AndriyKhavro/Parcs.NET)
2. [PARCS Python Repository](https://github.com/Hummer12007/parcs-python)
3. [Google Maps Static API](https://developers.google.com/maps/documentation/maps-static)

## License

See [LICENSE](LICENSE) file.
