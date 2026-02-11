using System;

namespace ParcsNetMapsStitcher.Models
{
    [Serializable]
    public sealed class TileDownloadTask
    {
        public TileRequest[] Requests { get; set; } = Array.Empty<TileRequest>();

        public int Zoom { get; set; } = 19;
        public int TileSizePx { get; set; } = 640;
        public int Scale { get; set; } = 2;
        public int CropBottom { get; set; } = 40;
        public int Concurrency { get; set; } = 1;

        public bool DryRun { get; set; }

        /// <summary>
        /// When true, uses parallel downloads with thread pool optimization.
        /// When false (default), uses sequential downloads for baseline measurement.
        /// </summary>
        public bool Optimized { get; set; }
    }
}
