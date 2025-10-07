# PARCS Google Maps Stitcher

Parallel Google Maps tile downloading and stitching using PARCS framework.

## Files

- **solution.py**: PARCS solver that downloads Google Maps tiles in parallel and stitches them into a mosaic
- **input.txt**: Input file specifying regions to sample
- **requirements.txt**: Python dependencies (install on PARCS instances)

## Input Format

```
<number_of_regions>
<center_lat_1>
<center_lon_1>
<height_meters_1>
<width_meters_1>
<center_lat_2>
<center_lon_2>
<height_meters_2>
<width_meters_2>
...
```

## Example Input

```
2
50.4162021584
30.8906000000
1000
1000
50.4162
30.8906
5000
5000
```

This will generate 2 stitched maps:
1. A 1km × 1km region centered at (50.4162, 30.8906)
2. A 5km × 5km region centered at (50.4162, 30.8906)

## Output

The solution generates `output.png` (for single region) or `output_0.png`, `output_1.png`, etc. (for multiple regions).

## Setup on Google Cloud

### Prerequisites

1. Google Cloud instances created with PARCS containers
2. Google Maps API key set as environment variable `GMAPS_KEY`

### Environment Variable

On each instance (master and workers), set:
```bash
export GMAPS_KEY=AIzaSyBHgIsFNlDmq33vkAeYt1w9ekVd43yLZvo
```

Or add to the container environment.

### Running

1. Upload `solution.py` as the Solution File in PARCS GUI
2. Upload `input.txt` as the Input File in PARCS GUI
3. Click "Run" and wait for completion
4. Download the generated `output.png` or `output_N.png` files

## How It Works

1. **Master** reads input file and calculates tile coordinates using Web Mercator projection
2. **Master** distributes tile download tasks across workers
3. **Workers** download tiles from Google Maps Static API in parallel
4. **Workers** encode tiles as base64 and return to master
5. **Master** stitches tiles into final mosaic image and saves as PNG

## Configuration

Default settings in `solution.py`:
- `zoom = 19` (high detail satellite imagery)
- `tile_size_px = 640` (maximum size for Static API)
- `scale = 2` (2x resolution for retina displays)
- `resolution_m = 100` (each tile covers ~100m)

Adjust these values in the `process_region` method as needed.