# PARCS Google Maps Stitcher

Parallel Google Maps tile downloading and stitching using PARCS framework.

## Files

- **solver.py**: PARCS solver that downloads Google Maps tiles in parallel and stitches them into a mosaic
- **input.txt**: Input file specifying region to sample
- **requirements.txt**: Python dependencies (install on PARCS instances)
- **decode_output.py**: Helper script to decode base64 output to PNG

## Input Format

```
<center_lat>
<center_lon>
<height_meters>
<width_meters>
<compress_flag>
```

Where `compress_flag` is:

- `0` = No compression (high quality)
- `1` = Compress to ~100MB max

## Example Input

```
50.4162021584
30.8906000000
1000
1000
0
```

This will generate a 1km × 1km satellite map centered at (50.4162, 30.8906) without compression.

## Output

The solution generates a **base64-encoded PNG** in the output file that can be downloaded from PARCS UI.

### Decoding Output (After Downloading from PARCS):

```bash
# Method 1: Use decode script
python decode_output.py output.txt map.png

# Method 2: Manual (Linux/Mac)
grep -v "PNG_BASE64" output.txt | base64 -d > map.png

# Method 3: Manual (Windows PowerShell)
$content = Get-Content output.txt -Raw
$base64 = $content -replace '.*PNG_BASE64_START\n','' -replace '\nPNG_BASE64_END.*',''
[IO.File]::WriteAllBytes("map.png", [Convert]::FromBase64String($base64))
```

## Setup on Google Cloud

### Prerequisites

1. Google Cloud instances created with PARCS containers
2. Google Maps API key set as environment variable `GMAPS_KEY`

### Environment Variable

On each instance (master and workers), set:

```bash
export GMAPS_KEY=YOUR_GOOGLE_MAPS_API_KEY
```

Or add to the container environment.

### Instance Creation (Recommended: 6-8 workers for 5x speedup)

```bash
# Create master
gcloud compute instances create-with-container master \
  --container-image=registry.hub.docker.com/hummer12007/parcs-node \
  --container-env PARCS_ARGS="master",GMAPS_KEY="YOUR_API_KEY"

# Create workers (6-8 for optimal performance)
gcloud compute instances create-with-container worker1 worker2 worker3 worker4 worker5 worker6 \
  --container-image=registry.hub.docker.com/hummer12007/parcs-node \
  --container-env PARCS_ARGS="worker MASTER_INTERNAL_IP",GMAPS_KEY="YOUR_API_KEY"
```

### Running on PARCS

1. Access PARCS web interface at `http://$MASTER_IP:8080`
2. Upload `solver.py` as the Solution File
3. Upload `input.txt` as the Input File
4. Click "Run" and wait for completion (~5 minutes with 6 workers for 2500 tiles)
5. Click "Output" button to download the base64-encoded result
6. Decode using `decode_output.py` or manual method above

## How It Works

1. **Master** reads input file and calculates tile coordinates using Web Mercator projection
2. **Master** distributes tile download tasks across workers (or runs sequentially if no workers)
3. **Workers** download tiles from Google Maps Static API in parallel
4. **Workers** crop 40px from bottom to remove Google watermark
5. **Workers** encode tiles as base64 and return to master
6. **Master** stitches tiles into final mosaic image
7. **Master** applies smart compression if enabled (downscales to ~100MB)
8. **Master** encodes final PNG as base64 and writes to output file

## Configuration

Default settings in `solver.py`:

- `zoom = 19` (high detail satellite imagery)
- `tile_size_px = 640` (maximum size for Static API)
- `scale = 2` (2x resolution for retina displays)
- `resolution_m = 100` (each tile covers ~100m)
- `crop_bottom = 40` (pixels to crop from bottom to remove watermark)

## Performance

- **Sequential (0 workers)**: ~25 minutes for 2500 tiles (5km × 5km)
- **6 workers**: ~5 minutes for 2500 tiles (5x speedup)
- **8 workers**: ~4 minutes for 2500 tiles (6x speedup)

## Features

✅ Watermark removal (crops bottom 40px)  
✅ Smart compression (targets 100MB max file size)  
✅ Progressive stitching (memory-efficient for large maps)  
✅ Fail-fast error handling  
✅ API key redaction in logs  
✅ Base64 output for PARCS UI compatibility
