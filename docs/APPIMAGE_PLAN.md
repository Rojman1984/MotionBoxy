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

- **P0 — Preconditions.** Verify a from-scratch `build.sh all linux` (or equivalent manual
  pipeline) yields a complete `deploy/`: pulse helper + TS demuxer + Opus decoder plugins
  present, `plugins.dat`, shaders baked, `backend/` payload, working `start.sh` launch. Document
  the apt package list (build + VLC deps + `patchelf`, `qt6-shadertools`, `appimagetool`).
- **P1 — AppImage script.** Add to the repo:
  - `dist/appimage/motionboxy.desktop` (Name=MotionBoxy, Exec=MotionBox, Icon=motionboxy,
    Categories=AudioVideo;Video;Player;) + app icon PNG.
  - `appimage.sh` (repo root, sibling of `deploy.sh`): runs the deploy pipeline, assembles the
    AppDir (`usr/` ← `deploy/`, `AppRun` → `exec ./start.sh`, `.desktop`, icon), validates the
    plugin set (fails the build if `libvlc_pulse.so.0` / `libts_plugin.so` /
    `libopus_plugin.so` are missing — the Addendum 17 gaps), then invokes `appimagetool`
    producing `MotionBoxy-<version>-x86_64.AppImage`.
- **P2 — Local smoke test.** Run the AppImage on this machine (Wayland + X11): fresh storage in
  a clean `HOME`, video renders, and `run/storage/log.txt`-equivalent `[vlc]` log shows
  `using audio output module pulse`, TS demux and Opus decode active. Also run with
  `--appimage-extract-and-run` (no-FUSE path).
- **P3 — Warehouse.** `gh release create appimage-v1 MotionBoxy-*.AppImage SHA256SUMS` on
  `Rojman1984/MotionBoxy` with notes (baseline, contents, usage).
- **P4 — (optional) CI.** GitHub Actions workflow on `Rojman1984/MotionBoxy` in an
  `ubuntu:22.04` container: apt deps → build → `appimage.sh` → attach to release. Decide there
  whether VLC/libtorrent come from apt dev packages or Sky's `3rdparty.sh` source builds.
- **P5 — Retire the ad-hoc runtime.** After P2/P3 acceptance, `run/` + hand-bundled `bin/` become
  dev-only fallbacks. Update SDD (Addendum 18: packaging & distribution).

## Acceptance checklist

- [ ] AppImage launches from a clean `$HOME` (storage auto-created; no run/ dir present)
- [ ] Video + audio OK; `[vlc]` log confirms pulse aout, TS demuxer, Opus decoder
- [ ] `--appimage-extract-and-run` works (systems without FUSE)
- [ ] `desktop-file-validate` passes; icon shows in a desktop environment
- [ ] Release `appimage-v1` visible with AppImage + SHA256SUMS attached

## Risks / notes

- **glibc baseline**: artifact built on 22.04 won't run on older distros — stated in release
  notes; widening later means rebuilding in a 20.04 container.
- **VLC plugin cache** (`plugins.dat` inside the read-only AppDir): VLC rebuilds its cache in the
  user cache dir on version mismatch — benign, already how the dev runtime behaves.
- **appimagetool needs FUSE** (or run it with `--appimage-extract-and-run` itself in restricted
  environments).
- The app sets `VLC_PLUGIN_PATH` from `applicationDirPath()` — keep the `vlc/` directory layout
  identical to `deploy/` inside `AppDir/usr/bin/`.