# Jellyfin Enhanced: upstream Jellyfin (pinned) + the emby-port patches, multi-arch.
# Build context = the directory that contains jellyfin/, jellyfin-web/, jellyfin-plugin-tvdb/ (see workflow).
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS server
ARG TARGETARCH
WORKDIR /src
COPY jellyfin ./jellyfin
COPY jellyfin-plugin-tvdb ./jellyfin-plugin-tvdb
RUN case "$TARGETARCH" in amd64) A=x64;; arm64) A=arm64;; *) A=x64;; esac \
 && dotnet publish jellyfin/Jellyfin.Server/Jellyfin.Server.csproj -c Release -a $A --no-self-contained -o /out/server \
 && dotnet publish jellyfin-plugin-tvdb/Jellyfin.Plugin.Tvdb/Jellyfin.Plugin.Tvdb.csproj -c Release -a $A -o /out/tvdb

FROM --platform=$BUILDPLATFORM node:24-bookworm AS web
WORKDIR /web
COPY jellyfin-web ./
RUN npm ci --no-audit --no-fund && npm run build:production

FROM mcr.microsoft.com/dotnet/aspnet:10.0
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg locales \
      libfontconfig1 libfreetype6 libssl3 mesa-va-drivers \
 && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg \
 && . /etc/os-release \
 && echo "deb [arch=$TARGETARCH signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/debian ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/jellyfin.list \
 && apt-get update && apt-get install -y --no-install-recommends jellyfin-ffmpeg7 \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*
COPY --from=server /out/server /jellyfin
COPY --from=web /web/dist /jellyfin/jellyfin-web
# TheTVDB is bundled and seeded into the data dir on first start (see SeedBundledPlugins)
COPY --from=server /out/tvdb /jellyfin/plugins/TheTVDB_24.0.0.0
RUN printf '{"category":"MoviesAndShows","changelog":"","description":"Get TV metadata from TheTvdb (bundled).","guid":"a677c0da-fac5-4cde-941a-7134223f14c8","name":"TheTVDB","overview":"Get TV metadata from TheTvdb","owner":"jellyfin","targetAbi":"12.0.0.0","timestamp":"2026-01-01T00:00:00Z","version":"24.0.0.0","status":"Active","autoUpdate":false,"imagePath":"","assemblies":["Jellyfin.Plugin.Tvdb.dll","Tvdb.Sdk.dll"]}' > /jellyfin/plugins/TheTVDB_24.0.0.0/meta.json
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
    JELLYFIN_DATA_DIR=/config JELLYFIN_CONFIG_DIR=/config/config JELLYFIN_LOG_DIR=/config/log \
    JELLYFIN_CACHE_DIR=/cache JELLYFIN_WEB_DIR=/jellyfin/jellyfin-web \
    JELLYFIN_FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg \
    NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
LABEL org.opencontainers.image.source="https://github.com/yo-repo87/Jellyfin_Enhanced" \
      org.opencontainers.image.description="Jellyfin with Emby-style features (copy-user, easy PIN, backups, bulk editor, TVDB bundled)"
EXPOSE 8096 8920 7359/udp 1900/udp
VOLUME /config /cache
ENTRYPOINT ["/jellyfin/jellyfin"]
