# -*- coding: utf-8 -*-
from __future__ import print_function, division

"""
PARCS Solution for Parallel Google Maps Tile Downloading and Stitching
Compatible with both Python 2.7 and Python 3.x
"""

from Pyro4 import expose
import os
import sys
import base64
import math
import time
import traceback
import requests
import numpy as np
from PIL import Image

# ---- Python 2/3 compatibility shims ----
try:
    xrange
except NameError:
    xrange = range

try:
    from io import BytesIO
except ImportError:
    from StringIO import StringIO as BytesIO


class Solver(object):
    def __init__(self, workers=None, input_file_name=None, output_file_name=None):
        self.input_file_name = input_file_name
        self.output_file_name = output_file_name
        self.workers = workers or []
        print("Solver initialized")
        print("Workers: {}".format(len(self.workers)))

    # -------------------------------------------------
    # Main entrypoint
    # -------------------------------------------------
    def solve(self):
        try:
            print("Job started - Google Maps parallel tile download and stitching")

            # ---- Read input (single region) ----
            center_lat, center_lon, height_m, width_m, compress = self.read_input()
            print("Center: ({}, {})".format(center_lat, center_lon))
            print("Size: {}m x {}m".format(width_m, height_m))
            print("Compression: {}".format("Enabled (max 100MB)" if compress else "Disabled"))

            # ---- Process and build mosaic ----
            temp_output = "temp_output.png"
            self.process_region(center_lat, center_lon, width_m, height_m, temp_output, compress)

            # ---- Write result ----
            if self.output_file_name:
                with open(temp_output, "rb") as src, open(self.output_file_name, "wb") as dst:
                    dst.write(src.read())
                try:
                    size_mb = os.path.getsize(self.output_file_name) / (1024.0 * 1024.0)
                    print("Output written to {} ({:.2f} MB)".format(self.output_file_name, size_mb))
                except Exception:
                    pass

            print("Job completed successfully!")

        except Exception:
            tb = traceback.format_exc()
            print(tb)
            out = self.output_file_name or "error.txt"
            try:
                with open(out, "w") as f:
                    f.write(tb)
            except Exception:
                pass
            raise

    # -------------------------------------------------
    # Region processing
    # -------------------------------------------------
    def process_region(self, center_lat, center_lon, width_m, height_m, output_path, compress=False):
        """Download tiles (via workers) and stitch to a mosaic."""
        zoom = 19
        tile_size_px = 640
        scale = 2
        resolution_m = 100
        crop_bottom = 40

        # ---- Grid ----
        num_cols = max(1, int(width_m / resolution_m))
        num_rows = max(1, int(height_m / resolution_m))
        total_tiles = num_cols * num_rows
        print("Grid: {}x{} = {} tiles".format(num_rows, num_cols, total_tiles))

        # ---- Tile centers ----
        tile_requests = self.calculate_tile_coordinates(
            center_lat, center_lon, num_rows, num_cols, zoom, tile_size_px
        )

        # ---- Dispatch ----
        num_workers = len(self.workers)
        print("Distributing {} tiles across {} workers".format(len(tile_requests), num_workers))
        downloaded_tiles = []

        if num_workers == 0:
            print("No workers available; downloading tiles sequentially...")
            downloaded_tiles = Solver.download_tiles(tile_requests, zoom, tile_size_px, scale, crop_bottom)
        else:
            tiles_per_worker = max(1, len(tile_requests) // num_workers)
            worker_tasks = []
            for i, worker in enumerate(self.workers):
                start_idx = i * tiles_per_worker
                end_idx = start_idx + tiles_per_worker if i < num_workers - 1 else len(tile_requests)
                if start_idx < len(tile_requests):
                    batch = tile_requests[start_idx:end_idx]
                    print("Worker {}: downloading {} tiles".format(i, len(batch)))
                    fut = worker.download_tiles(batch, zoom, tile_size_px, scale, crop_bottom)
                    worker_tasks.append(fut)

            print("Waiting for workers to download tiles...")
            for i, fut in enumerate(worker_tasks):
                tiles = fut.value
                print("Worker {} completed: {} tiles downloaded".format(i, len(tiles)))
                downloaded_tiles.extend(tiles)

        print("Total tiles downloaded: {}".format(len(downloaded_tiles)))

        # ---- Stitch ----
        print("Stitching tiles into mosaic...")
        self.create_mosaic(downloaded_tiles, num_rows, num_cols, tile_size_px, scale,
                           crop_bottom, output_path, compress)
        print("Mosaic saved to {}".format(output_path))

    # -------------------------------------------------
    # Tile coordinate generation
    # -------------------------------------------------
    def calculate_tile_coordinates(self, center_lat, center_lon, num_rows, num_cols, zoom, tile_size_px):
        """Compute tile center coordinates."""
        world_px = 256 * (2 ** zoom)

        def latlon_to_pixel(lat, lon):
            x = (lon + 180.0) / 360.0 * world_px
            siny = math.sin(math.radians(lat))
            y = (0.5 - math.log((1 + siny) / (1 - siny)) / (4 * math.pi)) * world_px
            return x, y

        def pixel_to_latlon(x, y):
            lon = x / float(world_px) * 360.0 - 180.0
            n = math.pi - 2.0 * math.pi * y / float(world_px)
            lat = math.degrees(math.atan(math.sinh(n)))
            return lat, lon

        cx, cy = latlon_to_pixel(center_lat, center_lon)
        step_px = tile_size_px
        tiles = []
        for i in xrange(num_rows):
            for j in xrange(num_cols):
                dx = (j - (num_cols - 1) / 2.0) * step_px
                dy = (i - (num_rows - 1) / 2.0) * step_px
                x = cx + dx
                y = cy + dy
                lat, lon = pixel_to_latlon(x, y)
                tiles.append({'lat': lat, 'lon': lon, 'row': i, 'col': j})
        return tiles

    # -------------------------------------------------
    # Mosaic creation
    # -------------------------------------------------
    def create_mosaic(self, tiles, num_rows, num_cols, tile_size_px, scale, crop_bottom,
                      output_path, compress=False):
        """Combine tiles into a single mosaic image."""
        original_tile = tile_size_px * scale
        cropped_h = original_tile - crop_bottom
        cropped_w = original_tile
        mosaic_w = num_cols * cropped_w
        mosaic_h = num_rows * cropped_h
        print("Creating mosaic: {}x{} px (tile {}x{})".format(mosaic_w, mosaic_h, cropped_w, cropped_h))

        tiles.sort(key=lambda t: (t['row'], t['col']))
        est_mb = (mosaic_w * mosaic_h * 3) / (1024.0 * 1024.0)
        print("Estimated uncompressed size: {:.1f}MB".format(est_mb))

        if not compress and est_mb <= 500:
            mosaic = Image.new('RGB', (mosaic_w, mosaic_h), color=(0, 0, 0))
            for t in tiles:
                data = t.get('image_data')
                if not data:
                    continue
                try:
                    if isinstance(data, bytes):
                        img_data = base64.b64decode(data)
                    else:
                        img_data = base64.b64decode(data.encode('utf-8'))
                    img = Image.open(BytesIO(img_data))
                    mosaic.paste(img, (t['col'] * cropped_w, t['row'] * cropped_h))
                except Exception as e:
                    print("Error placing tile ({}, {}): {}".format(t['row'], t['col'], e))
            mosaic.save(output_path, format='PNG')
            return

        self._create_mosaic_progressive(tiles, num_rows, num_cols, cropped_w, cropped_h,
                                        mosaic_w, mosaic_h, output_path, compress)

    # -------------------------------------------------
    def _create_mosaic_progressive(self, tiles, num_rows, num_cols, tile_w, tile_h,
                                   mosaic_w, mosaic_h, output_path, compress):
        print("Using progressive stitching for memory efficiency...")
        tile_dict = {(t['row'], t['col']): t for t in tiles if t.get('image_data')}
        base_quality = 75 if compress else 92
        target_mb = 100 if compress else None
        mosaic = Image.new('RGB', (mosaic_w, mosaic_h), color=(0, 0, 0))

        for row in xrange(num_rows):
            for col in xrange(num_cols):
                t = tile_dict.get((row, col))
                if not t:
                    continue
                try:
                    data = t.get('image_data')
                    if isinstance(data, bytes):
                        img_data = base64.b64decode(data)
                    else:
                        img_data = base64.b64decode(data.encode('utf-8'))
                    img = Image.open(BytesIO(img_data))
                    mosaic.paste(img, (col * tile_w, row * tile_h))
                    img.close()
                except Exception as e:
                    print("Error placing tile ({}, {}): {}".format(row, col, e))

        print("Saving mosaic...")
        if compress and target_mb:
            self._save_with_smart_compression(mosaic, output_path, target_mb, base_quality)
        else:
            mosaic.save(output_path, format='JPEG', quality=base_quality, optimize=True)
            try:
                size_mb = os.path.getsize(output_path) / (1024.0 * 1024.0)
                print("Saved: {:.2f}MB".format(size_mb))
            except Exception:
                pass

    # -------------------------------------------------
    def _save_with_smart_compression(self, image, output_path, target_mb, start_quality):
        max_bytes = target_mb * 1024 * 1024
        w, h = image.size
        est_full = (w * h * 3) / (1024.0 * 1024.0)
        print("Original size: {}x{} (~{:.0f}MB RGB)".format(w, h, est_full))

        if est_full > target_mb * 20:
            print("Very large image - aggressive downscaling first...")
            target_pixels = target_mb * 500000.0
            current_pixels = float(w) * float(h)
            scale = min(0.45, (target_pixels / current_pixels) ** 0.5)
            new_w = max(1, int(w * scale))
            new_h = max(1, int(h * scale))
            print("Downscaling to {:.0%} ({}x{})".format(scale, new_w, new_h))
            resized = image.resize((new_w, new_h), Image.LANCZOS)
            resized.save(output_path, format='JPEG', quality=80, optimize=True)
            return

        for q in (start_quality, 60, 45):
            buf = BytesIO()
            image.save(buf, format='JPEG', quality=q, optimize=True)
            size = buf.tell()
            if size <= max_bytes:
                with open(output_path, "wb") as f:
                    f.write(buf.getvalue())
                print("Quality {} OK ({:.2f}MB)".format(q, size / (1024.0 * 1024.0)))
                return
            else:
                print("Quality {} too large ({:.2f}MB)".format(q, size / (1024.0 * 1024.0)))

        resized = image.resize((int(w * 0.7), int(h * 0.7)), Image.LANCZOS)
        resized.save(output_path, format='JPEG', quality=75, optimize=True)
        print("Final: downscaled to 70% and saved")

    # -------------------------------------------------
    def read_input(self):
        with open(self.input_file_name, "r") as f:
            lines = [line.strip() for line in f if line.strip()]
        lat = float(lines[0])
        lon = float(lines[1])
        h = float(lines[2])
        w = float(lines[3])
        compress = int(lines[4]) == 1
        return lat, lon, h, w, compress

    # -------------------------------------------------
    @staticmethod
    @expose
    def download_tiles(tile_requests, zoom, tile_size_px, scale, crop_bottom=40):
        print("Worker downloading {} tiles...".format(len(tile_requests)))
        api_key = os.environ.get('GMAPS_KEY') or os.environ.get('GOOGLE_MAPS_API_KEY')
        if not api_key:
            print("ERROR: No Google Maps API key found in environment!")
            return []

        base_url = "https://maps.googleapis.com/maps/api/staticmap"
        results = []

        for idx, req in enumerate(tile_requests):
            lat = req['lat']; lon = req['lon']
            row = req['row']; col = req['col']
            params = {
                'center': '{:.10f},{:.10f}'.format(lat, lon),
                'zoom': zoom,
                'size': '{}x{}'.format(tile_size_px, tile_size_px),
                'scale': scale,
                'maptype': 'satellite',
                'format': 'jpg',
                'key': api_key
            }

            image_data = None
            for attempt in range(3):
                try:
                    time.sleep(0.1)
                    r = requests.get(base_url, params=params, timeout=15)
                    r.raise_for_status()
                    if r.headers.get('content-type', '').startswith('image'):
                        img = Image.open(BytesIO(r.content))
                        w, h = img.size
                        cropped = img.crop((0, 0, w, h - crop_bottom))
                        buf = BytesIO()
                        cropped.save(buf, format='JPEG', quality=95)
                        image_data = base64.b64encode(buf.getvalue())
                        break
                    else:
                        print("Non-image response for tile ({}, {})".format(row, col))
                except Exception as e:
                    if attempt < 2:
                        print("Retry {} for tile ({}, {}): {}".format(attempt + 1, row, col, e))
                        time.sleep(1)
                    else:
                        print("Failed tile ({}, {}): {}".format(row, col, e))

            results.append({'row': row, 'col': col, 'image_data': image_data})
            if (idx + 1) % 10 == 0:
                print("Progress: {}/{}".format(idx + 1, len(tile_requests)))

        ok = len([r for r in results if r.get('image_data')])
        print("Worker completed: {} successful downloads".format(ok))
        return results
