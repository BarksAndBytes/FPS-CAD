# First-Person CAD — engineering summary

The full product spec lives in the shared doc **First-Person CAD — Product Spec**
(<https://claude.ai/artifact/7XbRS4VAmsCUqXCA9V9aBZ>). This file pins the decisions the code
depends on, so a contributor can work from the repo alone.

## Product in one paragraph

A parametric solid modeler played like a first-person game. You walk the model, change your own
size to zoom, and swap tools from a weapon wheel. Windows PC and Android ship together, an Xbox
controller is the primary input on both, and everything runs locally: no accounts, servers or
network calls for modeling, saving or export.

## Fixed decisions

| Area | Decision |
| --- | --- |
| Platforms | Windows 10/11 x64 and Android 10+ (API 29) arm64, equal first platforms |
| Input | Xbox controller primary; keyboard and mouse equal on PC; touch fallback on Android |
| Engine | Godot 4 + C++ GDExtension (`extension/`) over an engine-agnostic C++ core (`core/`) |
| Kernel | Open CASCADE Technology 8.0.x, shared libraries (LGPL 2.1 with exception) |
| Hosting | Fully local. No cloud services, telemetry or accounts |
| Native files | `.fpprt` part, `.fpasm` assembly, `.fpdrw` drawing (after 1.0), `.fppack` bundle |
| Container | ZIP + pretty-printed JSON, cached B-rep, `formatVersion` integer, safe writes |
| Export | STEP (AP242 default, AP214 option), IGES 5.3, STL (binary default), 3MF — all offline |
| Parasolid | Dropped from 1.0: no local Android writer exists without a licensed SDK |
| Internal units | Metres. Document display units are per file (mm default) |
| Modeling | History-based parametric parts, multi-body parts, full assemblies with mates |

## Controller mapping (summary)

| Control | Action |
| --- | --- |
| Left stick / click | Move / toggle sprint |
| Right stick / click | Look / precision aim |
| Right trigger | Primary tool action |
| Left trigger | Secondary tool action |
| Right bumper (hold) | Tool wheel |
| Left bumper (hold) | Context wheel (snap modes, mate types, options) |
| A / B | Jump or fly up / crouch, fly down, back |
| A / B in menus | Select / back |
| X / Y | Finish sketch / inspect target parameters; in sketch mode Y looks straight at the plane |
| D-pad up / down | Grow / shrink (x2 per tap, hold for smooth) |
| D-pad left / right | Undo / redo |
| View / Menu | Controls map / pause menu |

## Modelling workflow

Standard history-based CAD: choose a plane (Top / Front / Right or any flat face), draw a sketch,
constrain it, then build a feature from it. Sketches are `sketch` features (plane, points,
lines / circles / arcs, constraints) solved by the core; `extrude`, `revolve`, `sweep` and `loft`
reference them by id, so editing a sketch's dimension rebuilds everything after it. Feature
parameters are set in a property panel with a live preview. Direct tools (push/pull, boxes,
cylinders, spheres) remain for quick blocking-out. Details: [`docs/SKETCHING.md`](SKETCHING.md).

## Onboarding

Launch shows three skippable splash cards (studio, technology, "best played with a controller"),
then the title screen over an orbiting model: Training, New part, Free build, Assembly sandbox,
Controls, Quit. Training runs on the core's `trainingCourse()` part and checks real game state
for each of its fourteen objectives, including sketching on a face and extruding it. Completion is stored in `user://settings.cfg`.

## Native file layout (`.fpprt`)

```
manifest.json            formatVersion, kind, fileId, app version, units, timestamps
history/features.json    ordered features with parameters and references
history/variables.json   global variables and equations
geometry/body-N.brep     cached B-rep per body (rebuilt from history if missing or stale)
views/viewpoints.json    saved "stand here" positions and sizes
```

An `.fpasm` adds `assembly/components.json` (file references by relative path + fileId, or
embedded virtual parts) and `assembly/mates.json`.

## Phase 0 exit gate

A sample part rebuilds on a mid-range Android phone without dropping frames, and STEP and STL
exports round-trip offline. See [`docs/PHASE0.md`](PHASE0.md) for the checklist.
