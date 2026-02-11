using CommandLine;
using Parcs.Module.CommandLine;

namespace ParcsNetMapsStitcher
{
    public sealed class CommandLineOptions : BaseModuleOptions
    {
        [Option("input", Required = true, HelpText = "Path to input file (same 5-line format as Python solver).")]
        public string InputFile { get; set; } = string.Empty;

        [Option("output", Required = false, HelpText = "Path to output text file (base64-encoded image for PARCS UI).")]
        public string OutputFile { get; set; } = "output.txt";

        [Option('p', "points", Required = true, HelpText = "Number of PARCS points (workers). Example: 1, 4, 7.")]
        public int PointsNum { get; set; }

        [Option("dryrun", Required = false, HelpText = "Generate dummy tiles instead of calling Google Maps API.")]
        public bool DryRun { get; set; }

        [Option("downloadonly", Required = false, HelpText = "Skip mosaic, output raw tile data as base64 JSON for local merge.")]
        public bool DownloadOnly { get; set; }

        [Option("tilestart", Required = false, Default = 0, HelpText = "Start tile index (0-based) for federated mode.")]
        public int TileStart { get; set; }

        [Option("tileend", Required = false, Default = -1, HelpText = "End tile index (exclusive, -1 = all) for federated mode.")]
        public int TileEnd { get; set; }

        [Option("concurrency", Required = false, Default = 1, HelpText = "Concurrency level per worker.")]
        public int Concurrency { get; set; }

        [Option("optimized", Required = false, Default = false, HelpText = "Use parallel downloads with thread pool optimization. Without this flag, downloads are sequential (for baseline).")]
        public bool Optimized { get; set; }
    }
}
