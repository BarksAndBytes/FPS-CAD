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
- **Video board**: plays a video from a link or a file. RT on empty floor sets one up and opens its
  video menu (`video_menu.gd`); RT on a video board pauses and resumes it, LT opens the menu. The
  menu offers **Enter a link…** (the on-screen keyboard has URL signs and Paste), **Choose a file
  on this device…** (the system's own picker: Windows' Open dialog filtered to video files,
  Android's document picker for `video/*`), and the **library**: every video kept in
  `user://videos`, newest first, with its title (a page's `<title>`, else the file name), size and
  date, each playable on the board at once or deletable, plus Delete all. The library index is
  `user://videos/library.json` (file → link, title, bytes, added); kept videos from before it are
  listed by their file id. A local file plays where it is if it is Theora, else is converted into
  the videos folder like a download; Android's picks are `content://` addresses only the system
  can read, so the board copies them in first (8 MB a frame, with progress), then plays or
  converts the copy. Deleting a video stops any board showing it first. Godot plays only Ogg Theora (.ogv) and only from a file, so the board
  downloads the link into `user://videos` (kept by an MD5 of the URL, so it plays again without
  downloading; 1 GB at most), showing progress, then checks the file's first bytes. A Theora
  video plays, letterboxed, looping, with its sound fading with distance (full within 3 board
  heights, silent past 20). Any other video (MP4/MOV, WebM/MKV, AVI, sound-only Ogg…) is
  converted to Theora by FFmpeg running in the background (`ffmpeg.exe` ships beside the game on
  Windows; Android ships a small FFmpeg built by `tools/build_ffmpeg.sh` as
  `lib/arm64-v8a/libffmpeg.so`, run from the app's native library folder, the one place Android
  lets an app run a program it ships; Linux uses an `ffmpeg` on the PATH), scaled to at most
  1280 px wide (854 on phones). libtheora encodes on one core and encoding is nearly all the time,
  so a downloaded video of 8 s or more is probed for its length, frame rate and sound, cut on frame
  boundaries into one slice per worker (every core but one, at most 8; half the cores on phones,
  at most 4), the slices encoded at once by separate FFmpeg processes (`-ss` / `-frames:v`) with
  the sound as one more, then joined without re-encoding (concat demuxer, `-c copy`); streams and
  short clips convert in one process. On 2 cores a 10 s 720p clip took 7.2 s instead of 12.3 s,
  with identical frame count and length. With the
  percentage on the board from FFmpeg's progress output, then kept like a download. A link to a
  web page plays the page's main video (`find_page_video`): the video the page declares
  (`og:video`, `twitter:player:stream`, a VideoObject's `contentUrl`), else its largest `<video>`
  by width × height (its `src` or first video `<source>`; script-made `blob:` sources skipped),
  else the first link to a video file; relative links resolve against the page or its `<base>`.
  Among a `<video>`'s `<source>`s it takes an Ogg one (plays without converting), else the tallest
  at or under 720p (480p on phones) by `data-height` or the transcode key, so a Wikipedia video
  comes as its 720p version rather than the original upload.
  HLS and DASH playlists (`.m3u8`, `.mpd`) go straight to FFmpeg, which reads the stream. Only one
  hop: a page whose video link leads to another page is an error. What can't play gets an error
  screen saying why: YouTube, Vimeo and similar sites (linked, or embedded in the page) are turned
  away, since their pages hold no video file and taking one means working around their stream
  protection and terms; pages with no video found, failed downloads (HTTP status, no
  connection, TLS), files FFmpeg can't read (with its last message) and, on Android, which has no
  FFmpeg yet, anything that needs converting, with the ffmpeg line to convert it on a computer.
  Downloads name the game (`FPS-CAD/<version> (<project link>; whiteboard video) Godot/<version>`,
  as Wikimedia's user-agent policy asks); a busy server (HTTP 429 or 503) is asked again after
  its `Retry-After` (else 5, 10, 20 s), three times at most, with a countdown on the board, and an
  error names the link that failed when it was the video found on a page.
  The link is saved with the board; a reopened part shows "Ready to play".
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

## Files (0.3)

The pause menu has **Save** and a **File** page: **New part…** (in MMGS, CGS, MKS, IPS or FPS),
**Open…**, **Save as…**, **Import STEP…** and the exports. Parts and assemblies live in
`user://projects`, one file each, named after the part. Save writes back to the file the document
came from; a document never saved gets a free name (`Bracket`, `Bracket 2`, ...) so it can never
overwrite another part. Save as asks for a name, renames the part and saves under it.

**Open** (`file_browser.gd`) lists every saved part and assembly, most recently changed first,
with kind, size and date: open, duplicate (`<name> copy`), or delete (the button asks "Sure?"
first). **Open a file on this device…** uses the system's picker; Android's `content://` picks
are copied into the projects folder, then opened. An opened part puts the player where the whole
model is in view, sized to it.

**Import STEP** reads the file with Open Cascade (`importStep`, in metres), keeps only its solids,
and adds an `import` feature: the shape is stored inside the part file (`imports/`), stands on the
ground centred on the origin, is the first body or a new body, moves with the Move tool (its
`x y z`), undoes, and invalidates the cached geometry when it changes.

## Finishing the part (0.4)

The wheel's **Finish** group holds Fillet, Chamfer, Hole and Shell. They work on what the player
aims at in the room, then open the feature panel on the sizes with a live preview:

- **Fillet / Chamfer**: the primary action picks or unpicks the edge nearest the crosshair (the
  reach grows with the player; the picked edges are drawn in the accent colour, the edge under
  the crosshair with its length and radius). The secondary action rounds or bevels the picked
  edges, or the edge aimed at when none are picked. The feature stores each edge as a point on it
  (`picks`, the edge's midpoint) and finds the nearest edge again on rebuild, within 2 % of the
  model's size, so the pick follows edits that move the edge a little.
- **Hole**: the primary action places a hole on the aimed face with its centre snapped to the
  grid in the face's own directions; the secondary action places it exactly at the crosshair.
  Types: simple, counterbore (bore Ø and depth), countersink (sink Ø and angle) and tapped
  (thread from a metric coarse or Unified table, drilled at its tap size). Ends: through all or
  blind with a depth. Stored as `point`, `normal`, `d`, `kind`, `end` and the type's sizes.
- **Shell**: the primary action picks faces to leave open, the secondary hollows the part with
  the wall thickness inwards (`faces` are face references, `t` the wall).
- **Extrude end conditions**: Blind (depth), Through all, and Up to the face aimed at (a flat
  face, stored as a face reference: the solid is trimmed by that face's plane). Directions: out
  of the plane, into it, both sides equally, or both sides with two depths (`depth2`).

## Repeat and reuse (0.5)

- **Linear pattern / Circular pattern** (wheel group **Repeat**): the primary action picks or
  unpicks features (those that add or cut a shape: primitives, extrudes, revolves, sweeps, lofts,
  holes, imports); the secondary action opens the panel. Linear: a direction (±X, ±Y, ±Z, along
  or against the straight edge aimed at, or a reference axis), count and spacing, and an optional
  second direction with its own count and spacing. Circular: the axis aimed at (a round face, a
  straight edge or a reference axis) or X / Y / Z through the origin, count and total angle (360°
  spaces the copies evenly; less puts the last copy at that angle). Each picked feature's shape is
  repeated with the feature's own result (add, cut, intersect, new body); overlapping copies are
  fused first so the body gets one clean boolean. Stored as a `pattern` feature (`features`,
  `kind`, `dir`/`flip`, `count`, `spacing`, `dir2`/`flip2`, `count2`, `spacing2`, or `axis`,
  `count`, `angle`).
- **Mirror**: the same picking; the plane is the flat face or reference plane aimed at, or a
  standard plane. With no features picked the whole part is mirrored and joined to itself.
- **Draft** (Finish group): pick the faces to draft, then aim at the flat face they are drafted
  from (the neutral plane) and press the secondary action. The faces lean in as they go away
  from the neutral face, like a part drawn from a mould; the angle steps by 1°.
- **Bodies** group: **Combine bodies** picks two or more bodies (the first is kept) and joins
  them, subtracts the others from it, or keeps only the overlap, using the others up or keeping
  them. **Split body** picks a body, then splits it in two with the face or plane aimed at (or a
  standard or reference plane). **Delete body** removes the body aimed at; the secondary action
  undoes. Bodies are remembered by a face on them, so the feature follows edits upstream.
- The wheel's inner ring grows with the number of groups so its buttons never overlap.

## Controlling the history (0.6)

The model panel (View / Tab) is the feature tree. A picked feature shows **▲ Move up / ▼ Move
down**, **Suppress / Unsuppress**, **Roll back to here** and, when the feature fails, **Re-pick
what it uses…**.

- **Rollback bar**: Roll back to here builds the part only up to that feature; the features
  below the bar are listed as rolled back and greyed, and an orange bar row sits in the tree
  (press it to roll forward). New features from any tool go in at the bar, which moves down past
  them, so a feature can be inserted mid-history. The bar is saved with the part (`rollback` in
  the manifest) and undoes like any edit.
- **Reorder**: a move that would make a feature fail that builds now is refused with the reason
  (for example a pattern moved above what it repeats); the bar stays in front of the same
  rolled-back features.
- **Suppress**: the feature is skipped in the rebuild; anything that then fails is named.
- **Re-pick**: switches to the tool that made the feature (fillet, chamfer, shell, draft, hole,
  patterns, mirror, body tools) with the feature as the target: picking again updates it instead
  of making a new one. Push/pull, up-to-face extrudes and planes on a face use a Re-pick tool that
  takes the face aimed at.
- **Stronger face references**: every face a feature makes is tagged with its *role* in that
  feature: an extrude's `start` and `end` caps and `side<k>` (the k-th profile edge), a flat
  face's axis (`p+z`) or a curved face's kind (`cyl`) for other shapes. Face references store the
  role; on rebuild the face with the same feature and role is taken first (nearest the old spot if
  a later cut split it), and only then the old nearest-face-with-that-normal rule. A push/pull of
  one of two parallel faces no longer jumps to the other when the sketch moves.

## Checking the design (0.7)

- **Measure** has two more options (LB / E): **face or edge** reads the edge under the crosshair
  (length; radius and diameter for arcs and circles) or else the face (area; radius and diameter
  for round faces; sphere and torus radii), with the edge or face highlighted before you press;
  **angle** takes two picks (flat faces, straight edges or round faces' axes) and gives the angle
  between them and its supplement. The readout goes on the board like a distance.
- **Section view** (Measure group): cuts the part through the crosshair facing you, or with the
  Front, Right or Top plane, or the flat face aimed at; your side is taken away. The cut is real
  for display, walking and aiming (the core meshes and picks each body cut by a half-space, the
  cut face tinted orange), so you can walk into the part; the model itself is unchanged and the
  cut stays through edits until the secondary action shows the whole part.
- **Interference** (Measure group): lists every pair of bodies that overlap with the shared
  volume, and marks the first overlap's centre.
- **Driven dimensions**: a new sketch dimension that would over-define the sketch is added as a
  reference dimension, shown in brackets: the solver measures it after each solve and it drives
  nothing (`driven: true` in the constraint). Typing a value into it makes it drive again when the
  sketch allows.
- **Under-defined geometry**: the solver reports which points can still move and which circles
  can still change size (from the constraint Jacobian's null space). Sketch geometry is drawn
  blue where it is still free and dark where it is defined, entity by entity, instead of the whole
  sketch turning dark only when it is fully defined.

## Assemblies (0.8)

- **New assembly** (File page) starts an empty assembly with **Insert part** ready. Insert part
  (wheel group **Assembly**) lists the saved parts; the chosen part is placed where you aimed (on
  the floor, snapped to the grid). The first component is grounded. Instances of one part are
  numbered (`Bracket <2>`). The secondary action removes the component aimed at (with its mates).
- **Mate**: pick a face on each of two components. Options: coincident facing (flat faces meet,
  normals opposed) or aligned (normals the same way); concentric (round faces share an axis);
  distance and angle (asked for, starting from what the faces measure now); lock (keeps the
  second where it is relative to the first). The solver (Levenberg–Marquardt with a numeric
  Jacobian and minimum-norm steps) moves components that are not grounded as little as it can. A
  mate that cannot be met with the others is refused and nothing moves. The secondary action
  clears the picks, or undoes the last change. Mate references are face references in the part
  (probe, normal, feature, role), so they follow edits to the parts.
- **Constrained drag**: the Move tool drags a component, solving the mates at every step, so it
  goes only where its mates let it and mated neighbours follow. A grounded component does not
  move.
- **Interference** (Measure group) lists the components whose solids overlap, with the volume.
- **Bill of materials** lists each part, its quantity, material and mass each.
- **Exploded view** spreads the components away from the assembly's centre (each along the line
  through its own centre), half a step per press; the secondary action puts them back. The
  spread is real for walking and aiming, and is not saved.
- The model panel lists the components (Ground / Float, Remove) and the mates (⚠ when not met,
  Delete), with the solver's status. Assemblies undo and redo.

## Drawings (0.9)

- **Standard views**: front, top and right in third-angle projection, plus an isometric, made
  with Open Cascade's hidden-line removal (`HLRBRep`): visible edges and silhouettes solid,
  hidden ones dashed. They are laid out on A3 at the largest standard scale that fits (50:1 …
  1:1000), with a border and a title block (part name, material, scale, units, projection).
  **Model dimensions**: each view's overall width and height, and the diameter of each full
  circle it shows (with a centre mark), in the part's units.
- **Drawing board** (Boards group): a whiteboard showing the part's drawing, which follows the
  part as it changes; pressing the primary action on it turns hidden lines on or off. The
  secondary action on it exports PDF and DXF to the exports folder; on a flat face of the part it
  exports that face's outline true size (DXF for cutting, PDF at 1:1 on the smallest A-size page
  that fits, else scaled to A0 with the scale printed).
- **File page**: *Drawing: PDF and DXF of the standard views* and *Save drawing (.fpdrw)*. While
  sketching, the pause menu has *Export sketch: DXF and PDF, true size* (construction geometry
  left out).
- **DXF**: R12 (AC1009) in millimetres, layers VISIBLE, HIDDEN (dashed line type), DIMENSIONS,
  BORDER; text with `%%c` for Ø. **PDF**: one vector page, Helvetica text (WinAnsi).
- **`.fpdrw`**: a zip with a manifest (`kind: drawing`) and `drawing.json` naming the part
  (`part.path` relative to the drawing, `part.fileId`) and the options. Opening it opens the part
  and sets up a drawing board in front of you.

## 1.0: hardening and performance

- Every extension method that reads data from the game (hits, sketches, planes, mate
  references) catches errors and returns a failure instead of letting an exception end the app.
- A part of a few hundred features' worth of geometry (a 144-hole pattern and a 40-boss row on a
  plate) rebuilds in about a quarter of a second and meshes in about a third (Release, desktop);
  `core/tests` keeps that as a test with a generous ceiling, so a pathological slowdown fails CI.
- Patterns that add material fuse all their copies in one general fuse (run in parallel) before
  the single boolean with the body.
- Face roles for extrude sides use sampled profile edges rather than exact distance queries, so
  sketches with many edges (text, perforations) cost milliseconds.
- Drawing boards redraw at most every 0.4 s while the part changes quickly (hidden-line removal
  is the slow step), and once more when the changes stop.
- [GUIDE.md](GUIDE.md) is the user guide for the whole workflow.

## Native file layout (`.fpprt`)

```
manifest.json            formatVersion, kind, fileId, app version, units, timestamps
history/features.json    ordered features with parameters and references
history/variables.json   global variables and equations
geometry/body-N.brep     cached B-rep per body (rebuilt from history if missing or stale)
views/viewpoints.json    saved "stand here" positions and sizes
views/boards.json        the whiteboards standing in the room
imports/index.json       ids of imported shapes; imports/<id>.brep each shape (OCCT binary BRep)
(manifest.json also holds `rollback`: the rollback bar's index, -1 when every feature is built)
```

An `.fpasm` adds `assembly/components.json` (file references by relative path + fileId, or
embedded virtual parts) and `assembly/mates.json`.

## Phase 0 exit gate

A sample part rebuilds on a mid-range Android phone without dropping frames, and STEP and STL
exports round-trip offline. See [`docs/PHASE0.md`](PHASE0.md) for the checklist.
