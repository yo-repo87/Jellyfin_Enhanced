# Emby_Build

**Project mission**: build a personal, free, self-hosted media server with Emby's feature set by
forking Jellyfin (the GPL fork of Emby's last open release) and reimplementing Emby's behaviors in
it, clean-room. The Emby .deb in this repo is the reference artifact we studied to understand how
Emby works; we never copy its proprietary code (compiled DLLs) — we reimplement features with our
own code. Teardown findings are in "Emby .deb teardown (reference)" below.

## The fork (active work)

Two shallow clones live in this repo, each with an `emby-port` branch off upstream master
(cloned 2026-11-11, Jellyfin 13.0.0 dev):

- `jellyfin/` — the C#/.NET server (requires **.NET 10 SDK**, installed at `~/.dotnet/dotnet`;
  build: `dotnet build Jellyfin.Server/Jellyfin.Server.csproj -c Debug`, output lands in
  `Jellyfin.Server/bin/Debug/net10.0/jellyfin.dll`). ~200 pre-existing analyzer warnings in
  MediaBrowser.Model are upstream noise, not ours.
- `jellyfin-web/` — the web UI (Node 24; `npm ci`, check with `npx tsc --noEmit` and
  `npx eslint <changed files>`; lint `--fix` handles JSX indent).

Shared DNA note: the Jellyfin server still contains `Emby.Server.Implementations`, `Emby.Naming`
and `MediaBrowser.*` projects — the same assembly names as in the Emby .deb — so Emby's
architecture maps onto it directly.

### Features completed on `emby-port` (all built clean and verified live via API)

1. **Copy settings from user on create** — server `8a2e642`, web `1371e67`.
   `POST /Users/New` takes optional `CopyFromUserId`; the source user's full policy +
   configuration are applied to the new user (invalid id → 400). Web: "Copy settings from user"
   dropdown on the Add User page; selecting one hides the manual access checkboxes and skips the
   page's old policy overwrite (which would otherwise clobber the copy).
   Verified: duplicated a restricted user; policies matched field for field.
2. **Easy PIN code (Emby-style in-network sign-in)** — server `96f76c2`, web `a39132b`.
   New `EasyPassword` column on Users (EF migration `20261111155605_AddEasyPassword`, generated
   with `dotnet ef migrations add NAME --project src/Jellyfin.Database/Jellyfin.Database.Providers.Sqlite
   --output-dir Migrations -- --migration-provider Jellyfin-SQLite`; needs `dotnet tool restore`).
   Auth fallback in `UserManager.AuthenticateUser`: if normal auth fails AND the connection is
   in-network AND the user's `EnableLocalPassword` config is on, the password value is verified
   against the PIN hash. PIN never works remotely. `POST /Users/{id}/EasyPassword` sets/clears it
   (`{NewPw}` / `{ResetPassword:true}`); `HasConfiguredEasyPassword` un-obsoleted in UserDto and
   populated. Web: "Easy Pin Code" section on the password form (dashboard + user profile);
   saving a PIN sets `EnableLocalPassword=true`, removing sets false; PIN validated as 4-8 digits.
   Verified: PIN login 200 from localhost, wrong PIN 401, full password still 200.
3. **Automatic version merging (Emby-style)** — server `3fbc6b0`, web `2c89cf9`.
   Merge logic extracted from `VideosController.MergeVersions` into new
   `IVideoVersionManager`/`VideoVersionManager` (DI-registered in ApplicationHost next to
   ICollectionManager). New per-library option `LibraryOptions.EnableAutomaticVersionMerging` +
   `AutomaticVersionMergingPostScanTask` (ILibraryPostScanTask, auto-discovered): after each scan,
   movies in that library with same trimmed name + production year (resolved to version-family
   roots first) are merged across folders. Web: checkbox in library settings, shown for
   movies/mixed. Verified: 2 same-name movies in different folders auto-merged on scan into 1
   item with 2 MediaSources; second scan idempotent (no re-merge).
   **Key finding**: upstream master already fixed the old "merge lost on rescan" bug (manual
   merge survives full rescans — tested) and already allows merging episodes via multi-select;
   the user's bad experience was Jellyfin 10.x stable.
4. **TVDB bundled/preinstalled** — server `b9433f2`, plugin repo `jellyfin-plugin-tvdb/` branch
   `emby-port` commit `c750089`, staging script `build-bundled-plugins.sh` (repo root).
   The official TVDB plugin (guid `a677c0da-fac5-4cde-941a-7134223f14c8`, v24) is cloned as a
   third repo and built with ProjectReferences (`Private=false`) to our server tree so the ABI
   always matches. `build-bundled-plugins.sh` runs `dotnet publish` (a plain build does NOT copy
   NuGet deps like Tvdb.Sdk.dll), then stages `plugins/TheTVDB_24.0.0.0/` (plugin dll +
   Tvdb.Sdk.dll + meta.json) into the server output dir. Server side:
   `StartupHelpers.SeedBundledPlugins` (called from Program.cs before migrations) copies each
   bundled plugin folder into `<datadir>/plugins` once, tracked by a `.seeded-<folder>` marker
   file so an uninstall is not re-seeded. **Gotcha**: meta.json's `assemblies` list is a load
   whitelist — every DLL the plugin ships (including Tvdb.Sdk.dll) must be listed or the load
   context refuses it ("Failed to load assembly ... incompatible version").
   Verified live: fresh datadir → log shows "Seeded bundled plugin" + "Loaded plugin: TheTVDB
   24.0.0.0"; /Plugins lists TheTVDB Active; Series metadata fetchers include TheTVDB.
5. **Scheduled backups with retention (MBBackup-style)** — server `6f9ae83`, web `53941ea`.
   Upstream already had on-demand backup/restore (`IBackupService`, `BackupController`,
   dashboard Backups page); what was missing vs Emby was scheduling + retention. Added
   `BackupTask` (IScheduledTask, key `ScheduledBackup`, "Create Backup" under Maintenance,
   default trigger daily 03:00) which calls `IBackupService.CreateBackupAsync` then deletes the
   oldest backups beyond `RetentionCount`. Options live in a new `scheduledbackup` config store
   (`ScheduledBackupOptions` in MediaBrowser.Model + `BackupConfigurationFactory`,
   auto-discovered; defaults: retention 3, Database only) at
   `/System/Configuration/scheduledbackup`. Web: "Automatic Backups" section on the dashboard
   Backups page (retention + content checkboxes; schedule changed via Scheduled Tasks).
   Verified live: task registered with daily 3:00 trigger; with retention 2, three runs left
   exactly the two newest zips in `<datadir>/data/backups`.
   **Gotcha**: during boot Jellyfin now runs a placeholder *setup server* that answers
   `/System/Info/Public` (with a UTF-8 BOM) before the real API is up — a READY probe on that
   endpoint can pass while wizard POSTs go to the placeholder and vanish. Probe `/Startup/User`
   (needs 200) to detect the real server before driving the wizard.

### Roadmap (agreed order)

1. ~~Merge-versions hardening~~ (done — see above)
2. ~~TVDB bundled/preinstalled~~ (done — see above; the seeding mechanism is generic, so
   bundling more plugins later — DLNA, intros, etc. — is just another stanza in
   `build-bundled-plugins.sh`)
3. ~~Backup/restore task~~ (done — see above)
4. Then the gap list, in order: Live TV/DVR polish; offline sync; DLNA bundled back in;
   Cinema Mode (pre-roll trailers); hardware-transcode auto-config (crib Emby's ffdetect
   approach + its driver-bundling from the teardown); bulk metadata editor; client-app polish
   (API compat only).
6. **Filename identification improvements** — server `9285005`.
7. **Live TV/DVR polish** — server `b3246a5`.
   Enhanced M3U tuner validation to check format validity (must start with
   #EXTM3U marker) and provide helpful, actionable error messages for common
   issues: HTTP 4xx (wrong URL), 5xx (server down), file not found, access
   denied, invalid format. This eliminates cryptic failures when users add
   M3U playlists, significantly improving Live TV setup UX. Jellyfin already
   has the infrastructure (RefreshGuideScheduledTask with daily 24h interval,
   M3UTunerHost, XmlTvListingsProvider); this polish surfaces better feedback.
8. **Bulk metadata editor** — web `14e8ea2`.
   Dashboard page for batch-editing item properties (genres, tags, ratings)
   across multiple selected movies/shows. Search for items, then apply common
   metadata updates to the entire result set. UI uses library search + update
   endpoints; live ready for dashboard integration.

### Completed features (all built clean and verified)
   Metadata lookup now survives more real-world filename pollution. Added
   `GetSearchAttempts` method to generate progressive fallbacks: first tries full
   name+year, then name without year, then progressively shorter names (dropping
   trailing words) which typically contain release tags that are hard to strip
   perfectly. Applied to movie and series TMDb providers (both GetSearchResults and
   GetMetadata flow). Also expanded `CleanStrings` regex in `NamingOptions` with 30+
   modern release tags (av1, hevc, remux, 10bit, hdr10, atmos, criterion, dsnp,
   ddp, flac, opus, imax, amzn, etc.) so automatic parsing is less likely to leave
   noise. Path-embedded provider IDs (`[tmdbid-123]`, `{imdb-tt...}`) already worked
   upstream; no fuzzy match scoring added (would be a separate feature).

### Working practices for this fork

- **Clean-room rule**: never decompile/copy Emby DLLs; reimplement behavior only.
- Feature flow: implement server + web together, build both, then **verify live**: run the built
  server with `dotnet jellyfin.dll --datadir <tmp> --nowebclient` on port 18096 (write a
  `config/network.xml` with `InternalHttpPort`/`PublicHttpPort` 18096 — port 8096 is occupied by
  the real media server on this host; NEVER touch it). Data dir must be on the home disk, not the
  session scratchpad tmpfs (Jellyfin requires 2 GiB free). Complete the startup wizard via
  `/Startup/*`, auth via `/Users/AuthenticateByName` with the `MediaBrowser Client=...` header.
  Re-authenticating with the same DeviceId revokes the old token. `UID` is readonly in bash.
  Fake libraries: random-byte `.mkv` files scan fine (ffprobe errors are non-fatal); use nonsense
  titles so metadata lookups miss; disable internet providers in LibraryOptions. Stop the server
  and delete the test datadir when done.
- Commit per feature on `emby-port` in each repo (repo-local git identity is set; commits end
  with the Claude co-author line). Keep diffs minimal: insert strings surgically into
  `src/strings/en-us.json` (it is NOT fully sorted — never resort the whole file).
- In ASP.NET controllers the bare type name `User` resolves to `ControllerBase.User`
  (ClaimsPrincipal) — use `var` or qualify the entity type.

## Emby .deb teardown (reference)

The findings below come from a full teardown of `emby-server-deb_4.10.2.0_amd64.deb`
(247 MB compressed, 916 MB installed, 1,635 files) on 2026-11-11.

## Package anatomy (emby-server 4.10.2.0, amd64)

Standard Debian format-2.0 archive: `debian-binary` + `control.tar.xz` + `data.tar.xz`.
Key design decision: **the control file declares no `Depends:` at all** — the package is fully
self-contained (ships its own glibc, .NET runtime, FFmpeg, GPU userspace, CA certs) so one .deb
installs on any amd64 Debian/Ubuntu. File timestamps inside are clamped to "Aug 21 2017"
(reproducible-build artifact, not the real build date; content is ~2024, .NET 8.0.28).

### Control layer
- `control`: Package emby-server, Version 4.10.2.0, Maintainer "Emby LLC <apps@emby.media>", no dependencies.
- `conffiles` (protected on upgrade): `/etc/emby-server.conf`, `/etc/firewalld/services/emby-server.xml`, `/etc/init/emby-server.conf` (Upstart relic).
- `postinst`: creates system group+user `emby` (home `/var/lib/emby`, `/usr/sbin/nologin`, password locked), adds it to `video` and `render` groups (GPU access via `/dev/dri/*`), then `systemctl daemon-reload && enable && start emby-server` (SysV `service` fallback).
- `prerm`: stops + disables the service on remove/upgrade.
- `postrm` on **purge**: `rm -rf /var/lib/emby` (deletes the whole library DB) and `userdel emby`.
- `shlibs` + ldconfig trigger register the ~75 bundled shared libraries.

### Filesystem layout (data.tar.xz)
- `/opt/emby-server/` — everything: `bin/`, `system/` (the .NET app, 179 MB), `lib/` (native libs, 734 MB), `etc/`, `share/`, `licenses/` (~450 license files; FFmpeg is GPL v3 so the combined work is GPLv3-bound).
- `/etc/emby-server.conf` — env file, sets `EMBY_DATA` (default `/var/lib/emby`).
- `/usr/lib/systemd/system/emby-server.service` + `emby-server@.service` (template to run as any user).
- `/etc/firewalld/services/emby-server.xml` — ports 8096/tcp (HTTP), 8920/tcp (HTTPS), 1900/udp (SSDP/DLNA), 7359/udp (Emby discovery).

## Launch chain & self-containment tricks

`systemd → /opt/emby-server/bin/emby-server (sh) → system/EmbyServer (ELF host) → EmbyServer.dll (.NET)`

- Unit runs as `User=emby`, `WorkingDirectory=/opt/emby-server`, `EnvironmentFile=/etc/emby-server.conf`, `RestartForceExitStatus=3` — the web-UI "Restart" button makes the server exit 3 and systemd restarts it.
- The launcher script exports the isolation env: `LIBVA_DRIVERS_PATH`, `OCL_ICD_VENDORS`, `FONTCONFIG_PATH`, `SSL_CERT_FILE`, `PCI_IDS_PATH`, `AMDGPU_IDS_PATH`, `VK_DRIVER_FILES`/`VK_LAYER_PATH`, `XDG_CACHE_HOME=$EMBY_DATA/cache`, plus `NEOReadDebugKeys=1` + `OverrideGpuAddressSpace=48` (Intel compute-runtime workaround for kernel ≥ 6.8). Then execs:
  `EmbyServer -programdata $EMBY_DATA -ffdetect ... -ffmpeg ... -ffprobe ... -restartexitcode 3 -updatepackage 'emby-server-deb_{version}_amd64.deb'`
- **Every ELF has `RPATH=$ORIGIN/../lib`** so `/opt/emby-server/lib` wins over system libs.
- **`system/EmbyServer` has a *relative* ELF interpreter: `lib/ld-linux-x86-64.so.2`** — it runs on Emby's own bundled glibc 2.34 (crosstool-NG 1.28, cross prefix `x86_64-emby-linux-gnu-`). This is why every wrapper and the unit file `cd /opt/emby-server` first; launched from any other cwd it fails with "no such file or directory".

## Application layer (`system/`)

Self-contained **.NET 8.0.28** (CoreCLR + ASP.NET Core bundled; no system dotnet). ~35 first-party assemblies (`Emby.Api`, `Emby.Server.Implementations`, `MediaBrowser.*`, `Emby.LiveTV`, `Emby.Server.Sync`, `Emby.Server.Connect`, …). Third-party: SQLitePCL.pretty over bundled SQLite 3.53.4 (library DB), SkiaSharp 2.88 + libvips 42 (dual image backends, `-noskia`/`-novips` flags), ServiceStack.Text, SharpCompress, SimpleInjector, SharpDX (Windows dead weight). ~40 locale dirs with satellite assemblies.

- Hidden CLI flags (from EmbyServer.dll): `-programdata -ffmpeg -ffprobe -ffdetect -restartexitcode -updatepackage -defaultdirectory -noautorunwebapp -nointerface -noskia -novips -pidfile -service -skipsingleinstance -writeopenapi`.
- Bundled plugins (20 DLLs in `system/plugins/`): Emby.Dlna, M3UTuner + XmlTV (Live TV), CinemaMode, Webhooks, PortMapper, MBBackup, Bluray/DvdMounter, scrapers (MovieDb, Tvdb, Fanart, MusicBrainz, AudioDb, OMDb, OpenSubtitles, NfoMetadata, StudioImages, EmbyGuideData).
- Web UI: `system/dashboard-ui/` (35 MB SPA, AMD modules via alameda, service workers) served by embedded Kestrel on 8096/8920.
- External endpoints baked in: `mb3admin.com` (Premiere licensing + plugin catalog), `connect.emby.media` / `api.ipify.org` (external IP), `fcm.googleapis.com` + `wns.windows.com` (push relay).
- Runtime state under `$EMBY_DATA` (`/var/lib/emby`): `config/`, `plugins/`, `metadata/`, `cache/`, `transcoding-temp/`, `updates/` (built-in updater downloads the next `emby-server-deb_{version}_amd64.deb` there per the `-updatepackage` template; installation still needs dpkg/root).

## Transcoding stack (`lib/` + `bin/`)

- Custom FFmpeg fork **`5.1-emby_2023_06_25_p6`** (built on Emby buildbot): x264, x265, VP8/9, dav1d, Opus/Vorbis/Theora/LAME, libass+freetype+fribidi, **libtesseract (OCR for PGS/VOBSUB→text subs)**, chromaprint, zvbi/aribb24, mbedTLS; HW: VAAPI, Intel QSV (libmfx + oneVPL/libmfx-gen), NVENC/NVDEC/CUVID, OpenCL (HDR tonemapping). Vulkan is `--disable`d.
- `bin/ffdetect` — Emby-specific capability probe run at startup; `vainfo`/`clinfo` diagnostics with `emby-*` wrappers. Note: `emby-vulkaninfo` wrapper ships but the `vulkaninfo` binary it execs does not (packaging leftover).
- GPU userspace bundled wholesale:
  - Intel: both `i965` (legacy) and `iHD` VA drivers, libmfxhw64 + libmfx-gen, and **two full copies of the NEO OpenCL runtime** (`libigdrcl.so` + `_legacy1`) each with an LLVM shader compiler — `libopencl-clang` 110 MB ×2 + `libigc` ~85 MB ×2 ≈ 430 MB, ~half the package.
  - AMD: Mesa gallium VA drivers (`radeonsi`, `r600`, `libgallium_drv_video`) + libdrm_amdgpu + own `amdgpu.ids`.
  - NVIDIA: nothing bundled; NVENC/NVDEC bind to the proprietary driver at runtime.
- Support libs: ICU 72 (30 MB data), OpenSSL 3, curl, Kerberos, zlib, libvips, libSkiaSharp.

## Security posture

Dedicated locked system user, nologin shell, GPU via `video`/`render` groups (not root), no setuid binaries, BinaryFormatter disabled in runtimeconfig. Trade-offs: bundled OpenSSL/glibc/curl receive no distro security updates, and the unit has no systemd sandboxing (`ProtectSystem`, `PrivateTmp`, etc. absent).

## Practical notes for this repo

- Extract for inspection: `ar x <deb>` then `tar -xJf control.tar.xz` / `tar -xJf data.tar.xz` (extract into a scratch dir, not the repo — the tree is 916 MB and `.gitignore` won't cover it).
- Anything that must keep working if files are moved: the relative interpreter + `$ORIGIN` RPATHs mean binaries only run with cwd `/opt/emby-server` (or a faithful copy of that layout).
- To rebuild a modified package: unpack both tarballs, edit, regenerate `md5sums` (1,635 entries), repack with `dpkg-deb -b` (use `--root-owner-group`; control scripts assume systemd-or-SysV and the `emby` user conventions above).

## Docker image and Helix OS catalog (2026-11-12)
`ghcr.io/yo-repo87/jellyfin-enhanced:latest` (amd64+arm64, public) is built by `.github/workflows/docker.yml` from `docker/Dockerfile`: upstream jellyfin / jellyfin-web / jellyfin-plugin-tvdb at the commits in `docker/pins.env` plus `docker/patches/{server,web,tvdb}/*.patch`. **After committing new work on `emby-port`, regenerate the patches** (`rm docker/patches/X/*; git -C <clone> format-patch master..emby-port -o $PWD/docker/patches/X`) and push main; the workflow rebuilds (~30 min). The web build type-checks (webpack fails on TS errors), so run `npx tsc --noEmit` before pushing. The fork repos `jellyfin-emby-port`/`jellyfin-web-emby-port` on GitHub are empty (shallow push rejected). Helix OS lists it as "Jellyfin Enhanced" in its built-in catalog (port 8097).
