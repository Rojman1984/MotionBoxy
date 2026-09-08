# MotionBoxy — Linux AppImage build & warehousing plan

**Status**: planned (2026-09-08). Goal: replace the ad-hoc dev runtime (`run/` + hand-assembled
`bin/`) with a reproducible, self-contained AppImage, warehoused as a GitHub Release. Target OS:
native Linux / live Linux builds — no environment-specific code (SDD Addendum 17 policy).

## What already exists (reuse, don't rebuild)

- `build.sh all linux` → binary + `content/generate.sh` (deploy mode: QML/assets/qrc-embedded via
  Sky's deployer) + `deploy.sh` assembles `deploy/`: binary, Qt runtime + plugins, OpenSSL,
  VLC core + 16 plugin categories + helper libs (`$VLC/vlc/lib*.so*` — catches
  `libvlc_pulse.so.0`), libtorrent, Boost, `backend/` payload, and `dist/script/start.sh`
  (sets `LD_LIBRARY_PATH`/`QT_PLUGIN_PATH` to its own directory, then execs `MotionBox`).
- Sky's `deploy.sh` (linux) already bakes `$ORIGIN`-relative rpaths with `patchelf`.
- `WVlcEngine.cpp` sets `VLC_PLUGIN_PATH` to `applicationDirPath()`; plugins live in a `vlc/`
  subdirectory next to the binary — same layout inside an AppImage (`AppDir/usr/bin/`), so the
  recursive plugin scan works unchanged.
- SDD Addendum 17 root-cause table: the complete plugin set requires libpulse (+ helper),
  libdvbpsi, libopus, libtheora at VLC configure time; `.qsb` shaders must be baked (system
  `qsb` from `qt6-shadertools`, flags: `qsb --batchable --glsl "100 es,120,150" --hlsl 50
  --msl 12`).

## Decisions

1. **Packaging tool: `appimagetool` over a hand-assembled AppDir** (not linuxdeployqt). The
   `deploy/` tree is already relocatable (`$ORIGIN` rpath + `start.sh`); AppDir = `usr/` copy +
   `AppRun` (execs `start.sh`), `.desktop`, icon. Fewest moving parts, no dependency on
   linuxdeployqt's Qt-version assumptions.
2. **Stock VLC, no patched libvlc.** Sky commit `89c5bfe` passes `--avcodec-hw=none` from the
   engine, superseding the `lib/media_player.c` patch used during development. Any VLC 3.0.x
   source build configured with the four dev dependencies is sufficient — this makes the
   AppImage reproducible on any machine.
3. **Build baseline: Ubuntu 22.04 (jammy)** with distro Qt 6.4 packages — matches the toolchain
   already used for `build-check`. Stated compat: the AppImage requires a glibc of the build
   baseline (22.04+). Widening the baseline (20.04 container rebuild) is a later, optional step.
4. **Warehousing: GitHub Releases on `Rojman1984/MotionBoxy`.** Tag scheme `appimage-vN`
   (`appimage-v1` first). Attach the AppImage + `SHA256SUMS`. Release notes state the baseline
   requirement and content (VLC 3.0.x complete plugin set, Qt 6.4).
5. **Deploy-mode build** (`SK_DEPLOY`, qrc-embedded QML) — the AppImage ships no loose QML;
   storage is created fresh on first launch in the user's home.

## Phases

- **P0 — Preconditions. ✅ DONE (2026-09-08).** See "P0 results" below.
- **P1 — AppImage script. ✅ DONE (2026-09-08).** Files: `appimage.sh` (repo root: Sky/deploy
  state → `deploy.sh linux` → closure pass → `plugins.dat` → AppDir → validation →
  `appimagetool`), `dist/appimage/{AppRun,motionboxy.desktop,sky-deploy-linux.sh}`, icon
  `dist/icon.png` (512×512) as `motionboxy.png` + `.DirIcon` +
  `usr/share/icons/hicolor/512x512/apps/`. Verified: full pipeline green, 291 plugins validated,
  `MotionBoxy-1.0.0-x86_64.AppImage` (≈100 MB) launches via `--appimage-extract-and-run`
  (QML from qrc, storage OK). See "P1 results" below.
- **P2 — Local smoke test. ✅ DONE (2026-09-08).** See "P2 results" below.
- **P3 — Warehouse.** `gh release create appimage-v1 MotionBoxy-*.AppImage SHA256SUMS` on
  `Rojman1984/MotionBoxy` with notes (baseline, contents, usage).
- **P4 — (optional) CI.** GitHub Actions workflow on `Rojman1984/MotionBoxy` in an
  `ubuntu:22.04` container: apt deps → build → `appimage.sh` → attach to release. Decide there
  whether VLC/libtorrent come from apt dev packages or Sky's `3rdparty.sh` source builds.
- **P5 — Retire the ad-hoc runtime.** After P2/P3 acceptance, `run/` + hand-bundled `bin/` become
  dev-only fallbacks. Update SDD (Addendum 18: packaging & distribution).

## Acceptance checklist

- [x] AppImage launches from a clean `$HOME` (storage auto-created; no run/ dir present)
- [x] Video + audio OK; `[vlc]` log confirms pulse aout, TS demuxer, Opus decoder (P2 results:
      playback driven via the dev runtime against the identical bundled VLC payload — see
      "CLI argument" caveat below)
- [x] `--appimage-extract-and-run` works (systems without FUSE)
- [x] `desktop-file-validate` passes (P1); icon not visually verified on a real desktop
- [ ] Release `appimage-v1` visible with AppImage + SHA256SUMS attached

## P0 results (2026-09-08, Ubuntu 24.04 host — no sudo; no `3rdparty/`)

**Verified from-scratch pipeline** (the plan's "equivalent manual pipeline"): stock VLC 3.0.20
source build → deploy-mode MotionBox build (`SK_DEPLOY`, qrc-embedded QML/shaders) →
`deploy/` assembly → dependency closure → `plugins.dat` → launch test. All acceptance items for
P0 pass; `bin/` dev runtime untouched (restored from backup after the deploy build).

### Baseline corrections (supersede the plan text above)

- Build host is **Ubuntu 24.04 (noble), glibc 2.39, distro Qt 6.4.2** — jammy ships Qt 6.2, so
  "Ubuntu 22.04 + Qt 6.4" was impossible as stated. AppImage compat statement: needs
  glibc ≥ 2.39 + the host desktop stack (X11/GLVND, glib, pulse, fontconfig — all skipped from
  the bundle by design); everything else is bundled.
- **VLC plugins: 24 categories bundled** (not 16) — everything the stock build produces.
- **`plugins.dat` goes at the scan root** (`deploy/plugins.dat` in AppImage terms
  `usr/bin/plugins.dat`), NOT `vlc/plugins/plugins.dat`: VLC reads the cache from
  `<VLC_PLUGIN_PATH>/plugins.dat` (scan root = `applicationDirPath()`) and stores plugin paths
  relative to it (vlc-3.0.20 `src/config/cache.c:449`), so it is relocatable. Generated by
  `vlc-cache-gen <deploy>` — version-matched to the bundled libvlccore (noble's `libvlc-bin`
  provides the same 3.0.20 tool; use the locally built one).
- **libQt6QmlMeta.so.6 does not exist on noble** and the binary does not link it →
  `MotionBoxy/deploy.sh` now guards the QmlMeta copy (`if [ -f ]`, like QmlModels).
- `MotionBoxy/deploy.sh` gained the **`SK_PREBUILT=1`** opt-out that skips re-running
  `Sky/deploy.sh tools` (needed when `Sky/deploy` was assembled by an equivalent pipeline
  instead of the 3rdparty source-build layout).

### Pipeline that worked

1. `apt-get download <pkg>` + `dpkg -x` for `patchelf` and `qt6-shadertools` (the `qsb` binary)
   — no sudo required. VLC build deps were already installed as `-dev` packages.
2. VLC 3.0.20: configure stock (`--disable-nls`), `make`; install selectively with
   `make -C src modules lib bin install DESTDIR=…` (upstream `share/` install is broken:
   `vlc.appdata.xml` is generated before it can be installed).
3. MotionBox configure/build in a fresh build dir with the **default spec** (not
   `linux-g++-64`): `qmake "QT+=core-private gui-private quick-private qml-private
   qmlmodels-private" "CONFIG+=release qtquickcompiler vlc3 deploy"` — Sky needs Qt **private**
   headers (`WDeclarativeMouseArea.h` → `private/qquickmousearea_p.h`); the `-dev` packages
   above are required. `qt6-base-private-dev` + `qt6-declarative-private-dev` provide them.
4. `cd content && sh generate.sh linux deploy` → `dist/qrc/MotionBox.qrc` (327 files; baked
   `video.vert.qsb`/`video.frag.qsb` embedded at `:/shaders/`).
5. Assemble `Sky/deploy` (P0 prototype `/tmp/p0/assemble-sky-deploy.sh`; P1 folds this into
   `appimage.sh`): distro Qt 6.4.2 runtime libs + plugins (xcb, imageformats, tls/openssl,
   multimedia ffmpeg backend, xcbglintegrations) + qml modules (QtQuick, QtMultimedia,
   QtQml/WorkerScript) + ICU (`cp -L` the SONAME file — the `.so.NN.NN` glob duplicates 30 MB)
   + SSL + staged VLC (core, helper libs incl. `libvlc_pulse.so.0`, all 24 plugin categories,
   minus `.la`) + libtorrent + boost stub + patchelf rpaths (Sky scheme).
6. `SK_PREBUILT=1 sh deploy.sh linux` → `MotionBoxy/deploy/` (binary 14.1 MB, backend/, start.sh).
7. **Dependency-closure pass** (`/tmp/p0/closure.sh`): ldd-fixpoint over every bundled ELF;
   89 system libs copied into `deploy/` with `$ORIGIN` rpath — this is required, not optional:
   bundled VLC/Qt codec plugins link `libavcodec.so.60`-family libs whose SONAMEs older distros
   don't have. Skip-list = glibc family, `libstdc++`/`libgcc_s`, X11/GLVND/wayland/drm, glib
   family, dbus/systemd, pulse, font stack, compression, krb5, libproxy.
8. `vlc-cache-gen deploy/` → `deploy/plugins.dat` (must run **after** all file placement:
   the cache stores mtimes/sizes).
9. Dedupe + verify + launch: `deploy/start.sh` runs the app; storage auto-created at
   `$HOME/.local/share/MotionBox` (verified fresh — nothing pre-existing touched); QML loads
   from `qrc:`; network + backend payload OK.

### Known benign

- First launch on empty storage logs `qrc:/Gui.qml:153: TypeError: Cannot read property
  'isLoaded' of null` — init-order transient (`pReadyBrowse` binding evaluated before the index
  controller loads); app proceeds normally; absent once storage exists. Re-check in P2.
- Bundling `libOpenCL.so.1`/`libva*`/`libvdpau` (pulled by libavutil): they are ICD/driver
  loaders that look up host paths (`/etc/OpenCL/vendors`, dri) — fine by design.

### apt package list

```sh
sudo apt-get install \
    build-essential pkg-config git ca-certificates \
    qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev \
    qt6-multimedia-dev qt6-5compat-dev qt6-svg-dev qt6-qpa-plugins qt6-wayland \
    qt6-shadertools \
    libvlc-dev libvlc-bin \
    libpulse-dev libdvbpsi-dev libopus-dev libtheora-dev \
    libavcodec-dev libmatroska-dev \
    libtorrent-rasterbar-dev libssl-dev \
    patchelf
```

- `qt6-base-dev` provides `qmake` (`/usr/lib/qt6/bin/qmake`); `qt6-shadertools` provides
  `qsb`. Bake flags (SDD Addendum 17): `qsb --batchable --glsl "100 es,120,150" --hlsl 50
  --msl 12`. The four VLC codec deps (`pulse`, `dvbpsi`, `opus`, `theora`) are the Addendum 17
  requirement; `libvlc-bin` conveniently provides a system `vlc-cache-gen` (3.0.20 on noble).
- Without sudo: `apt-get download <pkg> && dpkg -x <pkg>.deb <dir>` works for `patchelf` and
  `qt6-shadertools` (both used this way on the P0 host).
- **Not apt packages**: `appimagetool` — GitHub release download
  (`https://github.com/AppImage/appimagetool`); `libfuse2` — needed at *runtime* of the
  AppImage (or run with `--appimage-extract-and-run`).

### P1 note (from P0)

`WControllerDeclarative` registers the QML import path as **`QDir::currentPath()`** — the
`AppRun` script MUST `cd` into `AppDir/usr/bin` before exec'ing `start.sh`, or `import QtQuick`
fails to resolve `deploy/QtQuick/qtquick2plugin`.

## P1 results (2026-09-08)

- `appimage.sh` envs: `SK_PREBUILT=1` (use `Sky/deploy` as-is), `SK_CANONICAL=1` (assemble via
  `Sky/deploy.sh` + 3rdparty), else the distro-Qt bridge `dist/appimage/sky-deploy-linux.sh`
  (parameterized: `VLC_PREFIX`, `PATCHELF`, `QMAKE`; Qt paths via `qmake6 -query`). Also
  `MOTIONBOXY_VERSION` (default 1.0.0), `APPIMAGETOOL`, `VLC_CACHE_GEN`.
- `appimagetool` is probed with `--appimage-extract-and-run --version` and, when it is an
  AppImage, always invoked through that flag — works with and without FUSE. Discovery order:
  `$APPIMAGETOOL`, PATH, `../tools/appimagetool*.AppImage`. Use `SOURCE_DATE_EPOCH` from the
  last commit for a reproducible squashfs.
- **Pitfall found and guarded:** `deploy.sh` copies `bin/MotionBox`, and `bin/` is *also* the
  dev-runtime directory — if `bin/MotionBox` currently holds the dev build (no qrc), the
  AppImage tries to load `Main.qml` from disk and aborts. `appimage.sh` now prechecks
  `strings bin/MotionBox | grep shaders/video.frag.qsb` (only the deploy build embeds it).
  Also note `make` will not relink over a newer foreign `bin/MotionBox` — delete the file
  before `make` (build-deploy objects are cached, relink is seconds).
- `AppRun` cds to `$APPDIR/usr/bin` then execs `start.sh` (which re-derives its own directory
  for `LD_LIBRARY_PATH`/`QT_PLUGIN_PATH`); the `cd` is what satisfies the
  `QDir::currentPath()` QML import path.
- `.desktop` validated with `desktop-file-validate` — the apt package is **`desktop-file-utils`**
  (not "desktop-file-validate"). WSLg launch shows benign libEGL/MESA warnings, same class as
  the dev runtime.
- AppImage size ≈ 100 MB (273 MB `deploy/` → squashfs).

## P2 results (2026-09-08)

### Precheck correction (fixes a P1 mistake)

The P1-era deploy-mode precheck (`strings bin/MotionBox | grep shaders/video.frag.qsb`) is
**useless**: the dev-runtime binary contains the same literal (it loads those shaders from
disk). P2 caught the consequences — a rebuild packaged the dev binary and the AppImage aborted
with `Cannot create Main QML object: file://.../usr/bin/Main.qml`. Working discriminator: the
deploy build links `qmlcache_loader.o` (thousands of `qmlcache` symbols; dev build has none).
`appimage.sh` now checks `nm bin/MotionBox | grep -qi qmlcache`, both before packaging and in
the AppDir validation gate. To rebuild deploy mode: `rm bin/MotionBox && make -C build-deploy`
(relink is seconds from cached objects); restore the dev binary afterwards if needed.

### Launch matrix (clean `$HOME`, no run/ dir, X11/xcb)

- `--appimage-extract-and-run`: ✅ launches (exit 124 = alive until timeout), storage
  auto-created at `$HOME/.local/share/MotionBox`, backend payload copied, network connected,
  qrc QML. First launch logs the known benign `Gui.qml:153` TypeError; second launch is clean.
- Plain FUSE launch: ✅ same (`/dev/fuse` present here; AppRun path identical).
- Running the extracted AppDir's `AppRun` directly: ✅ same — packaging is self-contained.
- Wayland probe: WSLg's Wayland is present but the app runs xcb by default; not further
  pursued (target OS is native Linux; the dev runtime showed the same WSLg constraints).

### VLC stack proof

The bundled payload (deploy/ → `usr/bin/`, VLC 3.0.20 + 291 plugins) was driven end-to-end
with the test stream `testsrc 320x240 H.264 + sine→Opus 48 kHz in MPEG-TS` (fabricated with
distro ffmpeg 6.1.1). Full `[vlc]` log evidence, zero VLC errors:

- `using demux module "ts"` — TS demuxer
- `using audio decoder module "opus"` — `Opus audio with 1 channels`
- `using video decoder module "avcodec"` + `swscale` converters (frames rendered)
- `using audio output module "pulse"` — connected to the host PulseAudio server

**Caveat (CLI argument):** passing a *local media file* as the CLI argument reaches the QML
layer correctly (`start.sh "$@"` fix verified by tracing `applyArguments` → `core.argument` →
`onPReadyBrowseChanged` → `PanelBrowse.play`), but the browse pipeline treats it as a
searchable **playlist source**, and it never reaches the VLC player — the same happens in the
dev runtime, so this is upstream behavior, not an AppImage defect. The playback evidence above
was therefore produced with an instrumented dev-runtime QML (direct `player.source`/`play()`)
against the **identical** bundled VLC payload; the AppImage itself runs the same binary and
libraries byte-for-byte (AppDir validation gate).

### VLC plugins cache

First launch logs ~291 `stale plugins cache: modified` errors (stderr) and VLC rescans all
plugins (~1s, self-healing). Root cause: `appimage.sh` sets `SOURCE_DATE_EPOCH` (reproducible
squashfs), which clamps every file mtime; a `plugins.dat` generated before the clamp is
guaranteed stale. `appimage.sh` now syncs the whole AppDir to the epoch (`touch -d
@$SOURCE_DATE_EPOCH`) and re-runs `vlc-cache-gen` on the synced tree before `appimagetool` —
the shipped cache then byte-matches a fresh generation. With the scan root read-only (squashfs
mount or fresh extraction), VLC 3.0.20 **cannot persist** the rebuilt cache, so the rescan
repeats on every launch; benign (no functional impact), but expect the stderr noise.

### Known issue (upstream, documented)

On first launch with empty storage, `Gui.qml:153` (`pReadyBrowse` binding) logs a TypeError
(`core.index` is null until the backend index is created); the binding resolves on the next
evaluation and everything proceeds. Second launch on existing storage is clean. Cosmetic log
noise only.

## Risks / notes

- **glibc baseline**: artifact built on 24.04 won't run on older distros — stated in release
  notes; widening later means rebuilding in an older container.
- **VLC plugin cache** (`plugins.dat` inside the read-only AppDir): superseded by "P2 results →
  VLC plugins cache" — the rescan is per-launch with a read-only scan root, benign.
- **appimagetool needs FUSE** (or run it with `--appimage-extract-and-run` itself in restricted
  environments).
- The app sets `VLC_PLUGIN_PATH` from `applicationDirPath()` — keep the `vlc/` directory layout
  identical to `deploy/` inside `AppDir/usr/bin/`.