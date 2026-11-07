# FPS-CAD

Parametric CAD you play in first person. Walk around your model, change your own size to zoom,
and pick tools from a weapon wheel. Built for an Xbox controller on Windows PC and Android, with
keyboard and mouse as an equal on PC. Everything runs locally: no accounts, servers or network.

Parts and assemblies keep their full editable history in native files (`.fpprt`, `.fpasm`) and
export to STEP, IGES, STL and 3MF.

> Status: **Phase 1 — the CAD workflow.** Pick a plane or a flat face, sketch with relations and
> dimensions, then extrude, revolve, sweep or loft, all in the part's history. Mates solving and
> drawings come in later phases. See [docs/PHASE0.md](docs/PHASE0.md) and
> [docs/SKETCHING.md](docs/SKETCHING.md).

## What is here

| Path | What it is |
| --- | --- |
| `core/` | Engine-agnostic C++17 CAD core on Open CASCADE: parametric features, expressions, rebuild, picking, push/pull, native files, exports |
| `core/cli/` | `fpcad` command-line tool: create samples, inspect, edit parameters, export |
| `core/tests/` | Headless tests, including export read-back validation |
| `extension/` | Godot 4 GDExtension exposing the core as `CadPart` and `CadAssembly` |
| `godot/` | The game: first-person player, self-scaling, tool wheel, HUD, touch controls |
| `prototypes/web-v1/` | The original browser prototype |
| `docs/` | Engineering spec summary, build guide, Phase 0 checklist, comparison with professional CAD |
| `tools/` | Open CASCADE build and staging scripts |

The full product spec is the shared doc **First-Person CAD — Product Spec**;
[docs/SPEC.md](docs/SPEC.md) pins the decisions the code depends on.
[docs/CAD_COMPARISON.md](docs/CAD_COMPARISON.md) reviews FPS-CAD against SOLIDWORKS, Fusion and
Inventor, area by area, with a suggested order for closing the gaps.

## Try it

Download the latest build from the Releases page: **windows-dev** for a PC (unzip, run
`FPS-CAD.exe`) or **android-dev** for a phone (install the APK).

## Quick start (Linux or Windows)

```bash
tools/build_occt.sh "$HOME/occt" linux          # once, about 30–60 minutes
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH="$HOME/occt" -DFPCAD_BUILD_EXTENSION=ON
cmake --build build
ctest --test-dir build --output-on-failure      # LD_LIBRARY_PATH=$HOME/occt/lib on Linux
python3 tools/stage_occt.py --occt "$HOME/occt" --platform linux
godot --path godot                              # Godot 4.5 or newer
```

Full instructions, including Windows and Android: [docs/BUILDING.md](docs/BUILDING.md).

## Controls

New players start with **Training** on the title screen: a fourteen-step course that teaches
moving, jumping, shrinking through a 30 cm tunnel, the tool wheel, push/pull, sketching a
rectangle on a face, finishing the sketch, extruding it, measuring and the controls map.
**New part** opens a blank part with the Sketch tool ready.
**Challenges** asks you to copy target parts, from a plain block to a mounting bracket: build it
any way you like, in any orientation, and it passes when the geometry matches. Press View (F1) at any time for the full map:

![Controller map](godot/ui/controller_map.svg)

| Xbox controller | Keyboard and mouse | Action |
| --- | --- | --- |
| Left stick | WASD | Move (L3 toggles sprint; Shift sprints) |
| Right stick | Mouse | Look (R3 / Alt: precision aim) |
| RT / LT | Left / right click | Tool primary / secondary action |
| Hold RB | Hold Q | Tool wheel (mouse toward a group, then further out toward a tool; let go of Q or click to pick) |
| LB | E | Cycle the tool's option |
| D-pad ↑ / ↓ | Scroll, = / − | Grow / shrink (a tap is a gentle step, holding keeps going and speeds up; sizes glide); R resets to 1:1, about 6 ft tall |
| D-pad ← / → | Ctrl+Z / Ctrl+Shift+Z | Undo / redo |
| A / B | Space / C | Jump or fly up / fly down |
| A / B | Enter / Esc | Select / back in every menu |
| Y | I, Tab | Inspect the target's parameters (model panel) |
| View | F1 | Controls map (controller, keyboard and touch pages) |
| Menu | Esc | Pause menu: controls, units (MMGS, CGS, MKS, IPS, FPS), material, save, File (new part, open, save as, import STEP, export), exit to title |
| — | F | Fly through walls |
| X | Enter | Finish the sketch |
| Y (sketching) | I | Sketch view ↔ free look (sketches open square to the plane, X right, Y up) |

The tool wheel groups tools: **Select**, **Sketch**, **Solids** (Extrude, Revolve, Sweep,
Loft), **Modify** (Push/Pull, Move, Delete), **Primitives** (Box, Cylinder, Sphere),
**Reference** (Plane, Axis, Point, Coordinate system), **Measure** (Measure, Bounding box, Mass properties) and **Boards** (Properties board, Notes board, Video board, Arrange boards: whiteboards you set up in the room, carry, turn and resize; while carrying one the D-pad ← / → or mouse wheel turns it and ↑ / ↓ or = / − resizes it). Aiming at a group shows its tools branching out from it; let go (or press A) to open
the branch, then aim and press A / RT to pick. B steps back. In sketch mode the wheel holds the sketch tools: Lines (line, rectangles, polygon, slot, point), Curves (circles, arcs, tangent arc, ellipse, spline), Modify (trim, extend, fillet, chamfer, offset, convert edges), Copy (move, copy, rotate, scale, mirror, patterns), Constrain, Text, Construction and Delete. Modify also has split. Messages (objectives, challenge cards, notices, the sketch status and the readout) are written on a whiteboard in the room rather than over the view; they come back on screen only while the board is out of sight. The full sketch and feature-panel controls are
in [docs/SKETCHING.md](docs/SKETCHING.md) and on the controls map's fourth page.

## The CLI

```bash
fpcad sample pavilion.fpprt
fpcad info pavilion.fpprt
fpcad set pavilion.fpprt "Roof.h=450"            # plain numbers use the document's units
fpcad export pavilion.fpprt pavilion.step --units mm
fpcad sample-assembly pins.fpasm && fpcad export pins.fpasm pins.3mf
```

## Licences

FPS-CAD's own code: see the repository licence once chosen. Open CASCADE Technology is LGPL 2.1
with an exception and ships as separate shared libraries; see [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).
