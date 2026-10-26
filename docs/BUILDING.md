# Building FPS-CAD

FPS-CAD has three layers, built in this order:

1. **Open CASCADE 8.0** (the geometry kernel), built once per platform as shared libraries.
2. **The CAD core, CLI and tests** (`core/`), plain CMake.
3. **The Godot extension** (`extension/`), which links the core and godot-cpp, then the Godot
   project (`godot/`) that loads it.

CI builds all three for Linux, Windows and Android on every push; download the `godot/bin`
artifacts from a run if you only want to play.

## Requirements

| Tool | Version |
| --- | --- |
| CMake | 3.21+ |
| Ninja | any recent |
| C++ compiler | GCC 11+, Clang 14+, or Visual Studio 2022 |
| Python | 3.8+ (godot-cpp bindings, staging script) |
| Godot | 4.5 or newer (4.7.2 tested in CI) |
| Android NDK | r26 or newer, for Android builds |

nlohmann/json, miniz and godot-cpp are fetched from GitHub when CMake configures.

## 1. Open CASCADE

```bash
tools/build_occt.sh <install-prefix> linux     # or windows (from a VS developer shell), android
```

The script builds only the modules the core uses (modelling, meshing, STEP/IGES/STL, XCAF) and
skips visualisation back-ends and the Draw harness. Set `OCCT_TAG` to change the version
(default `V8_0_1`) and `ANDROID_NDK_HOME` for Android.

## 2. Core, CLI and tests

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<occt-prefix>
cmake --build build
ctest --test-dir build --output-on-failure
```

On Linux set `LD_LIBRARY_PATH=<occt-prefix>/lib` to run the tests and CLI; on Windows add
`<occt-prefix>/win64/vc14/bin` to `PATH`.

## 3. Godot extension and project

```bash
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=<occt-prefix> \
  -DFPCAD_BUILD_EXTENSION=ON -DGODOTCPP_TARGET=template_debug
cmake --build build
python3 tools/stage_occt.py --occt <occt-prefix> --platform linux   # or windows
```

The extension lands in `godot/bin/` as `libfpcad.<platform>.<target>.<arch>`, and the staging
script copies the Open CASCADE libraries next to it and lists them in `fpcad.gdextension` so
Godot exports them. Open `godot/` in the Godot editor and press Play.

Build `-DGODOTCPP_TARGET=template_release` as well before exporting a release build.

### Android

```bash
tools/build_occt.sh <occt-android> android
cmake -S . -B build-android -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_shared \
  -DCMAKE_FIND_ROOT_PATH=<occt-android> -DCMAKE_PREFIX_PATH=<occt-android> \
  -DFPCAD_BUILD_TESTS=OFF -DFPCAD_BUILD_CLI=OFF -DFPCAD_BUILD_EXTENSION=ON
cmake --build build-android
python3 tools/stage_occt.py --occt <occt-android> --platform android \
  --extra $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so
```

Then export with the **Android** preset in `godot/export_presets.cfg` (install Godot's Android
export templates and set a debug keystore in Editor Settings first).

## Running the Godot smoke test headless

```bash
godot --headless --path godot --import
godot --headless --path godot --script res://tests/smoke_test.gd
```
