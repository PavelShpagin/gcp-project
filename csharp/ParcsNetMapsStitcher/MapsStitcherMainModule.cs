using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using CommandLine;
using Parcs;
using ParcsNetMapsStitcher.Models;

namespace ParcsNetMapsStitcher
{
    public sealed class MapsStitcherMainModule : MainModule
    {
        private static CommandLineOptions _options = new CommandLineOptions();

        public static void Main(string[] args)
        {
            var parseResult = Parser.Default.ParseArguments<CommandLineOptions>(args ?? Array.Empty<string>());
            parseResult
                .WithParsed(opts => _options = opts)
                .WithNotParsed(_ =>
                {
                    throw new ArgumentException(
                        $@"Cannot parse the arguments. Possible usages:
{new CommandLineOptions().GetUsage()}");
                });

            new MapsStitcherMainModule().RunModule(_options);
        }

        public override void Run(ModuleInfo info, CancellationToken token = default(CancellationToken))
        {
            try
            {
                Console.WriteLine("Job started - Google Maps parallel tile download and stitching (Parcs.NET)");

                var (centerLat, centerLon, heightM, widthM, compress) = ReadInput(_options.InputFile);
                Console.WriteLine($"Center: ({centerLat}, {centerLon})");
                Console.WriteLine($"Size: {widthM}m x {heightM}m");
                Console.WriteLine($"Compression: {(compress ? "Enabled (target ~100MB)" : "Disabled")}");
                Console.WriteLine($"Mode: {(_options.DryRun ? "Dry-run (dummy tiles)" : "Live (Google Maps API)")}");

                const int zoom = 19;
                const int tileSizePx = 640;
                const int scale = 2;
                const int resolutionM = 100;
                const int cropBottom = 40;

                var numCols = Math.Max(1, (int)(widthM / resolutionM));
                var numRows = Math.Max(1, (int)(heightM / resolutionM));
                var totalTiles = numCols * numRows;
                Console.WriteLine($"Grid: {numRows}x{numCols} = {totalTiles} tiles");

                var allTileRequests = MapsTiling.CalculateTileCoordinates(centerLat, centerLon, numRows, numCols, zoom, tileSizePx);
                
                // Apply tile range filter for federated mode
                var tileStart = Math.Max(0, _options.TileStart);
                var tileEnd = _options.TileEnd < 0 ? allTileRequests.Count : Math.Min(_options.TileEnd, allTileRequests.Count);
                var tileRequests = allTileRequests.Skip(tileStart).Take(tileEnd - tileStart).ToList();
                
                if (tileStart > 0 || tileEnd < allTileRequests.Count)
                {
                    Console.WriteLine($"Federated mode: tiles [{tileStart}, {tileEnd}) of {allTileRequests.Count}");
                }
                Console.WriteLine($"Distributing {tileRequests.Count} tiles across {_options.PointsNum} points");
                Console.WriteLine($"Execution settings: concurrency={_options.Concurrency}, optimized={_options.Optimized}");

                var swTotal = Stopwatch.StartNew();

                var swDownload = Stopwatch.StartNew();
                var downloadedTiles = DownloadTiles(info, tileRequests, _options.PointsNum, _options.DryRun, zoom, tileSizePx, scale, cropBottom, _options.Concurrency, _options.Optimized, token);
                swDownload.Stop();
                Console.WriteLine($"Download phase: {swDownload.Elapsed.TotalSeconds:F3}s");

                if (_options.DownloadOnly)
                {
                    // Output raw tile data for federated merge
                    WriteTileDataOutput(_options.OutputFile, downloadedTiles, numRows, numCols);
                    Console.WriteLine($"Total time: {swDownload.Elapsed.TotalSeconds:F3}s");
                    Console.WriteLine("Download-only mode completed!");
                    return;
                }

                var outputDir = GetOutputDirectory(_options.OutputFile);

                var swMosaic = Stopwatch.StartNew();
                var (imagePath, format) = MosaicBuilder.CreateMosaic(
                    downloadedTiles,
                    numRows,
                    numCols,
                    tileSizePx,
                    scale,
                    cropBottom,
                    compress,
                    outputDir);
                swMosaic.Stop();
                Console.WriteLine($"Mosaic phase: {swMosaic.Elapsed.TotalSeconds:F3}s");

                WriteParcsOutput(_options.OutputFile, imagePath, format);

                swTotal.Stop();
                Console.WriteLine($"Total time: {swTotal.Elapsed.TotalSeconds:F3}s");
                Console.WriteLine("Job completed successfully!");
            }
            catch (Exception ex)
            {
                var tb = ex.ToString();
                Console.WriteLine(tb);

                try
                {
                    var outPath = string.IsNullOrWhiteSpace(_options.OutputFile) ? "error.txt" : _options.OutputFile;
                    File.WriteAllText(outPath, tb, Encoding.UTF8);
                }
                catch
                {
                    // ignored
                }

                throw;
            }
        }

        private static List<TileResult> DownloadTiles(
            ModuleInfo info,
            IReadOnlyList<TileRequest> tileRequests,
            int pointsNum,
            bool dryRun,
            int zoom,
            int tileSizePx,
            int scale,
            int cropBottom,
            int concurrency,
            bool optimized,
            CancellationToken token)
        {
            var jpegQuality = tileRequests.Count >= 50 ? 45 : 60;
            var startDelayMs = GetPointStartDelayMs();

            if (pointsNum <= 0)
            {
                Console.WriteLine("No points requested; downloading sequentially on master...");
                var task = new TileDownloadTask
                {
                    Requests = tileRequests.ToArray(),
                    Zoom = zoom,
                    TileSizePx = tileSizePx,
                    Scale = scale,
                    CropBottom = cropBottom,
                    DryRun = dryRun,
                    Concurrency = concurrency,
                    Optimized = optimized
                };

                var results = TileDownloader.DownloadTiles(task, token).ToList();
                ProcessTilesOnMaster(results, tileSizePx, scale, cropBottom, dryRun, jpegQuality);
                return results;
            }

            var points = new IPoint[pointsNum];
            var channels = new IChannel[pointsNum];

            var tasks = new TileDownloadTask[pointsNum];
            for (var i = 0; i < pointsNum; i++)
            {
                points[i] = info.CreatePoint();
                channels[i] = points[i].CreateChannel();
                points[i].ExecuteClass("ParcsNetMapsStitcher.MapsWorkerModule");

                if (startDelayMs > 0 && i < pointsNum - 1)
                {
                    // Stagger point startup to avoid concurrent module cache file access on the same daemon.
                    Thread.Sleep(startDelayMs);
                }

                // Round-robin distribution (worker i gets i, i+N, i+2N, ...).
                var assigned = new List<TileRequest>();
                for (var j = i; j < tileRequests.Count; j += pointsNum)
                {
                    assigned.Add(tileRequests[j]);
                }

                Console.WriteLine($"Point {i}: downloading {assigned.Count} tiles");
                Console.WriteLine($"Point {i} settings: concurrency={concurrency}, optimized={optimized}");
                tasks[i] = new TileDownloadTask
                {
                    Requests = assigned.ToArray(),
                    Zoom = zoom,
                    TileSizePx = tileSizePx,
                    Scale = scale,
                    CropBottom = cropBottom,
                    DryRun = dryRun,
                    Concurrency = concurrency,
                    Optimized = optimized
                };
            }

            // Send tasks.
            for (var i = 0; i < pointsNum; i++)
            {
                channels[i].WriteObject(tasks[i]);
            }

            Console.WriteLine("Waiting for points to download tiles...");

            var all = new List<TileResult>(tileRequests.Count);
            for (var i = 0; i < pointsNum; i++)
            {
                var part = channels[i].ReadObject<TileResult[]>();
                Console.WriteLine($"Point {i} completed: {part.Length} tiles returned");
                all.AddRange(part);
            }

            Console.WriteLine($"Total tiles downloaded: {all.Count}");
            ProcessTilesOnMaster(all, tileSizePx, scale, cropBottom, dryRun, jpegQuality);
            return all;
        }

        private static void ProcessTilesOnMaster(
            List<TileResult> tiles,
            int tileSizePx,
            int scale,
            int cropBottom,
            bool dryRun,
            int jpegQuality)
        {
            if (dryRun)
            {
                var w = tileSizePx * scale;
                var h = Math.Max(1, w - cropBottom);
                foreach (var t in tiles)
                {
                    t.ImageBytes = TileImageProcessor.CreateDummyTileJpeg(w, h, t.Row, t.Col, jpegQuality);
                }

                return;
            }

            foreach (var t in tiles)
            {
                var bytes = t.ImageBytes;
                if (bytes == null || bytes.Length == 0)
                {
                    continue;
                }

                t.ImageBytes = TileImageProcessor.CropAndReencodeJpeg(bytes, cropBottom, jpegQuality);
            }
        }

        private static (double lat, double lon, double heightM, double widthM, bool compress) ReadInput(string inputPath)
        {
            if (string.IsNullOrWhiteSpace(inputPath))
            {
                throw new ArgumentException("Input file path is required. Use --input <path>.");
            }

            var lines = File.ReadAllLines(inputPath)
                .Select(l => l.Trim())
                .Where(l => !string.IsNullOrWhiteSpace(l))
                .ToArray();

            if (lines.Length < 5)
            {
                throw new InvalidOperationException("Input file must contain 5 non-empty lines: lat, lon, height_m, width_m, compress_flag.");
            }

            var lat = double.Parse(lines[0], CultureInfo.InvariantCulture);
            var lon = double.Parse(lines[1], CultureInfo.InvariantCulture);
            var h = double.Parse(lines[2], CultureInfo.InvariantCulture);
            var w = double.Parse(lines[3], CultureInfo.InvariantCulture);
            var compress = int.Parse(lines[4], CultureInfo.InvariantCulture) == 1;
            return (lat, lon, h, w, compress);
        }

        private static void WriteParcsOutput(string outputFile, string imagePath, string format)
        {
            if (string.IsNullOrWhiteSpace(outputFile))
            {
                Console.WriteLine("No output file specified; skipping base64 output.");
                return;
            }

            Console.WriteLine("Encoding output for PARCS UI...");

            var bytes = File.ReadAllBytes(imagePath);
            var base64 = Convert.ToBase64String(bytes);
            var sizeMb = bytes.Length / (1024.0 * 1024.0);

            using (var writer = new StreamWriter(outputFile, false, Encoding.UTF8))
            {
                writer.WriteLine($"FORMAT={format}");
                writer.WriteLine("PNG_BASE64_START");
                writer.WriteLine(base64);
                writer.WriteLine("PNG_BASE64_END");
            }

            Console.WriteLine($"Output written to {outputFile} ({sizeMb:F2} MB)");
            Console.WriteLine("Decode with: python decode_output.py output.txt map.png (or map.jpg if FORMAT=JPEG)");
        }

        private static void WriteTileDataOutput(string outputFile, List<TileResult> tiles, int numRows, int numCols)
        {
            Console.WriteLine($"Writing {tiles.Count} tiles to {outputFile}...");
            
            using (var writer = new StreamWriter(outputFile, false, Encoding.UTF8))
            {
                writer.WriteLine($"TILES_DATA");
                writer.WriteLine($"ROWS={numRows}");
                writer.WriteLine($"COLS={numCols}");
                writer.WriteLine($"COUNT={tiles.Count}");
                
                foreach (var t in tiles)
                {
                    if (t.ImageBytes == null || t.ImageBytes.Length == 0)
                    {
                        continue;
                    }
                    
                    var b64 = Convert.ToBase64String(t.ImageBytes);
                    writer.WriteLine($"TILE|{t.Row}|{t.Col}|{b64}");
                }
                
                writer.WriteLine("END_TILES_DATA");
            }
            
            var sizeMb = new FileInfo(outputFile).Length / (1024.0 * 1024.0);
            Console.WriteLine($"Tile data written: {sizeMb:F2} MB");
        }

        private static string GetOutputDirectory(string outputFile)
        {
            try
            {
                var full = Path.GetFullPath(string.IsNullOrWhiteSpace(outputFile) ? "output.txt" : outputFile);
                var dir = Path.GetDirectoryName(full);
                if (!string.IsNullOrWhiteSpace(dir))
                {
                    Directory.CreateDirectory(dir);
                    return dir;
                }
            }
            catch
            {
                // ignored
            }

            return Directory.GetCurrentDirectory();
        }

        private static int GetPointStartDelayMs()
        {
            var raw = Environment.GetEnvironmentVariable("PARCS_POINT_START_DELAY_MS");
            if (int.TryParse(raw, out var ms) && ms >= 0)
            {
                return ms;
            }

            return 300;
        }
    }
}
