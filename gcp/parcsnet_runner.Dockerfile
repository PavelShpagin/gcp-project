# Runner container for executing ParcsNetMapsStitcher on GCP COS VMs.
#
# Why needed:
# - COS mounts `/home` as `noexec`, so you can't run a Linux binary copied there.
# - Building a Docker image copies the published app into Docker layers (exec-ok).
#
# Build context must contain:
# - ./bin/   (published linux-x64 output)
# - ./tests/ (input files)
#
FROM mcr.microsoft.com/dotnet/core/runtime-deps:2.1

WORKDIR /app

COPY bin/ ./bin/
COPY tests/ ./tests/

RUN chmod +x ./bin/ParcsNetMapsStitcher

ENTRYPOINT ["./bin/ParcsNetMapsStitcher"]

