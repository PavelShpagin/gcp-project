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

        public bool DryRun { get; set; }
    }
}
