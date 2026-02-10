using System;

namespace ParcsNetMapsStitcher.Models
{
    [Serializable]
    public sealed class TileRequest
    {
        public double Lat { get; set; }
        public double Lon { get; set; }
        public int Row { get; set; }
        public int Col { get; set; }
    }
}
