using System;

namespace ParcsNetMapsStitcher.Models
{
    [Serializable]
    public sealed class TileResult
    {
        public int Row { get; set; }
        public int Col { get; set; }

        // Cropped + recompressed JPEG bytes (or dummy tile bytes in dry-run mode).
        public byte[]? ImageBytes { get; set; }
    }
}
