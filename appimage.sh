#!/bin/bash
#--------------------------------------------------------------------------------------------------
# appimage.sh — build the MotionBoxy Linux AppImage (docs/APPIMAGE_PLAN.md, phase P1)
#
# Pipeline:
#   1. ensure Sky/deploy is assembled (distro-Qt bridge, canonical 3rdparty builds, or prebuilt)
#   2. deploy.sh linux               -> deploy/ (binary + Qt/VLC runtime + backend/ + start.sh)
#   3. dependency closure pass       -> deploy/ (system libs the bundled ELFs need, $ORIGIN)
#   4. vlc-cache-gen deploy/         -> deploy/plugins.dat (VLC plugin cache, scan root)
#   5. AppDir assembly               -> build-appimage/AppDir (usr/bin + AppRun + .desktop + icon)
#   6. validation                    -> fatal on the Addendum 17 plugin gaps / missing payload
#   7. appimagetool                  -> MotionBoxy-<version>-x86_64.AppImage
#
# Environment:
#   SK_PREBUILT=1      use Sky/deploy as-is (skip every Sky-side step)
#   SK_CANONICAL=1     assemble Sky/deploy via Sky/deploy.sh (3rdparty source builds)
#   MOTIONBOXY_VERSION AppImage version (default 1.0.0)
#   VLC_PREFIX         prefix of the local VLC install (distro-Qt bridge; default ../vlc-runtime)
#   APPIMAGETOOL       appimagetool binary (default: PATH, then ../tools/appimagetool*)
#
# NOTE: requires the deploy-mode binary to be built first (docs/APPIMAGE_PLAN.md "P0 results",
#       pipeline step 3-4): bin/MotionBox with CONFIG+=deploy.
#--------------------------------------------------------------------------------------------------
set -e

target="MotionBox"

version="${MOTIONBOXY_VERSION:-1.0.0}"

appimage="MotionBoxy-$version-x86_64.AppImage"

appdir="build-appimage/AppDir"

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

Sky="$root/../Sky"

cd "$root"

#--------------------------------------------------------------------------------------------------
# Syntax
#--------------------------------------------------------------------------------------------------

if [ $# = 1 ] && [ "$1" = "clean" ]; then

    echo "CLEANING"

    rm -rf "$appdir" "$appimage"

    exit 0
fi

if [ $# != 0 ]; then

    echo "Usage: appimage.sh [clean]"

    exit 1
fi

if [ ! -x bin/$target ]; then

    echo "ERROR: bin/$target not built (see docs/APPIMAGE_PLAN.md 'P0 results', pipeline step 3-4)"

    exit 1
fi

# bin/MotionBox must be the DEPLOY build (SK_DEPLOY, qrc-embedded); the dev-runtime binary
# loads QML from disk and cannot be packaged. Discriminator: the deploy build links
# qmlcache_loader.o (thousands of `qmlcache` symbols); the dev build has none. A path
# reference like "shaders/video.frag.qsb" is NOT sufficient — the dev binary contains the
# same literal (it loads the shaders from disk).

if ! nm bin/$target 2>/dev/null | grep -qi qmlcache; then

    echo "ERROR: bin/$target is not the deploy-mode build (no qmlcache symbols)."
    echo "       bin/ is also the dev-runtime dir; the dev build must NOT be packaged."
    echo "       Rebuild deploy mode: cd build-deploy && make (rm bin/MotionBox first —"
    echo "       see docs/APPIMAGE_PLAN.md 'P0 results')."

    exit 1
fi

#--------------------------------------------------------------------------------------------------
# 1. Sky/deploy
#--------------------------------------------------------------------------------------------------

echo ""
echo "SKY"
echo "---"

if [ -n "$SK_PREBUILT" ]; then

    echo "SK_PREBUILT: using $Sky/deploy as-is"

elif [ -n "$SK_CANONICAL" ]; then

    (cd "$Sky" && sh deploy.sh linux tools)

elif [ -e "$Sky/deploy/libvlc.so.5" ]; then

    echo "$Sky/deploy already assembled: using as-is"

else
    sh "$root"/dist/appimage/sky-deploy-linux.sh
fi

#--------------------------------------------------------------------------------------------------
# 2. deploy.sh (Sky side is settled above)
#--------------------------------------------------------------------------------------------------

echo ""
echo "DEPLOY"
echo "------"

SK_PREBUILT=1 sh deploy.sh linux

#--------------------------------------------------------------------------------------------------
# 3. Dependency closure pass
#
# BFS over DT_NEEDED of every bundled ELF (binary + libs + Qt/VLC plugins). Any needed lib that
# is not already bundled and not in the skip-list is copied from the system into deploy/ (real
# file, SONAME basename) with rpath $ORIGIN. Fixes the SONAME-gap class: bundled codec plugins
# link libavcodec.so.60 et al., which older distros do not ship.
#
# Skip-list = base + guaranteed desktop stack (glibc family, libstdc++/libgcc, X11/GLVND/wayland,
# glib family, dbus/systemd, pulse, font stack, compression, krb5, libproxy) — hosts provide
# these; bundling them would shadow the host stack for no benefit.
#--------------------------------------------------------------------------------------------------

echo ""
echo "CLOSURE"
echo "-------"

PATCHELF=${PATCHELF:-}

if [ -z "$PATCHELF" ]; then

    if command -v patchelf >/dev/null 2>&1; then
        PATCHELF=$(command -v patchelf)
    else
        PATCHELF="$root/../tools/patchelf/usr/bin/patchelf"
    fi
fi

SYS_DIRS="/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /usr/lib /lib"

SKIP_RE='(linux-vdso|ld-linux-x86-64|libc\.so|libm\.so|libpthread|libdl\.so|librt\.so|libresolv|libanl|libutil\.so|libcrypt|libBrokenLocale|libnss_|libnsl|libstdc\+\+|libgcc_s|libX11|libXau|libXdmcp|libxcb|libxkbcommon|libEGL\.so|libGLX\.so|libGLdispatch|libOpenGL\.so|libGL\.so|libgbm|libwayland|libdrm|libXext|libXfixes|libXrender|libXi\.so|libXcursor|libXrandr|libXinerama|libXcomposite|libXdamage|libICE\.so|libSM\.so|libglib-2|libgobject-2|libgio-2|libgmodule-2|libdbus-1|libsystemd|libpulse|libasyncns|libapparmor|libsamplerate|libfontconfig|libfreetype|libharfbuzz|libgraphite2|libpng16|libmd4c|libb2\.so|libdouble-conversion|libpcre2|libbrotli|libz\.so|libzstd|liblzma|liblz4|libbz2|libexpat|libffi|libselinux|libmount|libblkid|libcap\.so|libkeyutils|libgssapi_krb5|libkrb5|libk5crypto|libcom_err|libproxy|libpxbackend|libduktape|libmd\.so|libbsd)'

closure()
{
    declare -A KNOWN

    while IFS= read -r f; do
        KNOWN[$(basename "$f")]=1
    done < <(find deploy -name "*.so*" ! -name "*.la" -type f -o -name "*.so*" ! -name "*.la" -type l)

    CHANGED=1
    ROUNDS=0

    while [ $CHANGED = 1 ]; do

        CHANGED=0
        ROUNDS=$((ROUNDS + 1))

        while IFS= read -r elf; do

            [ -f "$elf" ] || continue

            deps=$(readelf -d "$elf" 2>/dev/null | awk '/NEEDED/{print $NF}' | tr -d '[]')

            for d in $deps; do

                echo "$d" | grep -qE "$SKIP_RE" && continue

                [ -n "${KNOWN[$d]:-}" ] && continue

                found=""
                for dir in $SYS_DIRS; do
                    if [ -e "$dir/$d" ]; then found="$dir/$d"; break; fi
                done

                if [ -z "$found" ]; then
                    echo "MISSING: $d (needed by $elf)"
                    continue
                fi

                cp -L "$found" "deploy/$d"
                "$PATCHELF" --set-rpath '$ORIGIN' "deploy/$d"

                KNOWN[$d]=1
                echo "BUNDLED: $d  <- $elf"

                CHANGED=1
            done
        done < <(find deploy -name "*.so*" ! -name "*.la"; echo deploy/$target)
    done

    echo "closure done (rounds: $ROUNDS)"
}

closure

#--------------------------------------------------------------------------------------------------
# 4. VLC plugin cache (scan root = applicationDirPath; entries stored relative)
#--------------------------------------------------------------------------------------------------

echo ""
echo "PLUGIN CACHE"
echo "------------"

VLC_CACHE_GEN=${VLC_CACHE_GEN:-}

if [ -z "$VLC_CACHE_GEN" ]; then

    for candidate in "$root/../vlc-runtime/lib/vlc/vlc-cache-gen" \
                     "$Sky/../vlc-3.0.20/bin/vlc-cache-gen" \
                     "$(command -v vlc-cache-gen || true)"; do

        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            VLC_CACHE_GEN="$candidate"
            break
        fi
    done
fi

if [ -z "$VLC_CACHE_GEN" ]; then

    echo "ERROR: vlc-cache-gen not found (VLC_CACHE_GEN, ../vlc-runtime, ../vlc-3.0.20, PATH)"

    exit 1
fi

echo "vlc-cache-gen: $VLC_CACHE_GEN"

LD_LIBRARY_PATH="$root/deploy" "$VLC_CACHE_GEN" "$root/deploy"

ls -la deploy/plugins.dat

#--------------------------------------------------------------------------------------------------
# 5. AppDir
#--------------------------------------------------------------------------------------------------

echo ""
echo "APPDIR"
echo "------"

rm -rf "$appdir"

mkdir -p "$appdir/usr/bin"

cp -a deploy/. "$appdir/usr/bin/"

cp "$root"/dist/appimage/AppRun            "$appdir"/AppRun
cp "$root"/dist/appimage/motionboxy.desktop "$appdir"/motionboxy.desktop

cp "$root"/dist/icon.png "$appdir"/motionboxy.png
cp "$root"/dist/icon.png "$appdir"/.DirIcon

mkdir -p "$appdir"/usr/share/icons/hicolor/512x512/apps

cp "$root"/dist/icon.png "$appdir"/usr/share/icons/hicolor/512x512/apps/motionboxy.png

chmod +x "$appdir"/AppRun "$appdir"/usr/bin/start.sh

#--------------------------------------------------------------------------------------------------
# 6. Validation (fatal)
#--------------------------------------------------------------------------------------------------

echo ""
echo "VALIDATION"
echo "----------"

fail()
{
    echo "VALIDATION FAILED: $1"

    exit 1
}

[ -x "$appdir/usr/bin/$target" ] || fail "usr/bin/$target missing"

# Addendum 17 plugin gaps: pulse aout (+ helper lib), TS demuxer, Opus decoder
[ -e "$appdir/usr/bin/vlc/libvlc_pulse.so.0" ]                  || fail "libvlc_pulse.so.0 missing"
[ -e "$appdir/usr/bin/vlc/plugins/audio_output/libpulse_plugin.so" ] || fail "pulse aout plugin missing"
[ -e "$appdir/usr/bin/vlc/plugins/demux/libts_plugin.so" ]      || fail "TS demuxer plugin missing"
[ -e "$appdir/usr/bin/vlc/plugins/codec/libopus_plugin.so" ]    || fail "Opus decoder plugin missing"

[ -e "$appdir/usr/bin/plugins.dat" ]                            || fail "plugins.dat missing"

[ -e "$appdir/usr/bin/backend" ] && [ -n "$(ls -A "$appdir/usr/bin/backend")" ] \
                                                                || fail "backend/ payload missing"

nm "$appdir/usr/bin/$target" 2>/dev/null | grep -qi qmlcache \
                                                                || fail "deploy-mode binary not embedded (qmlcache symbols missing)"

[ -e "$appdir/.DirIcon" ]          || fail ".DirIcon missing"
[ -e "$appdir/motionboxy.desktop" ] || fail "motionboxy.desktop missing"

plugins=$(find "$appdir/usr/bin/vlc/plugins" -name "*.so" | wc -l)

[ "$plugins" -ge 200 ] || fail "suspiciously few VLC plugins ($plugins)"

if command -v desktop-file-validate >/dev/null 2>&1; then

    desktop-file-validate "$appdir/motionboxy.desktop" || fail "motionboxy.desktop invalid"

else
    echo "NOTE: desktop-file-validate not installed, skipping .desktop check"
fi

echo "validation OK ($plugins VLC plugins)"

#--------------------------------------------------------------------------------------------------
# 7. appimagetool
#--------------------------------------------------------------------------------------------------

echo ""
echo "APPIMAGETOOL"
echo "------------"

APPIMAGETOOL=${APPIMAGETOOL:-}

if [ -z "$APPIMAGETOOL" ]; then

    APPIMAGETOOL=$(command -v appimagetool || true)

    if [ -z "$APPIMAGETOOL" ]; then

        APPIMAGETOOL=$(ls "$root"/../tools/appimagetool*.AppImage 2>/dev/null | head -1)
    fi
fi

if [ -z "$APPIMAGETOOL" ] || [ ! -e "$APPIMAGETOOL" ]; then

    echo "ERROR: appimagetool not found"
    echo "       install it from https://github.com/AppImage/appimagetool/releases"
    echo "       and point APPIMAGETOOL at it (or put it in ../tools/)"

    exit 1
fi

echo "appimagetool: $APPIMAGETOOL"

# AppImage-run tooling: consume --appimage-extract-and-run at the runtime level (works with and
# without FUSE; skipped for plain binaries).

EXTRACT=""

if "$APPIMAGETOOL" --appimage-extract-and-run --version >/dev/null 2>&1; then

    EXTRACT="--appimage-extract-and-run"
fi

SOURCE_DATE_EPOCH=$(git -C "$root" log -1 --format=%at 2>/dev/null || date +%s)

# Sync the AppDir file mtimes to SOURCE_DATE_EPOCH BEFORE the plugin cache is (re)generated:
# squashfs clamps every mtime to that epoch, so cache entries taken from unclamped mtimes go
# stale on first run ("stale plugins cache" rescan). Touching the tree first makes the clamp
# a no-op and keeps plugins.dat valid. (vlc-cache-gen is re-run below on the synced tree.)

find "$appdir" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

"$VLC_CACHE_GEN" "$appdir/usr/bin"

SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH "$APPIMAGETOOL" $EXTRACT \
    "$appdir" \
    "$root/$appimage"

echo ""
ls -la "$root/$appimage"

sha256sum "$root/$appimage"

echo ""
echo "OK: $appimage"