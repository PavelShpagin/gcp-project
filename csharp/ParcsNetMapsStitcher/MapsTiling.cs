using System;
using System.Collections.Generic;
using ParcsNetMapsStitcher.Models;

namespace ParcsNetMapsStitcher
{
    internal static class MapsTiling
    {
        public static List<TileRequest> CalculateTileCoordinates(
            double centerLat,
            double centerLon,
            int numRows,
            int numCols,
            int zoom,
            int tileSizePx)
        {
            var worldPx = 256.0 * Math.Pow(2.0, zoom);

            (double x, double y) LatLonToPixel(double lat, double lon)
            {
                var x = (lon + 180.0) / 360.0 * worldPx;
                var siny = Math.Sin(DegToRad(lat));
                var y = (0.5 - Math.Log((1.0 + siny) / (1.0 - siny)) / (4.0 * Math.PI)) * worldPx;
                return (x, y);
            }

            (double lat, double lon) PixelToLatLon(double x, double y)
            {
                var lon = x / worldPx * 360.0 - 180.0;
                var n = Math.PI - 2.0 * Math.PI * y / worldPx;
                var lat = RadToDeg(Math.Atan(Math.Sinh(n)));
                return (lat, lon);
            }

            var (cx, cy) = LatLonToPixel(centerLat, centerLon);
            var stepPx = (double)tileSizePx;

            var tiles = new List<TileRequest>(numRows * numCols);
            for (var i = 0; i < numRows; i++)
            {
                for (var j = 0; j < numCols; j++)
                {
                    var dx = (j - (numCols - 1) / 2.0) * stepPx;
                    var dy = (i - (numRows - 1) / 2.0) * stepPx;
                    var (lat, lon) = PixelToLatLon(cx + dx, cy + dy);
                    tiles.Add(new TileRequest { Lat = lat, Lon = lon, Row = i, Col = j });
                }
            }

            return tiles;
        }

        private static double DegToRad(double deg) => deg * Math.PI / 180.0;
        private static double RadToDeg(double rad) => rad * 180.0 / Math.PI;
    }
}
