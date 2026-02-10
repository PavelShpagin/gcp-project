using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using ParcsNetMapsStitcher.Models;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Advanced;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

namespace ParcsNetMapsStitcher
{
    internal static class MosaicBuilder
    {
        public static (string imagePath, string format) CreateMosaic(
            IReadOnlyCollection<TileResult> tiles,
            int numRows,
            int numCols,
            int tileSizePx,
            int scale,
            int cropBottom,
            bool compress,
            string workingDirectory)
        {
            var originalTile = tileSizePx * scale; // e.g. 1280
            var tileW = originalTile;
            var tileH = Math.Max(1, originalTile - cropBottom); // e.g. 1240
            var mosaicW = numCols * tileW;
            var mosaicH = numRows * tileH;

            Console.WriteLine($"Creating mosaic: {mosaicW}x{mosaicH} px (tile {tileW}x{tileH})");

            var estMb = (mosaicW * (double)mosaicH * 3.0) / (1024.0 * 1024.0);
            Console.WriteLine($"Estimated uncompressed size: {estMb:F1}MB");

            var sorted = tiles
                .Where(t => t.ImageBytes != null && t.ImageBytes.Length > 0)
                .OrderBy(t => t.Row)
                .ThenBy(t => t.Col)
                .ToList();

            if (!compress && estMb <= 500.0)
            {
                var outPath = Path.Combine(workingDirectory, "temp_output.png");
                using (var mosaic = new Image<Rgb24>(mosaicW, mosaicH, new Rgb24(0, 0, 0)))
                {
                    DrawTilesParallelByRow(mosaic, sorted, numRows, numCols, tileW, tileH);

                    mosaic.SaveAsPng(outPath);
                }

                return (outPath, "PNG");
            }

            // Progressive stitching for large images / compression mode.
            return CreateMosaicProgressive(sorted, numRows, numCols, tileW, tileH, mosaicW, mosaicH, compress, workingDirectory);
        }

        private static (string imagePath, string format) CreateMosaicProgressive(
            IReadOnlyList<TileResult> sortedTiles,
            int numRows,
            int numCols,
            int tileW,
            int tileH,
            int mosaicW,
            int mosaicH,
            bool compress,
            string workingDirectory)
        {
            Console.WriteLine("Using progressive stitching for memory efficiency...");

            var estMb = (mosaicW * (double)mosaicH * 3.0) / (1024.0 * 1024.0);

            var outPath = Path.Combine(workingDirectory, "temp_output.jpg");
            const int targetMb = 100;
            var baseQuality = compress ? 75 : 92;

            if (compress && estMb > 500.0)
            {
                Console.WriteLine("Large mosaic detected - will build at reduced scale...");
                const double targetRamMb = 800.0;
                var scaleFactor = Math.Min(0.4, Math.Sqrt(targetRamMb / estMb));

                var scaledW = Math.Max(1, (int)(tileW * scaleFactor));
                var scaledH = Math.Max(1, (int)(tileH * scaleFactor));
                var scaledMosaicW = numCols * scaledW;
                var scaledMosaicH = numRows * scaledH;

                Console.WriteLine($"Building at {scaleFactor:P0} scale ({scaledMosaicW} x {scaledMosaicH})");

                using (var mosaic = new Image<Rgb24>(scaledMosaicW, scaledMosaicH, new Rgb24(0, 0, 0)))
                {
                    DrawTilesParallelByRow(mosaic, sortedTiles, numRows, numCols, scaledW, scaledH);

                    Console.WriteLine("Saving scaled mosaic...");
                    SaveWithSmartCompression(mosaic, outPath, targetMb, baseQuality);
                }

                return (outPath, "JPEG");
            }

            using (var mosaic = new Image<Rgb24>(mosaicW, mosaicH, new Rgb24(0, 0, 0)))
            {
                DrawTilesParallelByRow(mosaic, sortedTiles, numRows, numCols, tileW, tileH);

                Console.WriteLine("Saving mosaic...");
                if (compress)
                {
                    SaveWithSmartCompression(mosaic, outPath, targetMb, baseQuality);
                }
                else
                {
                    SaveJpeg(mosaic, outPath, baseQuality);
                    TryLogFileSize(outPath);
                }
            }

            return (outPath, "JPEG");
        }

        private static void SaveWithSmartCompression(Image<Rgb24> image, string outputPath, int targetMb, int startQuality)
        {
            var maxBytes = targetMb * 1024L * 1024L;
            var w = image.Width;
            var h = image.Height;
            var estFullMb = (w * (double)h * 3.0) / (1024.0 * 1024.0);
            Console.WriteLine($"Original size: {w}x{h} (~{estFullMb:F0}MB RGB)");

            if (estFullMb > targetMb * 20.0)
            {
                Console.WriteLine("Very large image - aggressive downscaling first...");
                var targetPixels = targetMb * 500000.0;
                var currentPixels = w * (double)h;
                var scale = Math.Min(0.45, Math.Sqrt(targetPixels / currentPixels));
                var newW = Math.Max(1, (int)(w * scale));
                var newH = Math.Max(1, (int)(h * scale));
                Console.WriteLine($"Downscaling to {scale:P0} ({newW}x{newH})");

                using (var resized = ResizeImage(image, newW, newH))
                {
                    SaveJpeg(resized, outputPath, 80);
                }

                TryLogFileSize(outputPath);
                return;
            }

            foreach (var q in new[] { startQuality, 60, 45 })
            {
                var bytes = SaveJpegToBytes(image, q);
                if (bytes.LongLength <= maxBytes)
                {
                    File.WriteAllBytes(outputPath, bytes);
                    Console.WriteLine($"Quality {q} OK ({bytes.LongLength / (1024.0 * 1024.0):F2}MB)");
                    return;
                }

                Console.WriteLine($"Quality {q} too large ({bytes.LongLength / (1024.0 * 1024.0):F2}MB)");
            }

            // Final fallback: downscale and save.
            using (var resized = ResizeImage(image, (int)(w * 0.7), (int)(h * 0.7)))
            {
                SaveJpeg(resized, outputPath, 75);
            }

            Console.WriteLine("Final: downscaled to 70% and saved");
            TryLogFileSize(outputPath);
        }

        private static void DrawTile(Image<Rgb24> mosaic, byte[] tileBytes, int destX, int destY, int destW, int destH)
        {
            using (var tile = Image.Load<Rgb24>(tileBytes))
            {
                if (tile.Width != destW || tile.Height != destH)
                {
                    tile.Mutate(c => c.Resize(destW, destH, KnownResamplers.NearestNeighbor));
                }

                for (var y = 0; y < destH; y++)
                {
                    var srcRow = tile.DangerousGetPixelRowMemory(y).Span;
                    var destRow = mosaic.DangerousGetPixelRowMemory(destY + y).Span.Slice(destX, destW);
                    srcRow.Slice(0, destW).CopyTo(destRow);
                }
            }
        }

        private static void DrawTilesParallelByRow(
            Image<Rgb24> mosaic,
            IReadOnlyList<TileResult> tiles,
            int numRows,
            int numCols,
            int tileW,
            int tileH)
        {
            var grid = new TileResult?[numRows, numCols];
            foreach (var t in tiles)
            {
                if (t.Row < 0 || t.Row >= numRows || t.Col < 0 || t.Col >= numCols)
                {
                    continue;
                }

                grid[t.Row, t.Col] = t;
            }

            Parallel.For(0, numRows, row =>
            {
                var destY = row * tileH;
                for (var col = 0; col < numCols; col++)
                {
                    var t = grid[row, col];
                    var bytes = t?.ImageBytes;
                    if (bytes == null || bytes.Length == 0)
                    {
                        continue;
                    }

                    var destX = col * tileW;
                    DrawTile(mosaic, bytes, destX, destY, tileW, tileH);
                }
            });
        }

        private static Image<Rgb24> ResizeImage(Image<Rgb24> source, int width, int height)
        {
            return source.Clone(c => c.Resize(width, height, KnownResamplers.Bicubic));
        }

        private static void SaveJpeg(Image<Rgb24> image, string outputPath, int quality)
        {
            image.SaveAsJpeg(outputPath, new JpegEncoder { Quality = quality });
        }

        private static byte[] SaveJpegToBytes(Image<Rgb24> image, int quality)
        {
            using (var ms = new MemoryStream())
            {
                image.SaveAsJpeg(ms, new JpegEncoder { Quality = quality });
                return ms.ToArray();
            }
        }

        private static void TryLogFileSize(string path)
        {
            try
            {
                var sizeMb = new FileInfo(path).Length / (1024.0 * 1024.0);
                Console.WriteLine($"Saved: {sizeMb:F2}MB");
            }
            catch
            {
                // ignored
            }
        }
    }
}
