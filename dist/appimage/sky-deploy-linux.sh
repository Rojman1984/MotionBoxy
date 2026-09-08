#!/bin/sh
#--------------------------------------------------------------------------------------------------
# sky-deploy-linux.sh — assemble Sky/deploy for linux from DISTRO Qt + a locally built VLC
# (P0-verified equivalent of Sky/3rdparty.sh + Sky/deploy.sh linux; see
# docs/APPIMAGE_PLAN.md "P0 results"). For the canonical 3rdparty source-build layout, use
# Sky/deploy.sh instead (run appimage.sh with SK_CANONICAL=1).
#
# Expected local VLC install layout ($VLC_PREFIX, default ../vlc-runtime):
#   $VLC_PREFIX/lib/libvlc.so.5* libvlccore.so.9*   (core)
#   $VLC_PREFIX/lib/vlc/lib*.so*                    (helper libs, e.g. libvlc_pulse.so.0)
#   $VLC_PREFIX/lib/vlc/vlc-cache-gen               (plugin cache generator)
#   $VLC_PREFIX/lib/vlc/plugins/<category>/lib*_plugin.so
#
# Environment:
#   VLC_PREFIX  prefix of the local VLC install (see layout above)
#   PATCHELF    patchelf binary (default: which patchelf, then ../tools/patchelf/usr/bin)
#   QMAKE       qmake binary (default: qmake6, then qmake)
#--------------------------------------------------------------------------------------------------
set -e

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

Sky="$root/../Sky"

deploy="$Sky/deploy"

#--------------------------------------------------------------------------------------------------
# Tool discovery
#--------------------------------------------------------------------------------------------------

QMAKE=${QMAKE:-}

if [ -z "$QMAKE" ]; then

    if command -v qmake6 >/dev/null 2>&1; then
        QMAKE="qmake6"
    else
        QMAKE="qmake"
    fi
fi

PATCHELF=${PATCHELF:-}

if [ -z "$PATCHELF" ]; then

    if command -v patchelf >/dev/null 2>&1; then
        PATCHELF=$(command -v patchelf)
    else
        PATCHELF="$root/../tools/patchelf/usr/bin/patchelf"
    fi
fi

VLC_PREFIX=${VLC_PREFIX:-"$root/../vlc-runtime"}

VLC_LIB="$VLC_PREFIX/lib"

QT_LIBS=$($QMAKE -query QT_INSTALL_LIBS)

QT_PLUGINS=$($QMAKE -query QT_INSTALL_PLUGINS)

QT_QML=$($QMAKE -query QT_INSTALL_QML)

echo "QT  : $QT_LIBS"
echo "VLC : $VLC_LIB"
echo "PATELF: $PATCHELF"

#--------------------------------------------------------------------------------------------------
# Helpers
#--------------------------------------------------------------------------------------------------

# soname_of <lib-base> — resolve the SONAME-level file name of a system library
soname_of()
{
    file=$(ls "$QT_LIBS"/$1.so.* 2>/dev/null | head -1)

    if [ -z "$file" ]; then
        return 1
    fi

    readelf -d "$(readlink -f "$file")" | awk '/SONAME/{print $NF}' | tr -d '[]'
}

#--------------------------------------------------------------------------------------------------
# Clean
#--------------------------------------------------------------------------------------------------

echo "CLEANING $deploy"

rm -rf "$deploy"/*

touch "$deploy"/.gitignore

mkdir -p "$deploy"/platforms \
         "$deploy"/imageformats \
         "$deploy"/tls \
         "$deploy"/multimedia \
         "$deploy"/xcbglintegrations \
         "$deploy"/QtQuick \
         "$deploy"/QtMultimedia \
         "$deploy"/QtQml/WorkerScript \
         "$deploy"/shaders \
         "$deploy"/vlc

#--------------------------------------------------------------------------------------------------
# Qt libraries
#--------------------------------------------------------------------------------------------------

echo "COPYING Qt"

for lib in Core Gui Network OpenGL Qml QmlModels QmlWorkerScript Quick QuickParticles \
           QuickShapes QuickWidgets Svg Widgets Xml Multimedia MultimediaQuick \
           XcbQpa DBus Core5Compat Concurrent Positioning ShaderTools; do

    if [ -f "$QT_LIBS/libQt6$lib.so.6" ]; then

        cp "$QT_LIBS/libQt6$lib.so.6" "$deploy"

    else
        echo "SKIP libQt6$lib.so.6 (not installed)"
    fi
done

#--------------------------------------------------------------------------------------------------
# ICU, OpenSSL, libtorrent, Boost (SONAME-resolved)
#--------------------------------------------------------------------------------------------------

echo "COPYING ICU / SSL / torrent"

for base in libicudata libicui18n libicuuc libssl libcrypto libtorrent-rasterbar; do

    soname=$(soname_of $base) || { echo "SKIP $base (not installed)"; continue; }

    cp -L "$QT_LIBS/$soname" "$deploy/$soname"
done

# NOTE MotionBoxy/deploy.sh copies libboost*.so* unconditionally; the system libtorrent has
#      boost statically linked and the binary does not use it, but a stub keeps the glob
#      satisfied.

if soname=$(soname_of libboost_system); then

    cp -L "$QT_LIBS/$soname" "$deploy/$soname"

else
    echo "NOTE: no libboost_system found, creating stub"

    touch "$deploy/libboost_system.so.0"
fi

#--------------------------------------------------------------------------------------------------
# Qt plugins
#--------------------------------------------------------------------------------------------------

cp "$QT_PLUGINS"/platforms/libqxcb.so "$deploy"/platforms

cp "$QT_PLUGINS"/imageformats/libqsvg.so  "$deploy"/imageformats
cp "$QT_PLUGINS"/imageformats/libqjpeg.so "$deploy"/imageformats

if [ -f "$QT_PLUGINS"/imageformats/libqwebp.so ]; then

    cp "$QT_PLUGINS"/imageformats/libqwebp.so "$deploy"/imageformats
fi

cp "$QT_PLUGINS"/tls/libqopensslbackend.so "$deploy"/tls

cp "$QT_PLUGINS"/multimedia/libffmpegmediaplugin.so "$deploy"/multimedia

cp "$QT_PLUGINS"/xcbglintegrations/libqxcb-egl-integration.so "$deploy"/xcbglintegrations
cp "$QT_PLUGINS"/xcbglintegrations/libqxcb-glx-integration.so "$deploy"/xcbglintegrations

#--------------------------------------------------------------------------------------------------
# Qt qml modules (only those the content imports: QtQuick, QtMultimedia + WorkerScript)
#--------------------------------------------------------------------------------------------------

cp "$QT_QML"/QtQuick/libqtquick2plugin.so "$deploy"/QtQuick
cp "$QT_QML"/QtQuick/qmldir               "$deploy"/QtQuick

cp "$QT_QML"/QtMultimedia/libquickmultimediaplugin.so "$deploy"/QtMultimedia
cp "$QT_QML"/QtMultimedia/qmldir                      "$deploy"/QtMultimedia

cp "$QT_QML"/QtQml/WorkerScript/libworkerscriptplugin.so "$deploy"/QtQml/WorkerScript
cp "$QT_QML"/QtQml/WorkerScript/qmldir                   "$deploy"/QtQml/WorkerScript

#--------------------------------------------------------------------------------------------------
# VLC (local build; complete plugin set)
#--------------------------------------------------------------------------------------------------

echo "COPYING VLC"

cp "$VLC_LIB"/libvlc.so.5*     "$deploy"
cp "$VLC_LIB"/libvlccore.so.9* "$deploy"

cp "$VLC_LIB"/vlc/lib*.so* "$deploy"/vlc

mkdir -p "$deploy"/vlc/plugins

cp -r "$VLC_LIB"/vlc/plugins/. "$deploy"/vlc/plugins/

find "$deploy"/vlc/plugins -name "*.la" -delete

#--------------------------------------------------------------------------------------------------
# Shaders (baked .qsb for the qrc-embedded video pipeline)
# Flags (SDD Addendum 17): qsb --batchable --glsl "100 es,120,150" --hlsl 50 --msl 12
#--------------------------------------------------------------------------------------------------

if ls "$root"/bin/shaders/*.qsb >/dev/null 2>&1; then

    cp "$root"/bin/shaders/*.qsb "$deploy"/shaders/

else
    echo "ERROR: no baked shaders in bin/shaders (run the build first)"

    exit 1
fi

#--------------------------------------------------------------------------------------------------
# rpaths (same scheme as Sky/deploy.sh linux)
#--------------------------------------------------------------------------------------------------

echo "PATCHING rpaths"

find "$deploy" -maxdepth 1 -name "lib*.so*" -exec "$PATCHELF" --set-rpath '$ORIGIN' {} \;

find "$deploy"/vlc -maxdepth 1 -name "lib*.so*" -exec "$PATCHELF" --set-rpath '$ORIGIN/../' {} \;

find "$deploy"/vlc/plugins -name "*.so" -exec "$PATCHELF" --set-rpath \
                          '$ORIGIN/../../:$ORIGIN/../../../' {} \;

echo "DONE"

ls "$deploy"