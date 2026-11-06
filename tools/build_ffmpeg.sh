#!/usr/bin/env bash
# Builds a small FFmpeg program for the video board: it reads common web videos and streams and
# writes Ogg Theora, nothing else. One static executable with libogg, libvorbis, libtheora and
# mbedtls (for https streams) linked in. LGPL 3 (Mbed TLS is Apache 2.0, which needs FFmpeg's
# --enable-version3); no GPL parts (no x264 / x265).
#
#   tools/build_ffmpeg.sh <install prefix> android   # arm64-v8a, needs ANDROID_NDK_HOME
#   tools/build_ffmpeg.sh <install prefix> linux     # the same build for this machine (testing)
#
# The program lands in <prefix>/bin/ffmpeg. The Android build ships inside the APK as
# lib/arm64-v8a/libffmpeg.so: Android only runs programs from the app's native library folder.
set -euo pipefail

PREFIX="$(mkdir -p "$1" && cd "$1" && pwd)"
PLATFORM="${2:?android or linux}"
FFMPEG_TAG="${FFMPEG_TAG:-n8.1.3}"
OGG_VERSION=1.3.5
VORBIS_VERSION=1.3.7
THEORA_TAG=v1.2.0
MBEDTLS_VERSION=3.6.2
API=29
JOBS="$(nproc 2>/dev/null || echo 4)"
WORK="${WORK:-$PREFIX/.build}"
mkdir -p "$WORK"
# On a failure, show the end of the newest log (the build steps keep their output in $WORK).
trap 'echo "build failed; the newest log:" >&2; ls -t "$WORK"/*.log 2>/dev/null | head -1 | xargs -r tail -n 40 >&2' ERR
DEPS="$PREFIX/deps"

if [ "$PLATFORM" = android ]; then
  : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
  TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
  HOST=aarch64-linux-android
  export CC="$TC/bin/${HOST}${API}-clang" CXX="$TC/bin/${HOST}${API}-clang++"
  export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip" NM="$TC/bin/llvm-nm"
  CMAKE_TC=(-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
            -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API)
  CONF_HOST=(--host=$HOST)
elif [ "$PLATFORM" = linux ]; then
  export CC="${CC:-cc}" CXX="${CXX:-c++}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" STRIP="${STRIP:-strip}" NM="${NM:-nm}"
  CMAKE_TC=()
  CONF_HOST=()
else
  echo "unknown platform $PLATFORM" >&2
  exit 2
fi
export CFLAGS="-O2 -fPIC"

fetch() {  # url, dir: download a release archive and unpack it into $WORK/dir
  local url="$1" dir="$2"
  [ -d "$WORK/$dir" ] && return
  curl -sSL --retry 3 -o "$WORK/$dir.archive" "$url"
  mkdir -p "$WORK/$dir"
  tar -xf "$WORK/$dir.archive" -C "$WORK/$dir" --strip-components=1
}

cmake_lib() {  # dir, extra cmake args...: build and install a CMake library statically into $DEPS
  local dir="$1"; shift
  cmake -S "$WORK/$dir" -B "$WORK/$dir/build" -G "Unix Makefiles" "${CMAKE_TC[@]}" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_PREFIX_PATH="$DEPS" \
    -DCMAKE_FIND_ROOT_PATH="$DEPS" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@" > "$WORK/$dir.cmake.log"
  cmake --build "$WORK/$dir/build" -j "$JOBS" > "$WORK/$dir.build.log"
  cmake --install "$WORK/$dir/build" > /dev/null
}

echo "== libogg $OGG_VERSION"
fetch "https://github.com/xiph/ogg/releases/download/v$OGG_VERSION/libogg-$OGG_VERSION.tar.gz" ogg
[ -f "$DEPS/lib/libogg.a" ] || cmake_lib ogg -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF

echo "== libvorbis $VORBIS_VERSION"
fetch "https://github.com/xiph/vorbis/releases/download/v$VORBIS_VERSION/libvorbis-$VORBIS_VERSION.tar.gz" vorbis
[ -f "$DEPS/lib/libvorbisenc.a" ] || cmake_lib vorbis -DOGG_ROOT="$DEPS" -DBUILD_TESTING=OFF

echo "== libtheora $THEORA_TAG"
if [ ! -f "$DEPS/lib/libtheoraenc.a" ]; then
  [ -d "$WORK/theora" ] || git -c advice.detachedHead=false clone -q --depth 1 --branch "$THEORA_TAG" https://github.com/xiph/theora "$WORK/theora"
  (cd "$WORK/theora" && { [ -x configure ] || ./autogen.sh > "$WORK/theora.autogen.log" 2>&1; } \
    && PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" ./configure "${CONF_HOST[@]}" --prefix="$DEPS" \
       --disable-shared --enable-static --disable-examples --disable-spec --disable-doc \
       --disable-oggtest --disable-vorbistest --with-ogg="$DEPS" --with-vorbis="$DEPS" \
       $( [ "$PLATFORM" = android ] && echo --disable-asm ) > "$WORK/theora.configure.log" \
    && make -j "$JOBS" > "$WORK/theora.build.log" && make install > /dev/null)
fi

echo "== mbedtls $MBEDTLS_VERSION"
fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2" mbedtls
[ -f "$DEPS/lib/libmbedtls.a" ] || cmake_lib mbedtls -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF

echo "== FFmpeg $FFMPEG_TAG"
[ -d "$WORK/ffmpeg" ] || git -c advice.detachedHead=false clone -q --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg "$WORK/ffmpeg"
CROSS=()
if [ "$PLATFORM" = android ]; then
  CROSS=(--enable-cross-compile --target-os=android --arch=aarch64 --cpu=armv8-a
         --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --nm="$NM"
         --sysroot="$TC/sysroot")
fi
cd "$WORK/ffmpeg"
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" ./configure \
  --prefix="$PREFIX" "${CROSS[@]}" \
  --pkg-config=pkg-config --pkg-config-flags=--static \
  --extra-cflags="-I$DEPS/include" --extra-ldflags="-L$DEPS/lib" --extra-libs="-lm" \
  --disable-everything --disable-autodetect --disable-doc --disable-debug \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg --disable-shared --enable-static --enable-small \
  --enable-version3 --enable-zlib --enable-libtheora --enable-libvorbis --enable-mbedtls --enable-swscale --enable-swresample \
  --enable-protocol=file,pipe,http,https,tcp,udp,tls,hls,crypto \
  --enable-demuxer=mov,matroska,ogg,mpegts,hls,avi,flv,mpegps,m4v,mp3,aac,wav,flac,h264,hevc \
  --enable-decoder=h264,hevc,vp8,vp9,mpeg4,mpeg2video,mpeg1video,h263,msmpeg4v3,mjpeg,theora,aac,aac_latm,mp3,mp3float,mp2,opus,vorbis,flac,ac3,eac3,pcm_s16le,pcm_s24le,pcm_f32le \
  --enable-parser=h264,hevc,vp8,vp9,mpeg4video,mpegvideo,mjpeg,aac,aac_latm,mpegaudio,opus,vorbis,flac,ac3 \
  --enable-encoder=libtheora,libvorbis \
  --enable-muxer=ogg \
  --enable-filter=scale,aresample,aformat,format,null,anull,copy,acopy,setpts,asetpts \
  > "$WORK/ffmpeg.configure.log" || { tail -30 "$WORK/ffbuild/config.log" 2>/dev/null || tail -30 ffbuild/config.log; exit 1; }
make -j "$JOBS" > "$WORK/ffmpeg.build.log"
make install > /dev/null
"$STRIP" "$PREFIX/bin/ffmpeg"
ls -la "$PREFIX/bin/ffmpeg"
echo "built $PREFIX/bin/ffmpeg for $PLATFORM"
