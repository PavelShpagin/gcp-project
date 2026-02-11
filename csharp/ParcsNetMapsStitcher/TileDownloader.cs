using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using ParcsNetMapsStitcher.Models;

namespace ParcsNetMapsStitcher
{
    internal static class TileDownloader
    {
        private static readonly HttpClient Client = CreateHttpClient();

        public static TileResult[] DownloadTiles(TileDownloadTask task, CancellationToken token)
        {
            Console.WriteLine($"Worker downloading {task.Requests.Length} tiles (optimized={task.Optimized})...");

            var throttleSeconds = GetThrottleSeconds();

            var apiKey = task.DryRun ? null : GetApiKey();
            if (!task.DryRun && string.IsNullOrWhiteSpace(apiKey))
            {
                throw new InvalidOperationException(
                    "No Google Maps API key found. Set GMAPS_KEY or GOOGLE_MAPS_API_KEY in the environment.");
            }

            TileResult[] results;

            if (task.Optimized && task.Concurrency > 1)
            {
                // Parallel mode: use thread pool optimization for maximum throughput
                results = DownloadTilesParallel(task, apiKey!, throttleSeconds, token);
            }
            else
            {
                // Sequential mode: true baseline without any parallelism or thread pool tricks
                results = DownloadTilesSequential(task, apiKey!, throttleSeconds, token);
            }

            var ok = results.Count(r => r.ImageBytes != null && r.ImageBytes.Length > 0);
            Console.WriteLine($"Worker completed: {ok} successful downloads");
            return results;
        }

        private static TileResult[] DownloadTilesSequential(
            TileDownloadTask task,
            string apiKey,
            double throttleSeconds,
            CancellationToken token)
        {
            var results = new List<TileResult>(task.Requests.Length);

            for (var idx = 0; idx < task.Requests.Length; idx++)
            {
                token.ThrowIfCancellationRequested();

                var req = task.Requests[idx];
                byte[]? imageBytes = null;

                if (!task.DryRun)
                {
                    // In sequential (baseline) mode, we use a fresh HttpClient for each request
                    // to simulate a naive implementation without connection pooling.
                    // This provides a fair "unoptimized" baseline to compare against.
                    using (var handler = new HttpClientHandler { AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate })
                    using (var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) })
                    {
                        imageBytes = DownloadSingleTileJpeg(
                            client,
                            apiKey,
                            req.Lat,
                            req.Lon,
                            task.Zoom,
                            task.TileSizePx,
                            task.Scale,
                            throttleSeconds,
                            token);
                    }
                }

                results.Add(new TileResult { Row = req.Row, Col = req.Col, ImageBytes = imageBytes });

                if ((idx + 1) % 10 == 0)
                {
                    Console.WriteLine($"Progress: {idx + 1}/{task.Requests.Length}");
                }
            }

            return results.ToArray();
        }

        private static TileResult[] DownloadTilesParallel(
            TileDownloadTask task,
            string apiKey,
            double throttleSeconds,
            CancellationToken token)
        {
            // Optimize thread pool for burst parallelism on single-core containers
            ThreadPool.SetMinThreads(32, 32);

            var results = new System.Collections.Concurrent.ConcurrentBag<TileResult>();
            var options = new ParallelOptions
            {
                CancellationToken = token,
                MaxDegreeOfParallelism = task.Concurrency > 0 ? task.Concurrency : 1
            };

            var count = 0;
            Parallel.ForEach(task.Requests, options, (req) =>
            {
                byte[]? imageBytes = null;

                if (!task.DryRun)
                {
                    imageBytes = DownloadSingleTileJpeg(
                        Client,
                        apiKey,
                        req.Lat,
                        req.Lon,
                        task.Zoom,
                        task.TileSizePx,
                        task.Scale,
                        throttleSeconds,
                        token);
                }

                results.Add(new TileResult { Row = req.Row, Col = req.Col, ImageBytes = imageBytes });

                var current = Interlocked.Increment(ref count);
                if (current % 10 == 0)
                {
                    Console.WriteLine($"Progress: {current}/{task.Requests.Length}");
                }
            });

            return results.ToArray();
        }

        // Random for cache-busting via tiny coordinate jitter (thread-safe)
        private static readonly ThreadLocal<Random> Rng = new ThreadLocal<Random>(() => new Random(Guid.NewGuid().GetHashCode()));

        private static byte[]? DownloadSingleTileJpeg(
            HttpClient client,
            string apiKey,
            double lat,
            double lon,
            int zoom,
            int tileSizePx,
            int scale,
            double throttleSeconds,
            CancellationToken token)
        {
            const string baseUrl = "https://maps.googleapis.com/maps/api/staticmap";

            // Add tiny random jitter to coordinates to bust CDN cache (imperceptible at zoom 19)
            // At zoom 19, 1e-7 degrees ~= 0.01 meters - invisible but unique
            var jitterLat = (Rng.Value!.NextDouble() - 0.5) * 2e-7;
            var jitterLon = (Rng.Value!.NextDouble() - 0.5) * 2e-7;

            var center = string.Format(
                CultureInfo.InvariantCulture,
                "{0:F10},{1:F10}",
                lat + jitterLat,
                lon + jitterLon);

            var url =
                $"{baseUrl}?center={Uri.EscapeDataString(center)}" +
                $"&zoom={zoom}" +
                $"&size={tileSizePx}x{tileSizePx}" +
                $"&scale={scale}" +
                $"&maptype=satellite" +
                $"&format=jpg" +
                $"&key={Uri.EscapeDataString(apiKey)}";

            for (var attempt = 0; attempt < 3; attempt++)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    if (throttleSeconds > 0)
                    {
                        Thread.Sleep(TimeSpan.FromSeconds(throttleSeconds));
                    }

                    using (var response = client.GetAsync(url, token).GetAwaiter().GetResult())
                    {
                        response.EnsureSuccessStatusCode();

                        var mediaType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;
                        if (!mediaType.StartsWith("image", StringComparison.OrdinalIgnoreCase))
                        {
                            Console.WriteLine("Non-image response for tile");
                            return null;
                        }

                        var originalBytes = response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
                        return originalBytes;
                    }
                }
                catch (Exception ex) when (attempt < 2)
                {
                    // IMPORTANT: don't print the request URL (contains API key).
                    Console.WriteLine($"Retry {attempt + 1} for tile: {ex.GetType().Name}");
                    Thread.Sleep(TimeSpan.FromSeconds(1));
                }
                catch (Exception ex)
                {
                    // IMPORTANT: don't print the request URL (contains API key).
                    Console.WriteLine($"Failed tile: {ex.GetType().Name}");
                    return null;
                }
            }

            return null;
        }

        private static string? GetApiKey()
        {
            return Environment.GetEnvironmentVariable("GMAPS_KEY")
                ?? Environment.GetEnvironmentVariable("GOOGLE_MAPS_API_KEY");
        }

        private static double GetThrottleSeconds()
        {
            var raw = Environment.GetEnvironmentVariable("GMAPS_THROTTLE_SECONDS");
            if (string.IsNullOrWhiteSpace(raw))
            {
                return 0; // No throttle by default - allows true parallel downloads
            }

            if (double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && seconds >= 0)
            {
                return seconds;
            }

            return 0;
        }

        private static HttpClient CreateHttpClient()
        {
            // .NET Framework + TLS defaults can vary; this makes HTTPS more reliable.
#if NET48
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            ServicePointManager.DefaultConnectionLimit = 256;
#endif

            var handler = new HttpClientHandler
            {
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
            };
#if !NET48
            try
            {
                handler.MaxConnectionsPerServer = 50;
            }
            catch
            {
                // Ignore if platform doesn't support it
            }
#endif

            var client = new HttpClient(handler)
            {
                Timeout = TimeSpan.FromSeconds(15)
            };

            client.DefaultRequestHeaders.ConnectionClose = false;
            return client;
        }
    }
}