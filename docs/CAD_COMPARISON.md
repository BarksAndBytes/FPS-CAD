# FPS-CAD compared with professional CAD

A capability-by-capability review of SOLIDWORKS, Autodesk Fusion and Autodesk Inventor against
FPS-CAD (first written at build 39, October 2026; the sketching section is updated for the
November 2026 sketch tools). It is a planning document: nothing here changes the code.

**Versions reviewed:** SOLIDWORKS 2026; Autodesk Fusion through its October 2026 update;
Autodesk Inventor 2026, plus what Autodesk lists as new for Inventor 2027. Sources are at the end.

**FPS-CAD status key**

| Mark | Meaning |
| --- | --- |
| ✓ | In the game: usable from the tools, wheel, panels or menus |
| ◐ | Partly there: a subset, or in the CAD core (files, CLI) without an in-game tool yet |
| ✗ | Not yet |
| — | Out of scope for FPS-CAD as specified (see notes) |

Where the three packages name the same idea differently, the professional column gives the
names as **SOLIDWORKS / Fusion / Inventor**. A single name means all three use it (or close to it).

---

## Scorecard

| Area | Typical professional depth | FPS-CAD today | Coverage |
| --- | --- | --- | --- |
| Sketching | ~60 entity, edit and constraint tools | 15 drawing tools (incl. polygon, slot, ellipse, spline, text), trim/extend/split/fillet/chamfer/offset/linked convert, live move, copy/rotate/scale/mirror, live patterns, smart dimensions, 12 relations, snap inference | High |
| Part features | ~40 sketched and applied features | Extrude (end conditions), revolve, sweep, loft, push/pull, primitives, fillet, chamfer, hole, shell | Medium |
| Patterns and mirror | Linear, circular, curve, sketch, table, fill; mirror | Linear (two directions), circular, mirror of features or the whole part | Medium |
| Reference geometry | Planes, axes, points, coordinate systems | Offset / angled / 3-point / mid planes, edge / cylinder / 2-point / 2-plane axes, points, coordinate systems; all follow the model | High |
| Parameters | Equations, global variables, configurations, design tables | Variables and expressions | Medium |
| Surfacing, freeform, mesh | Full surface toolsets, T-splines, mesh repair | None | None |
| Sheet metal, weldments, plastics, mold | Dedicated environments | None | None |
| Assemblies | Mates/joints solved, motion, interference, BOM, standard parts | Insert saved parts, solved mates (coincident, concentric, distance, angle, lock), constrained drag, interference, BOM, exploded view | Medium |
| Drawings and MBD | 2D drawings, GD&T, BOM tables, 3D annotations | Standard views with hidden lines and overall/hole dimensions, true-size sketch and face views, PDF and DXF, `.fpdrw` | Low–medium |
| Inspection and analysis | Measure, mass properties, section, interference, draft, curvature | Measure distance, angle, length, radius, area; bounding box; mass properties; walkable section view; body interference | Medium |
| Simulation and generative | FEA, motion, CFD, topology, generative | None | None |
| Manufacturing | CAM, additive prep, nesting, costing | STL/3MF export only | Low |
| Data management | PDM / Vault / cloud versions, branching | Local native files with history; undo/redo; autosave | Low (by design) |
| Interoperability | Dozens of import/export formats | Export STEP, IGES, STL, 3MF with read-back validation; no import | Low–medium |
| Automation and API | VBA/C# API, Python/JS API, iLogic | Headless C++ core and CLI | Low |
| Platform and input | Desktop, mouse and keyboard; Fusion also web | First person, any size, controller first, Android and Windows, offline | Unique |

---

## 1. Sketching

### 1.1 Sketch placement and setup

| Capability | Professional (SW / Fusion / Inventor) | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Sketch on standard planes | Front, Top, Right / XY, XZ, YZ / origin planes | ✓ | Top, Front, Right |
| Sketch on a planar face | All three | ✓ | Aim at a flat face |
| Sketch on a user-defined plane | Reference plane / construction plane / work plane | ✗ | Needs reference planes (§2) |
| 3D sketch | 3D Sketch / sketch in 3D / 3D Sketch | ✗ | |
| Sketch view square to the plane | Normal To / Look At / Look At | ✓ | Automatic on entering a sketch; Y toggles free look |
| Edit sketch plane after creation | Edit Sketch Plane / Redefine / Redefine | ✗ | |
| Sketch picture / canvas | Sketch Picture / Canvas / Image | ✗ | Tracing reference images |
| Sketch blocks | Blocks / — / Sketch Blocks | ✗ | |
| Grid and snapping | All three | ✓ | Snaps to points, origin, grid; snap step follows zoom |
| Inferencing (snap to midpoints, alignment lines, tangency) | All three | ◐ | Points, origin, midpoints and onto lines and curves (adding midpoint / point-on relations), grid, horizontal/vertical alignment with the previous point; no tangency inference |

### 1.2 Sketch entities

| Entity | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Line (chained) | All three | ✓ | |
| Centreline / construction line | Centerline / construction toggle / construction style | ✓ | Construction mode (LB) for every drawing tool, dashed |
| Midpoint line | SW | ✗ | |
| Rectangle: corner | All three | ✓ | Adds horizontal/vertical relations |
| Rectangle: centre, 3-point | All three | ✓ | Centre rectangle with construction diagonals; 3-point at any angle |
| Rectangle: parallelogram | SW, Inventor | ✗ | |
| Circle: centre-radius | All three | ✓ | |
| Circle: 3-point | All three | ✓ | Existing points it passes through stay on it |
| Circle: 2-point, tangent to three | All three | ✗ | |
| Arc: centre-point | All three | ✓ | Takes the shorter way round |
| Arc: tangent, 3-point | All three | ✓ | Tangent arc carries on from a line or arc end and chains |
| Slot: straight centre-to-centre | All three (Inventor added a slot feature in 2027) | ✓ | Tangent lines and equal arcs, construction centreline |
| Slot: overall, centre-point, arc | All three | ✗ | |
| Polygon | All three | ✓ | 3–12 sides, inscribed in a construction circle, equal sides |
| Ellipse | All three | ✓ | Centre, axis end, second semi-axis |
| Partial ellipse | All three | ✗ | |
| Spline: fit point | All three | ✓ | Open or closed; B-spline through the points |
| Spline: tangent ends | All three | ✓ | Tangent to the line or arc a spline ends on |
| Spline: control point / style spline, curvature handles | All three | ✗ | |
| Conic, parabola | SW, Fusion (conic curve) | ✗ | |
| Sketch fillet and chamfer | All three | ✓ | Line-line corners; virtual sharp kept when referenced |
| Point | All three | ✓ | Stand-alone points |
| Text | All three | ✓ | Single font (the game's UI font), stays level; extrudes and cuts |
| Offset entities | Offset Entities / Offset / Offset | ✓ | Whole chains of lines and arcs, circles; parallel + distance held |
| Project / convert edges into the sketch | Convert Entities / Project / Project Geometry | ✓ | A face's edges, linked: they follow the model on rebuild and keep their ids |
| Intersection curve | All three | ✗ | |
| Trim, extend | All three | ✓ | Lines, arcs, circles; new ends stay on the crossing geometry |
| Split, break | All three | ✓ | Lines, arcs; circles at two places |
| Mirror entities | All three | ✓ | Held symmetric about the mirror line |
| Sketch patterns (linear, circular) | All three | ✓ | Live: copies held to the original; count, spacing and spread editable |
| Move, copy, rotate, scale | All three | ✓ | Solved against existing relations; refused if they forbid it |
| Live dragging | All three | ✓ | Move solves the sketch live at the crosshair before placing |
| Stretch (move some points of a selection) | SW, Inventor | ✗ | |

### 1.3 Relations (constraints)

| Relation | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Horizontal, vertical | All three | ✓ | Also added automatically |
| Coincident | All three | ✓ | Point on point, point on line, point on circle |
| Parallel, perpendicular | All three | ✓ | |
| Equal | All three | ✓ | Lines, or circles and arcs |
| Tangent | All three | ✓ | Line–circle/arc and circle/arc–circle/arc, inside or outside; no spline or ellipse tangency |
| Fix / lock | Fix / Fix / Fix | ✓ | |
| Midpoint | All three | ✓ | |
| Concentric | All three | ✓ | Circles, arcs, ellipses |
| Coradial | SW | ✗ | Concentric plus equal does the same |
| Collinear | All three | ✓ | |
| Symmetric | All three | ✓ | Two points about a line |
| Curvature (G2), smooth | SW, Fusion, Inventor | ✗ | Tangent (G1) spline ends only |
| Pierce (to a 3D curve) | SW | ✗ | |
| Automatic relations while drawing | All three | ◐ | Horizontal, vertical, midpoint, point-on, tangent (tangent arc, fillet, slot), square corners (rectangles) |
| Show / delete relations | Display/Delete Relations / show constraints / Show Constraints | ◐ | Delete tool's alternate action removes them; no on-screen glyphs |

### 1.4 Dimensions and sketch status

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Linear, aligned, horizontal, vertical | All three | ✓ | |
| Radius, diameter | All three | ✓ | |
| Angular dimension | All three | ✓ | Pick two lines |
| Point-to-line and parallel-line distance | All three | ✓ | |
| Ordinate / baseline dimensions | All three | ✗ | |
| Driven (reference) dimensions | All three | ✓ | An over-defining dimension becomes a reference dimension in brackets (0.7) |
| Dimensions as expressions | Equations / parameters / parameters | ✓ | `width / 2`, `25 mm`, part variables |
| Degrees-of-freedom status | Fully/under/over defined / constraint status / DOF | ✓ | HUD message; free geometry blue and defined geometry dark, entity by entity (0.7) |
| Conflict detection | SketchXpert / warnings / warnings | ✓ | A conflicting change is refused with a message |
| Find under-constrained geometry | Fusion "Find Under-Constrained" (Oct 2026) | ✗ | |
| Closed-profile shading | All three | ✓ | Holes cut out; construction excluded |

---

## 2. Reference geometry

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Offset plane | Plane / Offset Plane / Work Plane | ✓ | From a flat face, a standard plane or another reference plane; signed distance, editable |
| Plane at angle, through three points, midplane | All three | ✓ | Midway between parallel faces, or halving the angle between others |
| Plane tangent to a curved face, plane normal to a curve | All three | ✗ | |
| Axis (straight edge, cylinder, two points, two planes) | Axis / Axis / Work Axis | ✓ | Revolve can turn about a reference axis |
| Point (XYZ values, on a corner, face centre) | All three | ✓ | |
| Coordinate system | All three; Fusion exports UCS to STEP (Oct 2026) | ◐ | Placed on a face (corner and edge snap); not yet used by export |
| Sketch on a reference plane, following it | All three | ✓ | Moving the plane moves the sketch and everything built from it |
| Bounding box | SW Bounding Box (enhanced in 2026) | ✓ | Drawn as a wire box; X × Y × Z on the whiteboard |
| Centre of mass marker | SW | ✓ | With the Mass properties tool |

---

## 3. Part features

### 3.1 Sketched features

| Feature | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Extrude: blind, symmetric, reverse | All three | ✓ | |
| Extrude: through all | All three | ✓ | |
| Extrude: up to next / to face / to vertex / offset from surface | All three | ◐ | Up to a flat face (0.4) |
| Extrude: two directions, draft, thin feature | All three | ◐ | Two directions with two depths (0.4); no draft or thin |
| Extrude result: join, cut, new body | All three | ✓ | |
| Extrude result: intersect | All three | ◐ | Intersect exists in the core |
| Revolve: angle, axis from sketch, direction | All three | ✓ | |
| Revolve: two directions, thin | All three | ✗ | |
| Sweep along a path | All three | ✓ | |
| Sweep with guide curves, twist, orientation control | All three | ✗ | |
| Loft between profiles | All three | ✓ | Two profiles in the UI |
| Loft with several sections, guide rails, centreline, end conditions | All three | ◐ | Core takes any number of sections and a ruled option; no guides |
| Boundary | SW Boundary / — / — | ✗ | |
| Rib | All three | ✗ | |
| Web | Fusion | ✗ | |
| Emboss / wrap | Wrap / Emboss / Emboss | ✗ | |
| Coil / helix / spring | Helix + sweep / Coil / Coil | ✗ | |
| Pipe | Fusion Pipe | ✗ | |
| Plastic features: boss, snap fit, rest, lip | Fusion; SW mold/plastic tools | ✗ | |

### 3.2 Applied (placed) features

| Feature | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Fillet: constant radius | All three | ✓ | Finish → Fillet: pick edges in the room (0.4) |
| Fillet: variable, face, full round, setback | All three | ✗ | |
| Chamfer: distance, distance-distance, angle | All three | ◐ | Equal distance on picked edges (0.4); no two-distance or angle |
| Hole wizard: simple, counterbore, countersink, tapped | Hole Wizard / Hole / Hole | ✓ | Finish → Hole (0.4); metric coarse and Unified tap sizes |
| Threads (cosmetic and modelled) | All three | ✗ | |
| Shell | All three | ✓ | Finish → Shell, faces left open picked in the room (0.4) |
| Draft | All three; Fusion fixed-plane mode (Oct 2026) | ◐ | Neutral-plane draft of picked faces (0.5); no parting line |
| Dome, flex, deform, scale | SW; Fusion scale; Inventor | ✗ | |
| Split body / split face | All three | ◐ | Split a body with a plane or flat face (0.5); no split face |
| Move / copy body | All three | ◐ | Move and duplicate features; no rotation |
| Combine (booleans between bodies) | Combine / Combine / Combine | ✓ | Bodies → Combine: join, subtract, intersect; keep or use up the tools (0.5) |
| Delete / keep bodies | All three; SW 2026 "bodies by size" | ✗ | |
| Thicken / offset surface to solid | All three | ✗ | Needs surfaces (§5) |

### 3.3 Patterns and mirror

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Linear pattern | All three | ✓ | Two directions, along axes, edges or reference axes (0.5) |
| Circular pattern | All three | ✓ | Around a round face, edge, reference axis or X/Y/Z (0.5) |
| Pattern along a curve, sketch-driven, table-driven, fill | All three | ✗ | |
| Variable pattern | SW | ✗ | |
| Mirror features / bodies | All three; Inventor associative mirror | ✓ | Picked features, or the whole part joined to its image (0.5) |

### 3.4 Direct, primitive and freeform modelling

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Primitives: box, cylinder, sphere | Fusion Box/Cylinder/Sphere; Inventor primitives | ✓ | Placed from the Primitives group |
| Cone, torus | Fusion; Inventor | ◐ | Cone in the core |
| Push/pull a face | Move Face / Press Pull / Direct edit | ✓ | Edits the driving dimension; faces with none get stock added or removed as a Push/Pull feature (flat or curved), still in the history |
| Move, delete, replace, offset face (history-free) | Direct edit in all three | ✗ | |
| Freeform / T-spline / sub-D | — / Form workspace / Freeform | ✗ | |
| Mesh import, repair, convert to solid | SW mesh tools / Mesh workspace / Mesh enabler | ✗ | |
| Shape generator / generative | — / Generative Design / Shape Generator | ✗ | |

---

## 4. Parameters, history and variants

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Feature tree with history | FeatureManager / Timeline / Browser | ✓ | Model panel; edit sketch, edit feature |
| Rollback, reorder, insert mid-history | All three | ✓ | Rollback bar in the model panel; new features go in at the bar; moves that break a feature are refused (0.6) |
| Suppress / unsuppress | All three | ✓ | Model panel (0.6) |
| Edit a feature's definition | All three | ✓ | Feature panel with live preview |
| Global variables and equations | Equations / Parameters / Parameters | ✓ | With units |
| Text parameters | Fusion (Oct 2026), iLogic | ✗ | |
| Configurations / design tables | Configurations, Design Tables / Configurations / Model States, iParts | ✗ | |
| Failure diagnosis | FeatureXpert / warnings / Design Doctor | ◐ | Failed features marked ⚠ with the reason; Re-pick picks their edges or faces again in the room (0.6); edits that would break the model are refused |
| Undo / redo | All three | ✓ | Model and sketch level |
| Cancel a long computation | SW 2026: Esc during fillets and patterns | ✗ | |

---

## 5. Surfacing

| Capability | Professional | FPS-CAD |
| --- | --- | --- |
| Extruded, revolved, swept, lofted surfaces | All three | ✗ |
| Boundary / filled / planar / ruled / offset surfaces | All three | ✗ |
| Knit / stitch, trim, untrim, extend | All three | ✗ |
| Thicken surfaces to a solid | All three | ✗ |
| Patch, delete face, replace face | All three | ✗ |

Surfaces are a large addition. Open CASCADE supports all of the above, so this is engine work and
UI work rather than a kernel limitation.

---

## 6. Specialised part environments

| Environment | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Sheet metal: base/edge/contour flange, hem, jog, bend, fold/unfold, flat pattern, corner relief, forming tools, rules | All three (SW 2026 adds base flange "From" options; Fusion shared rules via Hub Library) | ✗ | A strong fit for a builder game |
| Weldments / structure systems / frames | Weldments, Structure System / — / Frame Generator | ✗ | |
| Mold tools: parting line, core/cavity, shut-off surfaces | SW, Inventor Mold | ✗ | |
| Plastic part design aids | Fusion plastic rules and features | ✗ | |
| Design accelerators (bolted connections, shafts, gears, springs, bearings) | Toolbox / — / Design Accelerators and calculators | ✗ | |

---

## 7. Assemblies

### 7.1 Structure

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Insert components from files | All three | ◐ | Assembly files reference parts; no in-game insert yet (sandbox only) |
| Multiple instances | All three | ✓ | |
| Virtual / in-place components | Virtual Components / components in one design / Virtual | ✓ | Virtual parts supported by the core |
| Sub-assemblies (rigid / flexible) | All three | ◐ | Nested components in the core; no flexible solving |
| Edit in place / top-down design | All three; Fusion concurrent edit in place (Oct 2026) | ✗ | |
| Mirror components | All three; Inventor 2027 assembly mirror | ✗ | |
| Pattern components | All three | ✗ | |
| Standard parts library | Toolbox / McMaster/insert / Content Center | ✗ | |
| Bill of materials | All three | ✓ | Parts, quantity, material, mass each (0.8) |

### 7.2 Mates and joints

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Standard mates: coincident, parallel, perpendicular, tangent, concentric, distance, angle, lock | Mates / Joints / Constraints | ◐ | Coincident (facing / aligned), concentric, distance, angle, lock solved (0.8); no tangent, parallel or perpendicular yet |
| Joint types: rigid, revolute, slider, cylindrical, pin-slot, planar, ball | Fusion joints; SW and Inventor equivalents | ✗ | |
| Advanced: symmetric, width, path, limit, coupler | All three | ✗ | |
| Mechanical: gear, rack and pinion, cam, screw, hinge, slot, universal joint | All three | ✗ | |
| Drag to move through degrees of freedom | All three | ✓ | Move solves the mates at each step (0.8) |

### 7.3 Assembly tools

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Interference / clearance detection | All three | ◐ | Interference between components and bodies (0.7, 0.8); no clearance |
| Exploded views and animations | All three; Inventor presentations | ◐ | Walkable radial exploded view (0.8); no steps or animation |
| Motion study / animation | Motion Study / Animation, Motion Link / Dynamic Simulation | ✗ | |
| Collision detection while dragging | All three | ✗ | |
| Large-assembly modes and simplification | Large Design Review, SpeedPak / — / Simplify, Level of Detail | ✗ | |
| Assembly features (holes, cuts) | All three | ✗ | |

---

## 8. Drawings and model-based definition

| Capability | Professional | FPS-CAD |
| --- | --- | --- |
| Standard views: projected, auxiliary, section, detail, broken, break-out, crop | All three | ◐ Front, top, right, isometric with hidden lines (0.9); no auxiliary, section or detail views |
| Dimensions from the model, ordinate, chain, baseline | All three | ◐ Overall sizes and hole diameters per view (0.9) |
| Annotations: notes, balloons, centre marks, centrelines, hole callouts | All three | ◐ Centre marks and diameter callouts (0.9) |
| GD&T, datums, surface finish, weld symbols, edge symbols | All three (Inventor edge and weld symbols) | ✗ |
| Tables: BOM, hole, revision, bend, cut list | All three; Fusion revision table auto-fills zone and sheet (Oct 2026) | ✗ |
| Sheet formats and title blocks | All three | ◐ A3 with a border and title block (0.9) |
| Export PDF, DWG, DXF | All three | ◐ PDF and DXF (0.9); no DWG |
| 3D annotations (MBD / PMI) | MBD, DimXpert / — / Model-Based Definition | ✗ |

0.9 added the first `.fpdrw` drawing file, standard views on a drawing board in the room, and
true-size DXF/PDF of a sketch or a face.

---

## 9. Inspection and analysis

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Measure distance | All three | ✓ | Point to point with ΔX ΔY ΔZ; snaps to corners |
| Measure angle, radius, edge length, face area | All three | ✓ | Measure → face or edge / angle (0.7) |
| Mass properties (volume, area, mass, centre of mass) | All three | ✓ | Mass properties tool; material and density from the part |
| Section view | All three | ✓ | Walkable: the cut is real for display, walking and aiming (0.7) |
| Draft analysis | All three (Fusion ±90° range, Oct 2026) | ✗ | |
| Curvature, zebra stripes | All three | ✗ | |
| Thickness, undercut, symmetry checks | SW; Fusion | ✗ | |
| Geometry check / validity | All three | ◐ | Exports are validated by reading them back |
| Compare two parts | SW Compare; Fusion compare | ✓ | Orientation-independent comparison (challenge mode) |

---

## 10. Simulation and generative design

| Capability | Professional | FPS-CAD |
| --- | --- | --- |
| Linear static stress (FEA) | SW Simulation, Fusion, Inventor Stress Analysis and Nastran | ✗ |
| Modal, buckling, thermal, fatigue, nonlinear, drop test | All three (tiered) | ✗ |
| CFD and electronics cooling | SW Flow Simulation, Fusion | ✗ |
| Motion and dynamics | All three | ✗ |
| Topology / shape optimisation, generative design | SW, Fusion Generative Design, Inventor Shape Generator | ✗ |
| Injection-moulding simulation | Fusion, SW Plastics | ✗ |
| Tolerance stack-up | SW TolAnalyst, Inventor Tolerance Analysis | ✗ |
| Sustainability / environmental impact | SW Sustainability | ✗ |

These are large, mostly cloud- or solver-heavy products. FPS-CAD's local-only rule rules out cloud
solving; a small local static solver is possible later but is not core to the game.

---

## 11. Manufacturing

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| CAM: 2.5/3/5-axis milling, turning, mill-turn, probing, post processors | SW CAM, Fusion Manufacture, Inventor CAM | — | Out of scope |
| Additive prep: orientation, supports, slicing | All three | ◐ | STL and 3MF export for a separate slicer |
| Nesting and cutting (laser, waterjet, plasma) | Fusion, Inventor Nesting | ✗ | Would follow sheet metal |
| Costing | SW Costing | ✗ | |
| Inspection planning | SW Inspection | ✗ | |

---

## 12. Routed systems, electrical and electronics

| Capability | Professional | FPS-CAD |
| --- | --- | --- |
| Pipe and tube routing | SW Routing, Inventor Tube and Pipe | ✗ |
| Cable and harness | SW Electrical 3D, Inventor Cable and Harness | ✗ |
| Electrical schematics | SW Electrical | — |
| PCB design and ECAD/MCAD | Fusion Electronics; SW and Inventor PCB interop | — |

---

## 13. Visualisation

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Appearances, materials, decals | All three | ◐ | One material and density per part; no per-face appearance |
| Rendering (ray-traced) | SW Visualize, Fusion Render, Inventor Studio | ✗ | |
| Scenes and lighting | All three | ◐ | Fixed white room and table |
| Named views and saved camera positions | All three | ◐ | Viewpoints stored in `.fpprt`; no UI |
| Walkthrough, VR/AR | SW (eDrawings AR/VR), Fusion, Inventor (VRED/AR) | ✓ | First person at any scale is the core of the game |
| Display styles (shaded, edges, wireframe, hidden lines) | All three | ◐ | Shaded with edges only |
| Section and cut-away displays | All three | ✗ | |

---

## 14. Data management and collaboration

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Native files with full history | `.sldprt/.sldasm/.slddrw` / cloud designs / `.ipt/.iam/.idw` | ✓ | `.fpprt`, `.fpasm` (ZIP + JSON, cached B-rep, format version) |
| Version history | PDM / automatic cloud versions / Vault | ◐ | Undo history in a session; autosave recovery file |
| Branching and merging | Fusion | ✗ | |
| Check-in/out, lifecycle, revisions, where-used | SW PDM, Vault | — | Local-only by design |
| Sharing, commenting, markup | 3DEXPERIENCE, Fusion share links, Inventor Shared Views | — | Local-only by design |
| Copy design with references (Pack and Go) | All three; Fusion cross-hub copy (Oct 2026) | ✗ | Useful for exchanging assemblies by file |

FPS-CAD is local-only by decision; collaboration would come through files (`.fppack` bundle is in the
spec).

---

## 15. Interoperability

| Format | Professional import / export | FPS-CAD export | FPS-CAD import |
| --- | --- | --- | --- |
| STEP (AP203/214/242) | All three, both ways | ✓ AP242 / AP214, validated | ✗ (reader used only to validate) |
| IGES | All three | ✓ validated | ✗ |
| STL | All three | ✓ validated | ✗ |
| 3MF | All three | ✓ validated | ✗ |
| Parasolid (x_t, x_b) | All three | — dropped (no licence-free writer on Android) | ✗ |
| ACIS (SAT), JT | All three | ✗ | ✗ |
| Native files of other CAD (CATIA, NX, Creo, SW, Inventor) | Import in all three (3D Interconnect, AnyCAD, translators) | — | ✗ |
| OBJ, FBX | Fusion, Inventor, SW | ✗ | ✗ |
| DWG, DXF | All three | DXF (0.9) | ✗ |
| PDF, 3D PDF | All three | PDF drawings (0.9) | — |
| Images and screenshots | All three | ✓ screenshot (F12 / Share) | — |

STEP import is the biggest gap here: it lets players bring parts in from other tools, and Open
CASCADE already reads STEP.

---

## 16. Automation and customisation

| Capability | Professional | FPS-CAD | Notes |
| --- | --- | --- | --- |
| Scripting API | SW API (VBA, C#), Fusion API (Python, C++), Inventor API and iLogic (codeblocks in 2027) | ◐ | C++ core library and `fpcad` CLI (create, inspect, set parameters, export) |
| Macros, add-ins | All three | ✗ | |
| Templates and custom properties | All three | ✗ | |
| Design checker / standards | SW Design Checker; Inventor style libraries | ✗ | |
| Remappable controls | Shortcuts, mouse gestures / marking menu | ✓ | Rebinds stored per device |

---

## 17. AI features (2026)

| Capability | Professional | FPS-CAD |
| --- | --- | --- |
| Design assistant / copilot | SOLIDWORKS AI features; Autodesk Assistant (Inventor 2027) | ✗ |
| Rebuild history from imported geometry | Fusion AutoTimeline (tech preview, Oct 2026) | ✗ |
| Sketch auto-constrain, similar-part search | Fusion Find Similar, auto-constrain | ✗ |

---

## 18. What FPS-CAD has that the professional packages do not

- **First-person modelling at any scale**: walk the model, shrink to 0.1 mm or grow to 1 km, with
  movement, collision and snapping that scale with you.
- **Controller-first and touch input**: a full CAD workflow on an Xbox controller or a phone, with
  a two-stick grouped tool wheel.
- **Android as a first-class platform**: the same parametric core and files on a phone, fully offline.
- **Physical interaction with geometry**: stand on parts, bump into them, size limits that stop
  you growing into a part.
- **Challenge mode**: copy a target part, judged by exact, orientation-independent geometry
  comparison, with a progression from a block to a mounting bracket.
- **Validated exports**: every STEP, IGES, STL and 3MF file is read back and checked against the
  model before it is reported as written.

---

## 19. Roadmap to 1.0

Agreed November 2026, after a whole-product review of what is critical to a CAD workflow. Each
release leaves the game usable on its own; earlier ones unblock later ones.

### 0.3 Work on real files (done)
1. Save As with a chosen name; rename a part.
2. An Open browser of every saved part: recent first, delete, duplicate.
3. New part from the pause menu, choosing units and material.
4. STEP import as a solid to build on.

### 0.4 Finish the part (done)
1. Fillet and chamfer on picked edges, as an in-game tool.
2. Extrude end conditions: through all, up to face, two directions.
3. Hole tool: simple, counterbore, countersink, tapped (with a thread note).
4. Shell, picking the faces left open.

### 0.5 Repeat and reuse (done)
1. Linear and circular patterns of features.
2. Mirror features.
3. Draft.
4. Body tools: combine, subtract, split, delete.

### 0.6 Control the history (done)
1. Rollback bar: insert a feature mid-history.
2. Reorder; suppress and unsuppress.
3. Failed features marked, with a "re-pick the face" fix.
4. Stronger face references so upstream edits stop breaking later features.

### 0.7 Check the design (done)
1. Measure angle, radius or diameter, edge length, face area.
2. A section view you can walk through.
3. Driven (reference) sketch dimensions; highlight under-constrained geometry.
4. Interference between bodies.

### 0.8 Assemblies (done)
1. New assembly; insert saved parts in the game.
2. Solved mates (coincident, concentric, distance, angle, lock) with constrained dragging.
3. Interference between components; bill of materials.
4. A walkable exploded view.

### 0.9 Drawings (done)
1. DXF and PDF of a flat view: a sketch, a face, a projection.
2. Standard views with model dimensions: the first `.fpdrw`.

### 1.0 Harden and polish
Stability, performance on large parts, controls and docs; no new feature areas.

### After 1.0
Sheet metal first (it suits building in first person), then surfacing, simulation, CAM, routing,
electronics. Cloud PDM and collaboration stay out (local-only by design).

---

## Sources

- [SOLIDWORKS 2026 top enhancements](https://www.solidworks.com/product/whats-new/solidworks-2026-top-enhancements)
- [SOLIDWORKS 2026 Parts and Features, What's New (GoEngineer)](https://www.goengineer.com/en-us/blog/solidworks-2026-parts-and-features-whats-new)
- [Autodesk Fusion October 2026 product update](https://autodesk.com/products/fusion-360/blog/october-2026-major-product-update-whats-new)
- [Autodesk Fusion help: solids from sketches](https://help.autodesk.com/cloudhelp/ENU/Fusion-Model/files/SLD-CREATE-SOLID-FROM-SKETCH.htm)
- [Key features of Inventor (Autodesk)](https://www.autodesk.com/products/inventor/features)

Capability names for long-standing tools come from the vendors' documentation; the lists above
are organised by function rather than by each product's menu layout, and do not cover every
option of every command.
