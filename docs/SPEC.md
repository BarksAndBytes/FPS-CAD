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
| Hosting | Fully local. No cloud services, telemetry or accounts. One exception: published Android builds fetch a public `latest.json` at launch and can download and install a newer build in-app (nothing is sent; off switch in the pause menu) |
| Android signing | Every published build is signed with the same FPS-CAD key and numbered by CI run, so new builds install over old ones as updates |
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
| X / Y | Finish sketch / inspect target parameters; in sketch mode Y switches between the sketch view and free look |
| D-pad up / down | Grow / shrink (×1.41 per tap, hold to keep going, faster the longer it is held; size glides on a critically damped curve). At 1:1 the player is 1.83 m (6 ft) tall, eyes at 1.70 m; the body blocks from step height to the top of the head |
| D-pad left / right | Undo / redo |
| View / Menu | Controls map / pause menu |

## Modelling workflow

Standard history-based CAD: choose a plane (Top / Front / Right or any flat face), draw a sketch,
constrain it, then build a feature from it. Sketches are `sketch` features (plane, points,
lines / circles / arcs, constraints) solved by the core; `extrude`, `revolve`, `sweep` and `loft`
reference them by id, so editing a sketch's dimension rebuilds everything after it. Feature
parameters are set in a property panel with a live preview. Direct tools (push/pull, boxes,
cylinders, spheres) remain for quick blocking-out. Push/pull edits the dimension that drives a
face when there is one; on any other face (an extrude's side, a revolve's curved outside) it adds
or removes stock as a *Push/Pull* (`face_offset`) feature: the face is thickened outward (a prism
for flat faces, an offset along the surface for curved ones) or cut inward, and its distance then
drives the face. The feature finds its face again on every rebuild, so it follows earlier
changes. Details: [`docs/SKETCHING.md`](SKETCHING.md).
How this compares with SOLIDWORKS, Fusion and Inventor, and which gaps matter most:
[`docs/CAD_COMPARISON.md`](CAD_COMPARISON.md).

## Reference geometry

The **Reference** group on the tool wheel builds planes, axes, points and coordinate systems.
They are features in the history like any other, worked out again on every rebuild from what they
were built on, so they follow the model (faces, edges and corners are found again the way
push/pull faces and converted sketch edges are). LB picks the kind; RT picks what it is built
from, one thing at a time; LT starts again.

| Tool | Kinds (LB) | Picks |
| --- | --- | --- |
| Plane | offset · at an angle · through three points · midway | a flat face, a reference plane or the ground (Top); an edge, round face or axis for the angle; corners for points |
| Axis | edge or cylinder · through two points · where two planes meet | a straight edge (the face's edge nearest the crosshair) or a round face; corners; faces or planes |
| Point | on a corner · face centre · at the crosshair | a corner; a face; anywhere (then X, Y, Z) |
| Coordinate system | — | a face: origin on the nearest corner, Z along the face's normal, X along its nearest edge |

Offset and angled planes and typed points open the feature panel with a live preview (distance,
angle, X / Y / Z); they can be edited later from the model panel. Planes are drawn as tinted
squares, axes dashed, points as small crosses and coordinate systems as red / green / blue arrows,
each with its name. The **Sketch** tool sketches on a reference plane aimed at (or a coordinate
system's XY plane); the sketch stays on the plane, so moving the plane moves it and everything
built from it. **Revolve** offers reference axes as well as the sketch's own.

The **Measure** group adds **Bounding box** (the parts' extent as a wire box, X × Y × Z on the
whiteboard) and **Mass properties** (volume, area, mass from the part's material, and a marker at
the centre of mass).

## Units and materials

**Units** (pause menu → Units) are the standard CAD unit systems: **MMGS** (mm, g), **CGS** (cm,
g), **MKS** (m, kg), **IPS** (in, lb) and **FPS** (ft, lb), seconds throughout. The length unit is
the part's display and typing unit; the mass unit is used for mass, and density reads g/cm³,
kg/m³, lb/in³ or lb/ft³ to match. Changing units never changes the part: plain numbers inside
expressions that were read in the old unit get it written after them ("wall + 2" becomes
"wall + 2 mm"; factors such as "width / 2" and angles are left alone), and `CadPart.set_units`
rebuilds and compares volume, area, centre of mass and bounding box before and after, refusing
(and restoring the part) if anything moved. Lengths on screen follow: mm and m in metric parts,
inches (feet past 1,000 in) in IPS, feet (inches under a foot) in FPS; stresses read MPa / GPa,
or ksi / Msi in IPS and FPS. Export uses the part's length unit (FPS exports in inches). The mass
unit is saved in the manifest as `massUnits`; older files use g for mm and cm, kg for m and lb
for in and ft.

**Materials** (pause menu → Material) come from a library in the core (`core/src/Materials.cpp`):
aluminium 6061-T6 and 7075-T6, steel AISI 1020, stainless 304, grey cast iron, titanium
Ti-6Al-4V, brass C360, copper C110, ABS, PLA, nylon 6/6, polycarbonate, acrylic, oak, concrete and
soda-lime glass. Each has typical room-temperature properties (density, Young's modulus,
Poisson's ratio, yield and ultimate tensile strength, where a brittle material has no yield,
thermal conductivity, specific heat and expansion) and an appearance (colour, metallic,
roughness, opacity) that the part takes on: metals shine, plastics are matt, glass and the clear
plastics are see-through. **Custom density…** takes a density typed in the unit system's density
unit; a custom material claims no other properties. Choosing a material is undoable; the
properties board shows the material, its density, E, yield, UTS and Poisson's ratio. Files from
before the library call aluminium "Aluminium 6061", read as 6061-T6.

## The room

Everything happens in a bright white room with a skylight that grows with the player and fades
into white haze, so it never feels walled in (`godot/scripts/room.gd`). Free build and challenges
add a wooden table, 4 ft × 2 ft and 75 cm high ("Old Wooden Table" by carlcapu9, CC BY 4.0), whose
top is the CAD ground; the player starts on the floor walking up to it. Training, new parts and the
assembly sandbox have no table: the room floor is the CAD ground. Free build opens a desk organiser
sample (`PartDocument::deskSample`) driven by width, depth, height and wall variables.

**The whiteboard.** Messages are written on a whiteboard standing in the room ("Whiteboards +" by
Michael V, CC BY 4.0) instead of over the view: the training objective or the challenge card
(name, brief, hint, timer, last comparison), the sketch status, the latest three notices (they fade
after 12 s) and the size / snap / position readout. It stands at 1:1 beside the table in free
build and challenges; elsewhere it is set down on the ground ahead of the player (training moves
it to each objective). It is solid. While it cannot be read (out of view, behind the player, or
too small on screen) new notices and the sketch status show on screen as before. The screen keeps
the tool chip and hint, the crosshair and aim label, measurements, menus and dialogs.

**Boards the player adds** (`godot/scripts/boards.gd`, the wheel's **Boards** group, parts only):
- **Properties board**: the part's name, volume, surface area, mass (with the part's material and
  density), bounding box, centre of mass, and body and feature counts, in the document's units,
  updated whenever the part changes. RT sets one up where the crosshair meets the floor (or a
  little way ahead), facing the player and sized to the player's current size.
- **Notes board**: the player's notes, one bullet per line. RT on empty floor sets up a board and
  asks for the first note; RT on a notes board adds a note; LT on a note edits it (clear it to
  delete it).
- **Video board**: plays a video from a link. RT on empty floor sets one up and asks for the link
  (the on-screen keyboard has URL signs and Paste); RT on a video board pauses and resumes it, LT
  changes its link. Godot plays only Ogg Theora (.ogv) and only from a file, so the board
  downloads the link into `user://videos` (kept by an MD5 of the URL, so it plays again without
  downloading; 1 GB at most), showing progress, then checks the file's first bytes. A Theora
  video plays, letterboxed, looping, with its sound fading with distance (full within 3 board
  heights, silent past 20). Anything else gets an error screen on the board saying what it was:
  links to YouTube, Vimeo and other sites that show video in a page are turned away before
  downloading; MP4/MOV, WebM/MKV, web pages, sound-only Ogg, failed downloads (HTTP status,
  no connection, TLS) and undecodable files are named, with the ffmpeg line that converts a
  video to .ogv. The link is saved with the board; a reopened part shows "Ready to play".
- **Arrange boards**: RT picks up any board, the message board included. A carried board stays at
  the same distance ahead and turned the same way relative to the player, standing on the floor;
  D-pad ← / → (mouse wheel) turns it 15°, ↑ / ↓ (= / −) resizes it ×1.25 about its feet (0.1× to
  12×), RT sets it down, LT puts it back. LT on a board removes it (not the message board).
  Changing tool sets a carried board down.
Boards always stand on the room floor, whatever they are scaled to. The layout (kind, position,
yaw, scale, notes) is saved in the part file as `views/boards.json`, outside the feature history:
undo and redo leave boards where they are, and the geometry cache stays valid.

## Challenge mode

A series of target parts to copy (`core/src/Challenges.cpp`), from a 100 × 75 × 50 block to a
mounting bracket with holes on two faces; finishing one unlocks the next. The target is shown as a
hologram with dimension callouts beside a blank part. After every change the core compares the two
(`fpcad/Compare.h`): a copy passes when it is the same solid, whatever its position, orientation
or the features that made it. The check uses volume, area and principal moments first (which also
give hints such as "90 % of the target's volume"), then candidate rotations from principal axes,
face normals, hole axes and farthest vertices, confirmed by an exact boolean. Mirror images are
reported, not passed.

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
