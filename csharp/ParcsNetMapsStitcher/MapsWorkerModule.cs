using System;
using System.Threading;
using Parcs;
using ParcsNetMapsStitcher.Models;

namespace ParcsNetMapsStitcher
{
    public sealed class MapsWorkerModule : IModule
    {
        public void Run(ModuleInfo info, CancellationToken token = default(CancellationToken))
        {
            var task = info.Parent.ReadObject<TileDownloadTask>();
            var results = TileDownloader.DownloadTiles(task, token);
            info.Parent.WriteObject(results);
        }
    }
}
