#!/usr/bin/env bash
# Builds the slice of Open CASCADE that FPS-CAD needs (modelling, meshing, STEP/IGES/STL, XCAF)
# as shared libraries, without visualisation back-ends or the Draw test harness.
#
#   tools/build_occt.sh <install-prefix> [linux|windows|android]
#
# Environment:
#   OCCT_TAG          Open CASCADE git tag (default V8_0_1)
#   ANDROID_NDK_HOME  NDK root, for android builds
#   JOBS              parallel jobs (default: all cores)
set -euo pipefail

PREFIX="${1:?usage: build_occt.sh <install-prefix> [linux|windows|android]}"
PLATFORM="${2:-linux}"
TAG="${OCCT_TAG:-V8_0_1}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
WORK="${OCCT_WORK:-$(pwd)/.occt-src}"

if [ ! -d "$WORK/src" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/Open-Cascade-SAS/OCCT "$WORK/src"
fi

ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DBUILD_LIBRARY_TYPE=Shared
  -DBUILD_MODULE_Draw=OFF
  -DBUILD_MODULE_Visualization=OFF
  -DBUILD_MODULE_ApplicationFramework=ON
  -DBUILD_MODULE_DataExchange=ON
  -DBUILD_DOC_Overview=OFF
  -DBUILD_GTEST=OFF
  -DBUILD_USE_PCH=ON
  -DUSE_FREETYPE=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_D3D=OFF -DUSE_TK=OFF -DUSE_TCL=OFF
  -DUSE_FREEIMAGE=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_VTK=OFF -DUSE_TBB=OFF
)

case "$PLATFORM" in
  android)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the NDK root}"
    ARGS+=(
      -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI=arm64-v8a
      -DANDROID_PLATFORM=android-29
      -DANDROID_STL=c++_shared
    )
    ;;
  linux|windows) ;;
  *) echo "unknown platform $PLATFORM" >&2; exit 2 ;;
esac

cmake -S "$WORK/src" -B "$WORK/build-$PLATFORM" -G Ninja "${ARGS[@]}"
cmake --build "$WORK/build-$PLATFORM" -j "$JOBS" --target install
echo "Open CASCADE $TAG installed to $PREFIX"
