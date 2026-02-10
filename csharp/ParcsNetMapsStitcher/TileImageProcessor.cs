using System;
using System.IO;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

namespace ParcsNetMapsStitcher
{
    /// <summary>
    /// Image processing that runs on the master (runner) only.
    ///
    /// Why separate:
    /// - PARCS daemons load worker assemblies via <c>Assembly.Load(byte[])</c>,
    ///   so dependency resolution is limited.
    /// - Keeping ImageSharp usage out of worker code avoids needing to ship extra DLLs to points.
    /// </summary>
    internal static class TileImageProcessor
    {
        public static byte[] CropAndReencodeJpeg(byte[] originalJpegBytes, int cropBottom, int jpegQuality)
        {
            using (var image = Image.Load<Rgb24>(originalJpegBytes))
            {
                var cropH = Math.Max(1, image.Height - cropBottom);
                image.Mutate(c => c.Crop(new Rectangle(0, 0, image.Width, cropH)));

                using (var ms = new MemoryStream())
                {
                    image.SaveAsJpeg(ms, new JpegEncoder { Quality = jpegQuality });
                    return ms.ToArray();
                }
            }
        }

        public static byte[] CreateDummyTileJpeg(int width, int height, int row, int col, int jpegQuality)
        {
            // Simple color hash by coordinates so the final mosaic is visually checkable.
            var r = (byte)((row * 53 + col * 97) % 256);
            var g = (byte)((row * 91 + col * 29) % 256);
            var b = (byte)((row * 17 + col * 71) % 256);

            using (var img = new Image<Rgb24>(width, height, new Rgb24(r, g, b)))
            using (var ms = new MemoryStream())
            {
                img.SaveAsJpeg(ms, new JpegEncoder { Quality = jpegQuality });
                return ms.ToArray();
            }
        }
    }
}

