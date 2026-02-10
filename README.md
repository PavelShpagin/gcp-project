# PARCS Google Maps Stitcher

Parallel Google Maps tile downloading and stitching using PARCS framework.

## Project Overview

This project demonstrates parallel computing for downloading and stitching Google Maps satellite tiles using two implementations:

1. **Python PARCS** (`solver.py`) - Original implementation using Pyro4-based PARCS
2. **C# PARCS.NET** (`csharp/`) - .NET Core implementation achieving **5x-8x speedup** with multi-region federation

## Quick Start

Run federated experiment on existing clusters (one command, args only):

```powershell
.\gcp\run.ps1 -MaxRegions 4 -PointsPerRegion 3 -Concurrency 16
```

- MaxRegions=0 (default) = use all clusters. Add -ForceRebuild to rebuild Docker first.
- Create clusters: `.\gcp\run_multi_region_experiments.ps1 -TargetClusterCount 4 -DaemonsPerRegion 3`
- Delete clusters: `.\gcp\cleanup_regions.ps1`

---

## Baseline (1 region)

Create 1 cluster, run with 1 point:

```powershell
.\gcp\run_multi_region_experiments.ps1 -TargetClusterCount 1 -DaemonsPerRegion 1
.\gcp\run.ps1 -MaxRegions 1 -PointsPerRegion 1 -Concurrency 1
```

---

## Federated (multi-region, up to 12x speedup)

Create 4 regions x 3 daemons, run:

```powershell
.\gcp\run_multi_region_experiments.ps1 -TargetClusterCount 4 -DaemonsPerRegion 3
.\gcp\run.ps1 -MaxRegions 4 -PointsPerRegion 3 -Concurrency 16
```

Note: Each region uses 1 host + N daemons. Ensure GCP CPU quota allows it.

## Configuration 3: Fair Comparison (Baseline vs Federated)

Run a direct "fair" comparison between a single-threaded baseline and the fully optimized federated cluster.

```powershell
.\gcp\legacy\run_fair_comparison.ps1 -FederatedConcurrency 16
```

This script:
1. Runs a **Baseline** on the first available cluster: 1 Point, **1 Thread** (`-Concurrency 1`).
2. Runs the **Federated** experiment on all clusters: 1 Point/Region, **16 Threads/Point** (`-Concurrency 16`).
3. Calculates the true speedup.

## Performance Results

| Configuration | Download Time | Speedup |
|--------------|---------------|---------|
| 1 daemon, 1 point (baseline, single-threaded) | ~200s+ | 1.0x |
| 1 daemon, 1 point (baseline, optimized) | 65.0s | ~3.0x |
| 3 daemons, 3 points (1 region) | 28.0s | ~7.0x |
| **Federated (4 regions)** | **15.9s** | **~12.5x** (vs single-threaded) |

**Key insight:** The "optimized baseline" (65s) already uses 16 parallel threads. A true "fair" comparison against a single-threaded process reveals the massive speedup from distributed parallelism.

---

## Script Architecture

| Script | Purpose |
|--------|---------|
| `run.ps1` | Run federated experiment (args: MaxRegions, PointsPerRegion, Concurrency, -ForceRebuild) |
| `run_federated_split.ps1` | Splits tiles across regions, runs experiment |
| `run_multi_region_experiments.ps1` | Provisions clusters across regions |
| `cleanup_regions.ps1` | Deletes all `parcsnet-mr-*` clusters |
| `parcsnet_cluster.ps1` | Creates/deletes a single cluster |
| `legacy/` | Deprecated scripts (run_full_cycle, run_experiments_gcp, etc.) |

---

## Results Location

| Experiment Type | Results Directory |
|-----------------|-------------------|
| Single-region | `csharp\results_gcp_<timestamp>\` |
| Multi-region | `csharp\results_multi_region_<timestamp>\` |
| Federated | `csharp\federated_results\federated_split_<timestamp>\` |

Each results folder contains:
- `results.csv` - Timing data
- `*.jpg` - Stitched satellite map images (auto-decoded)
- `log_*.txt` - Raw experiment logs

---

## Project Structure

```
gcp-project/
├── gcp/                          # GCP automation scripts
│   ├── run.ps1                   # Run experiment (args only)
│   ├── run_federated_split.ps1   # Federated tile-splitting runner
│   ├── run_multi_region_experiments.ps1
│   ├── cleanup_regions.ps1
│   ├── parcsnet_cluster.ps1
│   └── legacy/                   # Deprecated scripts
├── csharp/                       # PARCS.NET implementation
│   └── ParcsNetMapsStitcher/     # C# module source code
├── tests/                        # Benchmark input files
│   ├── small_city_block.txt      # 16 tiles (400m x 400m)
│   └── medium_district.txt       # 144 tiles (1200m x 1200m)
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

## References

1. [PARCS.NET Repository](https://github.com/AndriyKhavro/Parcs.NET)
2. [Google Maps Static API](https://developers.google.com/maps/documentation/maps-static)

## License

See [LICENSE](LICENSE) file.
