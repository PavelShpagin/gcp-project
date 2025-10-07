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
            center_lat, center_lon, height_m, width_m, compress = region
            print(f"Center: ({center_lat}, {center_lon})")
            print(f"Size: {width_m}m x {height_m}m")
            print(f"Compression: {'Enabled (max 100MB)' if compress else 'Disabled'}")
            
            # Generate the stitched map
            output_path = f"output_{idx}.png" if len(regions) > 1 else "output.png"
            self.process_region(center_lat, center_lon, width_m, height_m, output_path, compress)
        
        print("\nAll regions processed successfully!")

    def process_region(self, center_lat, center_lon, width_m, height_m, output_path, compress=False):
        """Process a single region: download tiles in parallel and stitch."""
        
        # Configuration
        zoom = 19
        tile_size_px = 640
        scale = 2
        resolution_m = 100  # Each tile covers approximately this many meters
        crop_bottom = 40  # Pixels to crop from bottom (remove watermark)
        
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
        
        # Distribute tile download tasks to workers (with sequential fallback)
        num_workers = len(self.workers) if self.workers else 0
        print(f"Distributing {len(tile_requests)} tiles across {num_workers} workers")

        downloaded_tiles = []

        if num_workers == 0:
            print("No workers available; downloading tiles sequentially...")
            downloaded_tiles = Solver.download_tiles(tile_requests, zoom, tile_size_px, scale, crop_bottom)
        else:
            # Split tiles among workers
            tiles_per_worker = max(1, len(tile_requests) // num_workers)
            worker_tasks = []

            for i, worker in enumerate(self.workers):
                start_idx = i * tiles_per_worker
                end_idx = start_idx + tiles_per_worker if i < num_workers - 1 else len(tile_requests)

                if start_idx < len(tile_requests):
                    worker_batch = tile_requests[start_idx:end_idx]
                    print(f"Worker {i}: downloading {len(worker_batch)} tiles")

                    # Submit task to worker
                    future = worker.download_tiles(worker_batch, zoom, tile_size_px, scale, crop_bottom)
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
        self.create_mosaic(downloaded_tiles, num_rows, num_cols, tile_size_px, scale, crop_bottom, output_path, compress)
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

    def create_mosaic(self, tiles, num_rows, num_cols, tile_size_px, scale, crop_bottom, output_path, compress=False):
        """Create mosaic from downloaded tiles with memory-efficient processing."""
        
        # Calculate actual tile dimensions after cropping
        original_tile_size = tile_size_px * scale
        cropped_tile_height = original_tile_size - crop_bottom
        cropped_tile_width = original_tile_size  # Width unchanged
        
        mosaic_width = num_cols * cropped_tile_width
        mosaic_height = num_rows * cropped_tile_height
        
        print(f"Creating mosaic: {mosaic_width}x{mosaic_height} pixels (each tile: {cropped_tile_width}x{cropped_tile_height})")
        
        # Sort tiles by row and col for proper placement
        tiles.sort(key=lambda t: (t['row'], t['col']))
        
        # Determine if we need aggressive compression for large images
        estimated_size_mb = (mosaic_width * mosaic_height * 3) / (1024 * 1024)
        print(f"Estimated uncompressed size: {estimated_size_mb:.1f}MB")
        
        if compress or estimated_size_mb > 500:
            # Use progressive row-by-row stitching for large images
            self._create_mosaic_progressive(tiles, num_rows, num_cols, cropped_tile_width, 
                                           cropped_tile_height, mosaic_width, mosaic_height, 
                                           output_path, compress)
        else:
            # Standard in-memory stitching for smaller images
            mosaic = Image.new('RGB', (mosaic_width, mosaic_height), color=(0, 0, 0))
            
            for tile in tiles:
                if tile['image_data']:
                    try:
                        img_data = base64.b64decode(tile['image_data'])
                        img = Image.open(BytesIO(img_data))
                        x_px = tile['col'] * cropped_tile_width
                        y_px = tile['row'] * cropped_tile_height
                        mosaic.paste(img, (x_px, y_px))
                    except Exception as e:
                        print(f"Error placing tile ({tile['row']}, {tile['col']}): {e}")
            
            mosaic.save(output_path, quality=95, optimize=True)
    
    def _create_mosaic_progressive(self, tiles, num_rows, num_cols, tile_width, tile_height, 
                                   mosaic_width, mosaic_height, output_path, compress):
        """Memory-efficient progressive mosaic creation with dynamic compression."""
        
        print("Using progressive stitching for memory efficiency...")
        
        # Create tiles dictionary for fast lookup
        tile_dict = {(t['row'], t['col']): t for t in tiles if t['image_data']}
        
        # Process in row chunks to reduce memory
        chunk_rows = max(1, min(10, num_rows))  # Process 10 rows at a time
        
        # Determine target quality based on compression flag
        if compress:
            # Start with medium quality for compression
            base_quality = 75
            target_size_mb = 100
        else:
            # High quality for no compression
            base_quality = 92
            target_size_mb = None
        
        mosaic = Image.new('RGB', (mosaic_width, mosaic_height), color=(0, 0, 0))
        
        # Stitch tiles row by row
        for chunk_start in range(0, num_rows, chunk_rows):
            chunk_end = min(chunk_start + chunk_rows, num_rows)
            print(f"  Processing rows {chunk_start}-{chunk_end}/{num_rows}...")
            
            for row in range(chunk_start, chunk_end):
                for col in range(num_cols):
                    tile = tile_dict.get((row, col))
                    if tile:
                        try:
                            img_data = base64.b64decode(tile['image_data'])
                            img = Image.open(BytesIO(img_data))
                            x_px = col * tile_width
                            y_px = row * tile_height
                            mosaic.paste(img, (x_px, y_px))
                            img.close()  # Free memory immediately
                        except Exception as e:
                            print(f"    Error placing tile ({row}, {col}): {e}")
        
        # Save with appropriate compression
        print("Saving mosaic...")
        if compress and target_size_mb:
            self._save_with_smart_compression(mosaic, output_path, target_size_mb, base_quality)
        else:
            mosaic.save(output_path, format='JPEG', quality=base_quality, optimize=True)
            size_mb = os.path.getsize(output_path) / (1024 * 1024)
            print(f"  Saved: {size_mb:.2f}MB")
    
    def _save_with_smart_compression(self, image, output_path, target_mb, start_quality):
        """Fast smart compression with aggressive downscaling for huge images."""
        max_size_bytes = target_mb * 1024 * 1024
        
        print(f"Applying smart compression (target: {target_mb}MB)...")
        
        # For very large images, estimate if we need to downscale first
        width, height = image.size
        estimated_full_size = (width * height * 3) / (1024 * 1024)  # Rough RGB estimate
        
        print(f"  Original size: {width}x{height} (estimated {estimated_full_size:.0f}MB uncompressed)")
        
        # If estimated size is way over target, jump straight to aggressive downscaling
        if estimated_full_size > target_mb * 20:  # More than 20x target size
            print(f"  Very large image detected - applying aggressive downscaling first...")
            
            # Calculate target scale - be very aggressive
            target_pixels = target_mb * 500000  # Conservative heuristic
            current_pixels = width * height
            scale_factor = min(0.45, (target_pixels / current_pixels) ** 0.5)
            
            new_w = int(width * scale_factor)
            new_h = int(height * scale_factor)
            
            print(f"  Downscaling to {scale_factor:.1%} ({new_w}x{new_h})...")
            resized = image.resize((new_w, new_h), Image.LANCZOS)
            
            # Save directly with good quality - should be under target now
            resized.save(output_path, format='JPEG', quality=80, optimize=True)
            size_mb = os.path.getsize(output_path) / (1024 * 1024)
            print(f"  Final: {size_mb:.2f}MB at {scale_factor:.0%} scale, quality 80 ✓")
            resized.close()
            return
        
        # Standard compression for smaller images
        for quality in [start_quality, 60, 45]:
            buffer = BytesIO()
            image.save(buffer, format='JPEG', quality=quality, optimize=True)
            size = buffer.tell()
            size_mb = size / (1024 * 1024)
            
            if size <= max_size_bytes:
                print(f"  Quality {quality}: {size_mb:.2f}MB ✓")
                with open(output_path, 'wb') as f:
                    f.write(buffer.getvalue())
                return
            else:
                print(f"  Quality {quality}: {size_mb:.2f}MB (too large)")
        
        # Moderate downscaling
        scale = 0.7
        new_w = int(width * scale)
        new_h = int(height * scale)
        resized = image.resize((new_w, new_h), Image.LANCZOS)
        resized.save(output_path, format='JPEG', quality=75, optimize=True)
        size_mb = os.path.getsize(output_path) / (1024 * 1024)
        print(f"  Final: {size_mb:.2f}MB at {scale:.0%} scale")
        resized.close()
    

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
            compress = int(lines[idx + 4]) == 1  # 1 = compress, 0 = don't compress
            regions.append((center_lat, center_lon, height_m, width_m, compress))
            idx += 5
        
        return regions

    @staticmethod
    @expose
    def download_tiles(tile_requests, zoom, tile_size_px, scale, crop_bottom=40):
        """
        Worker method: Download a batch of tiles from Google Maps.
        Returns list of tiles with base64-encoded image data (cropped to remove watermark).
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
                        # Crop Google watermark from bottom of image
                        img = Image.open(BytesIO(response.content))
                        width, height = img.size
                        
                        # Crop specified pixels from bottom (where watermark is)
                        cropped_img = img.crop((0, 0, width, height - crop_bottom))
                        
                        # Encode cropped image as base64 for transfer
                        buffer = BytesIO()
                        cropped_img.save(buffer, format='JPEG', quality=95)
                        image_data = base64.b64encode(buffer.getvalue()).decode('utf-8')
                        break
                    else:
                        print(f"Non-image response for tile ({row}, {col})")
                        
                except requests.exceptions.HTTPError as e:
                    # Don't retry on 4xx client errors (auth/quota issues)
                    if 400 <= e.response.status_code < 500:
                        error_msg = str(e).replace(api_key, '***REDACTED***')
                        print(f"Client error for tile ({row}, {col}): {error_msg}")
                        print(f"ERROR: API key issue detected. Check billing, API enablement, and key restrictions.")
                        break
                    elif attempt < max_retries - 1:
                        error_msg = str(e).replace(api_key, '***REDACTED***')
                        print(f"Retry {attempt + 1} for tile ({row}, {col}): {error_msg}")
                        time.sleep(backoff)
                        backoff *= 2
                    else:
                        error_msg = str(e).replace(api_key, '***REDACTED***')
                        print(f"Failed to download tile ({row}, {col}): {error_msg}")
                except Exception as e:
                    if attempt < max_retries - 1:
                        error_msg = str(e).replace(api_key, '***REDACTED***') if api_key in str(e) else str(e)
                        print(f"Retry {attempt + 1} for tile ({row}, {col}): {error_msg}")
                        time.sleep(backoff)
                        backoff *= 2
                    else:
                        error_msg = str(e).replace(api_key, '***REDACTED***') if api_key in str(e) else str(e)
                        print(f"Failed to download tile ({row}, {col}): {error_msg}")
            
            results.append({
                'row': row,
                'col': col,
                'image_data': image_data
            })
            
            if (idx + 1) % 10 == 0:
                print(f"  Progress: {idx + 1}/{len(tile_requests)} tiles")
        
        print(f"Worker completed: {len([r for r in results if r['image_data']])} successful downloads")
        return results