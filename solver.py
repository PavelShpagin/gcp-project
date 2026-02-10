from __future__ import print_function, division

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

    def solve(self):
        try:
            print("Job started - Google Maps parallel tile download and stitching")

            center_lat, center_lon, height_m, width_m, compress = self.read_input()
            print("Center: ({}, {})".format(center_lat, center_lon))
            print("Size: {}m x {}m".format(width_m, height_m))
            print("Compression: {}".format("Enabled (max 100MB)" if compress else "Disabled"))

            temp_output = "temp_output.png"
            self.process_region(center_lat, center_lon, width_m, height_m, temp_output, compress)

            if self.output_file_name:
                print("Encoding output for PARCS UI...")
                with open(temp_output, "rb") as img_file:
                    img_data = img_file.read()
                    img_base64 = base64.b64encode(img_data)
                    if not isinstance(img_base64, str):
                        img_base64 = img_base64.decode('utf-8')
                
                with open(self.output_file_name, "w") as out_file:
                    out_file.write("PNG_BASE64_START\n")
                    out_file.write(img_base64)
                    out_file.write("\nPNG_BASE64_END\n")
                
                size_mb = len(img_data) / (1024.0 * 1024.0)
                print("Output written to {} ({:.2f} MB)".format(self.output_file_name, size_mb))
                print("Download from PARCS UI and decode with: python decode_output.py output.txt map.png")

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

    def process_region(self, center_lat, center_lon, width_m, height_m, output_path, compress=False):
        """Download tiles (via workers) and stitch to a mosaic."""
        zoom = 19
        tile_size_px = 640
        scale = 2
        resolution_m = 100
        crop_bottom = 40

        num_cols = max(1, int(width_m / resolution_m))
        num_rows = max(1, int(height_m / resolution_m))
        total_tiles = num_cols * num_rows
        print("Grid: {}x{} = {} tiles".format(num_rows, num_cols, total_tiles))

        tile_requests = self.calculate_tile_coordinates(
            center_lat, center_lon, num_rows, num_cols, zoom, tile_size_px
        )

        num_workers = len(self.workers)
        print("Distributing {} tiles across {} workers".format(len(tile_requests), num_workers))
        downloaded_tiles = []

        if num_workers == 0:
            print("No workers available; downloading tiles sequentially...")
            # Process in batches to prevent OOM on large jobs
            batch_size = 50  # Process 50 tiles at a time
            downloaded_tiles = []
            for i in xrange(0, len(tile_requests), batch_size):
                batch = tile_requests[i:i + batch_size]
                print("Processing batch {}/{} ({} tiles)...".format(
                    i // batch_size + 1, (len(tile_requests) + batch_size - 1) // batch_size, len(batch)))
                batch_tiles = Solver.download_tiles(batch, zoom, tile_size_px, scale, crop_bottom)
                downloaded_tiles.extend(batch_tiles)
                # Explicit cleanup after each batch
                del batch_tiles
                try:
                    import gc
                    gc.collect()
                except Exception:
                    pass
        else:
            # Round-robin distribution for better load balancing
            worker_tasks = []
            for i, worker in enumerate(self.workers):
                # Distribute tiles round-robin: worker i gets tiles at indices i, i+N, i+2N, ...
                batch = [tile_requests[j] for j in xrange(i, len(tile_requests), num_workers)]
                if batch:
                    print("Worker {}: downloading {} tiles".format(i, len(batch)))
                    fut = worker.download_tiles(batch, zoom, tile_size_px, scale, crop_bottom)
                    worker_tasks.append((i, fut))

            print("Waiting for workers to download tiles...")
            for i, fut in worker_tasks:
                tiles = fut.value
                print("Worker {} completed: {} tiles downloaded".format(i, len(tiles)))
                downloaded_tiles.extend(tiles)

        print("Total tiles downloaded: {}".format(len(downloaded_tiles)))

        print("Stitching tiles into mosaic...")
        self.create_mosaic(downloaded_tiles, num_rows, num_cols, tile_size_px, scale,
                           crop_bottom, output_path, compress)
        print("Mosaic saved to {}".format(output_path))

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

    def _create_mosaic_progressive(self, tiles, num_rows, num_cols, tile_w, tile_h,
                                   mosaic_w, mosaic_h, output_path, compress):
        print("Using progressive stitching for memory efficiency...")
        tile_dict = {(t['row'], t['col']): t for t in tiles if t.get('image_data')}
        
        est_mb = (mosaic_w * mosaic_h * 3) / (1024.0 * 1024.0)
        
        if compress and est_mb > 500:
            print("Large mosaic detected - will build at reduced scale...")
            target_mb = 800
            scale_factor = min(0.4, (target_mb / est_mb) ** 0.5)
            scaled_w = max(1, int(tile_w * scale_factor))
            scaled_h = max(1, int(tile_h * scale_factor))
            scaled_mosaic_w = num_cols * scaled_w
            scaled_mosaic_h = num_rows * scaled_h
            print("Building at {:.0%} scale ({} x {})".format(
                scale_factor, scaled_mosaic_w, scaled_mosaic_h))
            
            mosaic = Image.new('RGB', (scaled_mosaic_w, scaled_mosaic_h), color=(0, 0, 0))
            
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
                        
                        scaled_tile = img.resize((scaled_w, scaled_h), Image.LANCZOS)
                        img.close()
                        
                        mosaic.paste(scaled_tile, (col * scaled_w, row * scaled_h))
                        scaled_tile.close()
                    except Exception as e:
                        print("Error placing tile ({}, {}): {}".format(row, col, e))
            
            print("Saving scaled mosaic...")
            mosaic.save(output_path, format='JPEG', quality=75, optimize=True)
            size_mb = os.path.getsize(output_path) / (1024.0 * 1024.0)
            print("Saved: {:.2f}MB at {:.0%} scale".format(size_mb, scale_factor))
            return
        
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

    def read_input(self):
        with open(self.input_file_name, "r") as f:
            lines = [line.strip() for line in f if line.strip()]
        lat = float(lines[0])
        lon = float(lines[1])
        h = float(lines[2])
        w = float(lines[3])
        compress = int(lines[4]) == 1
        return lat, lon, h, w, compress

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

        session = requests.Session()
        session.headers.update({'Connection': 'keep-alive'})

        throttle_delay = 0.05

        batch_size = len(tile_requests)
        if batch_size >= 50:
            jpeg_quality = 45
        else:
            jpeg_quality = 60

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
            r = None
            for attempt in range(3):
                try:
                    time.sleep(throttle_delay)
                    r = session.get(base_url, params=params, timeout=15)
                    r.raise_for_status()
                    if r.headers.get('content-type', '').startswith('image'):
                        response_content = r.content
                        img = Image.open(BytesIO(response_content))
                        w, h = img.size
                        
                        cropped = img.crop((0, 0, w, h - crop_bottom))
                        img.close()
                        del img
                        
                        buf = BytesIO()
                        cropped.save(buf, format='JPEG', quality=jpeg_quality, optimize=True)
                        cropped.close()
                        del cropped
                        
                        image_data = base64.b64encode(buf.getvalue())
                        buf.close()
                        del buf
                        del response_content
                        break
                    else:
                        print("Non-image response for tile ({}, {})".format(row, col))
                        break
                except Exception as e:
                    if attempt < 2:
                        print("Retry {} for tile ({}, {}): {}".format(attempt + 1, row, col, e))
                        time.sleep(1)
                    else:
                        print("Failed tile ({}, {}): {}".format(row, col, e))
                finally:
                    if r is not None:
                        try:
                            r.close()
                        except Exception:
                            pass
                        del r

            results.append({'row': row, 'col': col, 'image_data': image_data})
            if (idx + 1) % 10 == 0:
                print("Progress: {}/{}".format(idx + 1, len(tile_requests)))
                if batch_size >= 50:
                    try:
                        import gc
                        gc.collect()
                    except Exception:
                        pass

        session.close()
        ok = len([r for r in results if r.get('image_data')])
        print("Worker completed: {} successful downloads".format(ok))
        return results
