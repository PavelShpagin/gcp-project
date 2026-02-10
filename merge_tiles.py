#!/usr/bin/env python3
"""Merge federated tile data and build mosaic."""

import sys
import os
import base64
from io import BytesIO
from PIL import Image
import time

def load_tiles_from_file(filepath):
    """Load tiles from a region tile data file."""
    tiles = {}
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('TILE|'):
                parts = line.split('|', 3)
                row = int(parts[1])
                col = int(parts[2])
                b64 = parts[3]
                tiles[(row, col)] = b64
    return tiles

def main():
    if len(sys.argv) < 3:
        print("Usage: merge_tiles.py <output_image> <tile_file1> [tile_file2] ...")
        sys.exit(1)
    
    output_path = sys.argv[1]
    tile_files = sys.argv[2:]
    
    start = time.time()
    
    # Load all tiles with row offset per region
    all_tiles = {}
    max_row = 0
    max_col = 0
    row_offset = 0
    
    for f in tile_files:
        print(f"Loading {f} (row_offset={row_offset})...")
        tiles = load_tiles_from_file(f)
        
        # Find max row in this region to calculate offset for next
        region_max_row = max(row for (row, col) in tiles.keys()) if tiles else 0
        
        for (row, col), b64 in tiles.items():
            adjusted_row = row + row_offset
            all_tiles[(adjusted_row, col)] = b64
            max_row = max(max_row, adjusted_row)
            max_col = max(max_col, col)
        
        # Next region starts after this region's rows
        row_offset += region_max_row + 1
    
    num_rows = max_row + 1
    num_cols = max_col + 1
    print(f"Grid: {num_rows}x{num_cols}, {len(all_tiles)} tiles")
    
    # Determine tile size from first tile
    first_b64 = next(iter(all_tiles.values()))
    first_bytes = base64.b64decode(first_b64)
    with Image.open(BytesIO(first_bytes)) as img:
        tile_w, tile_h = img.size
    print(f"Tile size: {tile_w}x{tile_h}")
    
    mosaic_w = num_cols * tile_w
    mosaic_h = num_rows * tile_h
    print(f"Mosaic size: {mosaic_w}x{mosaic_h}")
    
    # Create mosaic
    mosaic = Image.new('RGB', (mosaic_w, mosaic_h), (0, 0, 0))
    
    load_time = time.time()
    print(f"Load time: {load_time - start:.2f}s")
    
    # Paste tiles
    for (row, col), b64 in all_tiles.items():
        tile_bytes = base64.b64decode(b64)
        with Image.open(BytesIO(tile_bytes)) as tile:
            x = col * tile_w
            y = row * tile_h
            mosaic.paste(tile, (x, y))
    
    paste_time = time.time()
    print(f"Paste time: {paste_time - load_time:.2f}s")
    
    # Save
    mosaic.save(output_path, quality=90)
    save_time = time.time()
    print(f"Save time: {save_time - paste_time:.2f}s")
    
    total = save_time - start
    print(f"Total mosaic time: {total:.2f}s")
    print(f"Saved to: {output_path}")

if __name__ == '__main__':
    main()
