#!/bin/sh
# Builds the bundled (preinstalled) plugins and stages them into the Jellyfin
# server's output directory under plugins/, where StartupHelpers.SeedBundledPlugins
# picks them up and seeds them into the data dir on first start.
#
# Usage: ./build-bundled-plugins.sh [server-output-dir]
#   default server-output-dir: jellyfin/Jellyfin.Server/bin/Debug/net10.0

set -e
cd "$(dirname "$0")"

export PATH="$HOME/.dotnet:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

SERVER_OUT="${1:-jellyfin/Jellyfin.Server/bin/Debug/net10.0}"

# ---- TheTVDB ----------------------------------------------------------------
TVDB_NAME="TheTVDB"
TVDB_VERSION="24.0.0.0"
TVDB_GUID="a677c0da-fac5-4cde-941a-7134223f14c8"
TVDB_PROJ="jellyfin-plugin-tvdb/Jellyfin.Plugin.Tvdb/Jellyfin.Plugin.Tvdb.csproj"
TVDB_PUBLISH="jellyfin-plugin-tvdb/Jellyfin.Plugin.Tvdb/bin/Release/net10.0/publish"

dotnet publish "$TVDB_PROJ" -c Release --nologo -v quiet

DEST="$SERVER_OUT/plugins/${TVDB_NAME}_${TVDB_VERSION}"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$TVDB_PUBLISH/Jellyfin.Plugin.Tvdb.dll" "$DEST/"
cp "$TVDB_PUBLISH/Tvdb.Sdk.dll" "$DEST/"

cat > "$DEST/meta.json" <<EOF
{
    "category": "MoviesAndShows",
    "changelog": "",
    "description": "Get TV metadata from TheTvdb (bundled with the server).",
    "guid": "$TVDB_GUID",
    "name": "$TVDB_NAME",
    "overview": "Get TV metadata from TheTvdb",
    "owner": "jellyfin",
    "targetAbi": "12.0.0.0",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "version": "$TVDB_VERSION",
    "status": "Active",
    "autoUpdate": false,
    "imagePath": "",
    "assemblies": [
        "Jellyfin.Plugin.Tvdb.dll",
        "Tvdb.Sdk.dll"
    ]
}
EOF

echo "Staged $TVDB_NAME $TVDB_VERSION -> $DEST"
ls -l "$DEST"
