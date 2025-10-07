"""
PARCS Solution for Parallel Google Maps Tile Downloading and Stitching
"""

from Pyro4 import expose
import os
import sys
import base64
import math
import time
import requests
import numpy as np
from PIL import Image
from io import BytesIO


class Solver:
    def __init__(self, workers=None, input_file_name=None, output_file_name=None):
        self.input_file_name = input_file_name
        self.output_file_name = output_file_name
        self.workers = workers
        print("Solver initialized")
        print(f"Workers: {len(workers) if workers else 0}")

    def solve(self):
        print("Job started - Google Maps parallel tile download and stitching")
        
        # Read input file
        regions = self.read_input()
        print(f"Processing {len(regions)} region(s)")
        
        # Process each region
        for idx, region in enumerate(regions):
            print(f"\n=== Processing region {idx + 1}/{len(regions)} ===")
            center_lat, center_lon, height_m, width_m = region
            print(f"Center: ({center_lat}, {center_lon})")
            print(f"Size: {width_m}m x {height_m}m")
            
            # Generate the stitched map
            output_path = f"output_{idx}.png" if len(regions) > 1 else "output.png"
            self.process_region(center_lat, center_lon, width_m, height_m, output_path)
        
        print("\nAll regions processed successfully!")

    def process_region(self, center_lat, center_lon, width_m, height_m, output_path):
        """Process a single region: download tiles in parallel and stitch."""
        
        # Configuration
        zoom = 19
        tile_size_px = 640
        scale = 2
        resolution_m = 100  # Each tile covers approximately this many meters
        
        # Calculate grid dimensions
        num_cols = max(1, int(width_m / resolution_m))
        num_rows = max(1, int(height_m / resolution_m))
        total_tiles = num_cols * num_rows
        
        print(f"Grid: {num_rows}x{num_cols} = {total_tiles} tiles")
        
        # Calculate tile coordinates using Web Mercator projection
        tile_requests = self.calculate_tile_coordinates(
            center_lat, center_lon, num_rows, num_cols, 
            zoom, tile_size_px
        )
        
        # Distribute tile download tasks to workers
        print(f"Distributing {len(tile_requests)} tiles across {len(self.workers)} workers")
        
        # Split tiles among workers
        tiles_per_worker = max(1, len(tile_requests) // len(self.workers))
        downloaded_tiles = []
        
        worker_tasks = []
        for i, worker in enumerate(self.workers):
            start_idx = i * tiles_per_worker
            end_idx = start_idx + tiles_per_worker if i < len(self.workers) - 1 else len(tile_requests)
            
            if start_idx < len(tile_requests):
                worker_batch = tile_requests[start_idx:end_idx]
                print(f"Worker {i}: downloading {len(worker_batch)} tiles")
                
                # Submit task to worker
                future = worker.download_tiles(worker_batch, zoom, tile_size_px, scale)
                worker_tasks.append(future)
        
        # Collect results from workers
        print("Waiting for workers to download tiles...")
        for i, future in enumerate(worker_tasks):
            tiles = future.value
            print(f"Worker {i} completed: {len(tiles)} tiles downloaded")
            downloaded_tiles.extend(tiles)
        
        print(f"Total tiles downloaded: {len(downloaded_tiles)}")
        
        # Stitch tiles into mosaic
        print("Stitching tiles into mosaic...")
        self.create_mosaic(downloaded_tiles, num_rows, num_cols, tile_size_px, scale, output_path)
        print(f"Mosaic saved to {output_path}")

    def calculate_tile_coordinates(self, center_lat, center_lon, num_rows, num_cols, zoom, tile_size_px):
        """Calculate coordinates for all tiles using Web Mercator projection."""
        
        world_px = 256 * (2 ** zoom)
        
        def latlon_to_pixel(lat, lon):
            x = (lon + 180.0) / 360.0 * world_px
            siny = math.sin(math.radians(lat))
            y = (0.5 - math.log((1 + siny) / (1 - siny)) / (4 * math.pi)) * world_px
            return x, y
        
        def pixel_to_latlon(x, y):
            lon = x / world_px * 360.0 - 180.0
            n = math.pi - 2.0 * math.pi * y / world_px
            lat = math.degrees(math.atan(math.sinh(n)))
            return lat, lon
        
        cx, cy = latlon_to_pixel(center_lat, center_lon)
        step_px = tile_size_px
        
        tile_requests = []
        for i in range(num_rows):
            for j in range(num_cols):
                dx_px = (j - (num_cols - 1) / 2.0) * step_px
                dy_px = (i - (num_rows - 1) / 2.0) * step_px
                x = cx + dx_px
                y = cy + dy_px
                lat, lon = pixel_to_latlon(x, y)
                
                tile_requests.append({
                    'lat': lat,
                    'lon': lon,
                    'row': i,
                    'col': j
                })
        
        return tile_requests

    def create_mosaic(self, tiles, num_rows, num_cols, tile_size_px, scale, output_path):
        """Create mosaic from downloaded tiles."""
        
        actual_tile_size = tile_size_px * scale
        mosaic_width = num_cols * actual_tile_size
        mosaic_height = num_rows * actual_tile_size
        
        print(f"Creating mosaic: {mosaic_width}x{mosaic_height} pixels")
        mosaic = Image.new('RGB', (mosaic_width, mosaic_height), color=(0, 0, 0))
        
        # Sort tiles by row and col for proper placement
        tiles.sort(key=lambda t: (t['row'], t['col']))
        
        for tile in tiles:
            if tile['image_data']:
                try:
                    # Decode base64 image
                    img_data = base64.b64decode(tile['image_data'])
                    img = Image.open(BytesIO(img_data))
                    
                    # Place tile in mosaic
                    x_px = tile['col'] * actual_tile_size
                    y_px = tile['row'] * actual_tile_size
                    mosaic.paste(img, (x_px, y_px))
                    
                except Exception as e:
                    print(f"Error placing tile ({tile['row']}, {tile['col']}): {e}")
        
        # Save mosaic
        mosaic.save(output_path, quality=95, optimize=True)

    def read_input(self):
        """Read input file and parse region specifications."""
        with open(self.input_file_name, 'r') as f:
            lines = [line.strip() for line in f if line.strip()]
        
        num_regions = int(lines[0])
        regions = []
        
        idx = 1
        for _ in range(num_regions):
            center_lat = float(lines[idx])
            center_lon = float(lines[idx + 1])
            height_m = float(lines[idx + 2])
            width_m = float(lines[idx + 3])
            regions.append((center_lat, center_lon, height_m, width_m))
            idx += 4
        
        return regions

    @staticmethod
    @expose
    def download_tiles(tile_requests, zoom, tile_size_px, scale):
        """
        Worker method: Download a batch of tiles from Google Maps.
        Returns list of tiles with base64-encoded image data.
        """
        print(f"Worker downloading {len(tile_requests)} tiles...")
        
        # Get API key from environment
        api_key = os.environ.get('GMAPS_KEY') or os.environ.get('GOOGLE_MAPS_API_KEY')
        if not api_key:
            print("ERROR: No Google Maps API key found in environment!")
            return []
        
        base_url = "https://maps.googleapis.com/maps/api/staticmap"
        results = []
        
        for idx, req in enumerate(tile_requests):
            lat = req['lat']
            lon = req['lon']
            row = req['row']
            col = req['col']
            
            # Build request URL
            params = {
                'center': f'{lat:.10f},{lon:.10f}',
                'zoom': zoom,
                'size': f'{tile_size_px}x{tile_size_px}',
                'scale': scale,
                'maptype': 'satellite',
                'format': 'jpg',
                'key': api_key
            }
            
            # Make request with retries
            max_retries = 3
            backoff = 1.0
            image_data = None
            
            for attempt in range(max_retries):
                try:
                    # Rate limiting
                    time.sleep(0.1)
                    
                    response = requests.get(base_url, params=params, timeout=15)
                    response.raise_for_status()
                    
                    if response.headers.get('content-type', '').startswith('image'):
                        # Encode image as base64 for transfer
                        image_data = base64.b64encode(response.content).decode('utf-8')
                        break
                    else:
                        print(f"Non-image response for tile ({row}, {col})")
                        
                except Exception as e:
                    if attempt < max_retries - 1:
                        print(f"Retry {attempt + 1} for tile ({row}, {col}): {e}")
                        time.sleep(backoff)
                        backoff *= 2
                    else:
                        print(f"Failed to download tile ({row}, {col}): {e}")
            
            results.append({
                'row': row,
                'col': col,
                'image_data': image_data
            })
            
            if (idx + 1) % 10 == 0:
                print(f"  Progress: {idx + 1}/{len(tile_requests)} tiles")
        
        print(f"Worker completed: {len([r for r in results if r['image_data']])} successful downloads")
        return results