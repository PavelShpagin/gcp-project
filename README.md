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

---

## Configuration 1: Baseline (1 region, 1 point)

Single worker baseline for comparison. Expected download time: ~65s.

```powershell
# 1. Create cluster (1 host + 1 daemon)
.\gcp\parcsnet_cluster.ps1 -Action up -ClusterName "parcsnet-baseline" -Daemons 1 -Zone "us-central1-a"

# 2. Run experiment
.\gcp\run_experiments_gcp.ps1 -HostInstance "parcsnet-baseline-host" -Zone "us-central1-a" -Points @(1) -Inputs @("tests\medium_district.txt")

# 3. Cleanup
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-baseline" -Zone "us-central1-a"
```

**Results:** `csharp\results_gcp_<timestamp>\`
- `results.csv` - timing data
- `medium_district_1.jpg` - stitched satellite map

---

## Configuration 2: Single Cluster (1 region, multiple points)

Single region with multiple daemons. Limited by API rate-limiting (~2.3x speedup max).

```powershell
# 1. Create cluster (1 host + 3 daemons with independent external IPs)
.\gcp\parcsnet_cluster.ps1 -Action up -ClusterName "parcsnet-cluster" -Daemons 3 -Zone "us-central1-a"

# 2. Run experiment with 1 and 3 points
.\gcp\run_experiments_gcp.ps1 -HostInstance "parcsnet-cluster-host" -Zone "us-central1-a" -Points @(1,3) -Inputs @("tests\medium_district.txt")

# 3. Cleanup
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-cluster" -Zone "us-central1-a"
```

**Results:** `csharp\results_gcp_<timestamp>\`

---

## Configuration 3: Multi-Region Federated (5.2x speedup)

Distributes work across 3 GCP regions with independent external IPs per daemon.

```powershell
# 1. Create 3 clusters (us-east1, us-west1, europe-west1)
.\gcp\run_multi_region_experiments.ps1

# 2. Run federated experiment (splits 144 tiles across regions)
.\gcp\run_federated_split.ps1 -InputFile tests\medium_district.txt

# 3. Cleanup all clusters
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-us-east1" -Zone "us-east1-d"
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-us-west1" -Zone "us-west1-c"
.\gcp\parcsnet_cluster.ps1 -Action down -ClusterName "parcsnet-mr-europe-west1" -Zone "europe-west1-b"
```

**Results:** `csharp\federated_results\federated_split_<timestamp>\`

---

## Performance Results

| Configuration | Download Time | Speedup |
|--------------|---------------|---------|
| 1 region, 1 point (baseline) | 65.0s | 1.0x |
| 1 region, 3 points (3 IPs) | 28.0s | 2.3x |
| **3 regions, 9 points (federated)** | **12.5s** | **5.2x** |

The key insight: Google Maps API rate-limits per external IP. Multi-region deployment with independent IPs per daemon enables true parallel scaling.

---

## Script Architecture

### Infrastructure Scripts (create/destroy VMs)

| Script | Purpose |
|--------|---------|
| `parcsnet_cluster.ps1 -Action up` | Create cluster with PARCS.NET containers |
| `parcsnet_cluster.ps1 -Action down` | Delete cluster and stop billing |
| `run_multi_region_experiments.ps1` | Create 3 regional clusters + run experiments |

### Experiment Scripts (run on existing clusters)

| Script | Purpose |
|--------|---------|
| `run_experiments_gcp.ps1` | Run experiments on a single cluster |
| `run_federated_split.ps1` | Run federated experiment across regions |

**Note:** Experiment scripts auto-detect if code/images are already deployed and skip redundant uploads. Use `-ForceRebuild` after changing C# code.

---

## Results Location

| Experiment Type | Results Directory |
|-----------------|-------------------|
| Single-region | `csharp\results_gcp_<timestamp>\` |
| Multi-region | `csharp\results_multi_region_<timestamp>\` |
| Federated split | `csharp\federated_results\federated_split_<timestamp>\` |

Each results folder contains:
- `results.csv` - Timing data (input, points, download time, total time)
- `*.jpg` - Stitched satellite map images (auto-decoded)
- `log_*.txt` - Raw experiment logs

---

## Project Structure

```
gcp-project/
├── gcp/                          # GCP automation scripts
│   ├── parcsnet_cluster.ps1      # Create/delete single cluster
│   ├── run_experiments_gcp.ps1   # Run experiments on existing cluster
│   ├── run_multi_region_experiments.ps1  # Multi-region orchestration
│   └── run_federated_split.ps1   # Federated tile-splitting experiment
├── csharp/                       # PARCS.NET implementation
│   └── ParcsNetMapsStitcher/     # C# module source code
├── tests/                        # Benchmark input files
│   ├── small_city_block.txt      # 16 tiles (400m x 400m)
│   └── medium_district.txt       # 144 tiles (1200m x 1200m)
├── report_c#.tex                 # LaTeX report (PARCS.NET results)
├── report_c#.pdf                 # Compiled report with 5.2x speedup
└── solver.py                     # Python PARCS solver (original)
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

## Python PARCS (Original)

The original Python implementation using Pyro4-based PARCS:

```bash
pip install -r requirements.txt
python solver.py
```

## References

1. [PARCS.NET Repository](https://github.com/AndriyKhavro/Parcs.NET)
2. [Google Maps Static API](https://developers.google.com/maps/documentation/maps-static)

## License

See [LICENSE](LICENSE) file.
