# Phase 0 — foundations spike

Goal from the spec: prove the kernel, the engine and the controller on one Windows PC and one
mid-range Android phone, and settle the risky choices before real building starts.

**Exit gate:** a sample part rebuilds on the phone without dropping frames, and exports work
offline.

## Status

| Item | State | Notes |
| --- | --- | --- |
| Open CASCADE 8.0.1 minimal build script | Done | `tools/build_occt.sh`; Linux build verified locally |
| Parametric core: box, cylinder, sphere, cone, extrude (rect, circle, polyline), fillet, chamfer | Done | Add / cut / intersect / new body; per-feature errors never stop the rebuild |
| Expressions and variables with units | Done | `width / 2 + 3 mm`; bare numbers use the document unit |
| Face ownership through history (which feature made each face) | Done | Used for picking, highlights and push/pull |
| Exact picking and push/pull on faces | Done | Cut features move the other way (pushing a doorway wall narrows it) |
| Native `.fpprt` / `.fpasm` files | Done | ZIP + JSON, cached B-rep, safe writes, format version check |
| Assemblies: nested components, instances, virtual parts | Done | Mates are stored, not solved yet (Phase 3) |
| Export STEP (AP242/AP214), IGES, STL, 3MF with read-back validation | Done | Volume within 0.01% (exact) or 1% (mesh) |
| Headless core tests | Done | 97 checks pass on Linux |
| Godot extension (`CadPart`, `CadAssembly`) | Done | Builds on Linux, Windows and Android arm64 in CI; loads in Godot 4.7.2 |
| First-person player: walk with exact collision, fly, self-scaling 0.1 mm to 1 km | Written | Needs a playtest |
| Tool wheel, 8 tools, context option, HUD, model panel, file menu | Written | Needs a playtest |
| Xbox controller mapping and remapping storage | Written | Needs a playtest with a real controller on both platforms |
| Touch controls (Android fallback) | Written | Needs a phone |
| CI: Linux tests + Godot smoke test, Windows build + tests, Android arm64 build | Done | All green; the smoke test drives the extension and runs the main scene headless |
| Profile rebuild time and memory on a mid-range Android phone | **Open** | The gate measurement; needs a device |
| Floating origin and reverse-Z for extreme sizes | **Open** | Single precision is fine to about 10 µm at 10 m; revisit after the phone test |
| Rebuild on a worker thread | **Open** | Rebuilds take ~25 ms for the sample on a desktop core; move off the main thread in Phase 1 |

## How to run the gate check

1. On the phone, open the repository's Releases page, download the APK from the **android-dev** pre-release and install it (CI rebuilds it on every push).
2. Pair an Xbox controller over Bluetooth.
3. Open the sample, push the roof up and down with RT/LT for 30 seconds while walking.
4. Note the frame time (Godot's monitor overlay) and the rebuild time shown in the log.
