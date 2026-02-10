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

### 2. Deploy multi-region clusters (for 5x+ speedup)

```powershell
# Deploy 3 clusters across regions (us-east1, us-west1, europe-west1)
# Each cluster has 1 host + 3 daemons with independent external IPs
.\gcp\run_multi_region_experiments.ps1
```

### 3. Run federated experiment

```powershell
# Split 144 tiles across 3 regions (48 tiles each)
# Achieves 5.2x speedup vs single-point baseline
.\gcp\run_federated_split.ps1 -InputFile tests\medium_district.txt
```

### 4. View results

Results are saved to `csharp\federated_results\federated_split_*\`

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
│   ├── parcsnet_cluster.ps1      # Single cluster management
│   ├── run_multi_region_experiments.ps1  # Multi-region orchestration
│   ├── run_federated_split.ps1   # Federated tile-splitting experiment
│   └── README.md                 # GCP scripts documentation
├── csharp/                       # PARCS.NET implementation
│   ├── ParcsNetMapsStitcher/     # C# module source code
│   └── federated_results/        # Experiment results
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

## Alternative: Single-Region Setup

For simpler setups (lower speedup due to API throttling):

```powershell
# Spin up single cluster with 7 daemons
.\gcp\spin_up_cluster.ps1 -Daemons 7

# Run experiments
.\gcp\run_all_experiments.ps1
```

## Python PARCS (Original)

The original Python implementation using Pyro4-based PARCS:

```bash
# Install dependencies
pip install -r requirements.txt

# Run via PARCS web UI or CLI
python solver.py
```

## Cleanup

```powershell
# Delete all clusters to stop billing
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-us-east1"
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-us-west1"
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-europe-west1"
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
