# Sketches and sketch-based features

FPS-CAD follows the workflow of desktop CAD tools: **pick a plane → sketch → constrain →
build a feature**. Everything is recorded in the part's history and re-solved on every rebuild.

## Starting a sketch

Pick **Sketch** from the tool wheel.

| Controller | Keyboard and mouse | What happens |
| --- | --- | --- |
| RT | Left click | Sketch on the flat face you aim at (or the Top plane if you aim at the ground) |
| LB | E | Choose Top, Front or Right plane instead of the aimed face |
| LT | Right click | Edit the sketch whose lines you aim at |

Unused sketches stay visible as blue lines (red when they have no closed profile). Sketches used
by a feature hide, as in most CAD tools; edit them from the model panel (Tab / Y → *Edit sketch*).

## Sketch mode

Entering a sketch swings the camera to look straight down the plane's normal, with the sketch's
X axis pointing right and its Y axis up, like a desktop CAD tool's sketch view. Editing an
existing sketch also centres and zooms on its geometry. Finishing or discarding the sketch takes
you back to where you were standing.

The crosshair (screen centre) is the cursor. While drawing, it snaps to existing points and the
sketch origin first, then to the middle of a line, then onto any line, circle or arc, and
otherwise to the grid (your snap step, which follows the zoom). A point placed on a line's middle
or on a curve stays there: the sketch adds a midpoint or point-on relation. The aim label says
what the cursor is on.

| Controller | Keyboard and mouse | Action |
| --- | --- | --- |
| Hold RB | Hold Q | Sketch tools (see the groups below) |
| RT | Left click | Place a point / pick geometry |
| LT | Right click | End a chain or finish a spline; the tool's alternate (see each tool) |
| B | — | Drop what is being drawn or picked |
| LB | E | Drawing tools: construction geometry on/off. Dimension, Relation, Move: their type |
| Left stick / right stick (fine) | WASD / mouse | Pan across the sketch; the view stays square to it |
| D-pad ↑ / ↓ | Scroll, = / − | Zoom in / out |
| Y | I | Switch between the sketch view and free look (walk or fly around it) |
| D-pad ← / → | Ctrl+Z / Ctrl+Shift+Z | Undo / redo inside the sketch |
| X | Enter | Finish (Menu → Discard sketch leaves without changes) |

### Tool groups

| Group | Tools |
| --- | --- |
| **Lines** | Line, Corner rectangle, Centre rectangle, 3-point rectangle, Polygon, Slot, Point |
| **Curves** | Circle, 3-point circle, Centre arc, 3-point arc, Tangent arc, Ellipse, Spline |
| **Modify** | Trim, Extend, Fillet, Chamfer, Offset, Convert edges |
| **Copy** | Move (move, copy, rotate, scale), Mirror, Linear pattern, Circular pattern |
| **Constrain** | Dimension, Relation |
| Construction | Switch geometry between normal and construction |
| Delete | Delete geometry, or only what holds it |

### Drawing

- **Line** chains point to point; ending on an existing point closes the chain. Horizontal and
  vertical relations are added automatically.
- **Corner rectangle**: two opposite corners. **Centre rectangle**: the centre, then a corner;
  construction diagonals hold the centre in the middle. **3-point rectangle**: both ends of one
  side (at any angle), then a point that sets the width. Corners stay square.
- **Polygon**: the centre, then a corner. Its corners sit on a construction circle and its sides
  are equal; LT (before the first click) changes the number of sides: 3, 4, 5, 6, 8, 10 or 12.
- **Slot**: the centre of one round end, the centre of the other, then a point that sets the
  width. Two lines tangent to two equal arcs, with a construction centreline.
- **Point**: a stand-alone point, for reference or dimensions.
- **Circle**: centre, then a point on the edge. **3-point circle**: any three points on it.
- **Centre arc**: centre, start, end; it takes the shorter way round. **3-point arc**: start,
  end, then a point it passes through. **Tangent arc**: start at the end of a line or arc and the
  new arc carries on smoothly from it (tangent); it chains, so tangent arcs can follow each other.
- **Ellipse**: centre, the end of one axis, then a point that sets the other axis.
- **Spline**: a smooth curve through the points you place. LT finishes it; placing the first
  point again closes it into a loop. Splines are fit-point curves (they pass through every point),
  so moving or dimensioning those points reshapes them.
- **Construction geometry** (LB with a drawing tool, or the **Construction** tool on existing
  geometry) is drawn dashed. It is for reference, such as centrelines and revolve axes, and never
  becomes part of a closed profile.

### Modifying

- **Trim**: aim at the piece to cut away. It goes back to the nearest crossings on each side; a
  piece with no crossing is deleted, a circle crossed twice becomes the arc that is left. New ends
  stay on the geometry that crossed them. Lines and arcs cut in the middle become two pieces held
  in line (collinear, or equal arcs on one centre).
- **Extend**: aim at a line near the end to lengthen; it runs on to the next line or curve ahead
  and stays on it.
- **Fillet**: aim at a corner where two lines meet. The corner becomes a tangent arc with a
  radius dimension. LT sets the radius (it is asked for the first time otherwise) and it is reused
  for each corner. If anything referred to the corner, it stays as a reference point where the
  lines would meet (a "virtual sharp"), and the lines' length dimensions measure to it.
- **Chamfer**: the same for a straight bevel, with two equal distance dimensions from the virtual
  sharp.
- **Offset**: aim at a line, arc, circle or a chain of lines and arcs, on the side to offset to.
  The whole chain is copied that distance away; lines are held parallel at the offset distance,
  arcs share their originals' centres. LT sets the distance.
- **Convert edges**: aim at a face of the model. Its edges are copied onto the sketch plane as
  fixed geometry (lines, circles and arcs where they lie square to the sketch, splines
  otherwise), ready to trim, offset or dimension against. They do not follow later changes to the
  model.

### Copying

- **Move**: pick a point, or geometry (its whole chain moves), then where it goes. LB switches to
  **copy** (the original stays), **rotate** (pick the centre, then type the angle) and **scale**
  (pick the centre, then type the factor). Geometry held by dimensions or relations is solved as
  it moves; if they forbid the move it is refused.
- **Mirror**: pick the mirror line (often a construction centreline), then each piece of
  geometry to mirror. Every copied point is held symmetric to its original; points on the line are
  shared.
- **Linear pattern**: pick the geometry, then where its first copy goes, then how many in all.
  **Circular pattern**: pick the geometry, then the centre, then how many round the full turn.
  The copies are independent geometry (they are not held to the original).

### Constraining

- **Dimension**: aim at a circle (diameter), arc (radius), ellipse (its second semi-axis), a
  line, or a point. After a line: aim off the geometry for its length, at a second line for the
  angle between them (or the distance between them if they are parallel), or at a point for its
  distance square to the line. After a point: a second point for the aligned, horizontal or
  vertical distance (LB), or a line. A number pad opens; plain numbers are in the part's units
  (degrees for angles), anything else is an expression (`width / 2`, `25 mm`, `90 deg - taper`).
- **Relation** (LB chooses): horizontal and vertical (a line, or two points level or one above the
  other), coincident (a point onto a point, line, circle or arc), parallel, perpendicular,
  tangent (a line and a circle or arc, or two circles or arcs), equal (lines, or curves' radii),
  collinear, concentric, midpoint (a point, then the line), symmetric (two points, then the line of
  symmetry), fix.
- **Delete**: RT deletes geometry; LT removes only the relations and dimensions holding it.

Sketch lines are drawn solid and every closed profile is shaded, so you can see what will extrude.
The HUD and the lines show the sketch's state: blue while it has degrees of freedom left, black
when fully defined. A change that would conflict with existing relations or dimensions is refused.

## Features

Pick a feature tool from the wheel's **Solids** group, aim at a sketch (or just press RT to use the newest unused sketch). RT adds
material, LT starts the feature as a cut. A property panel opens and the feature appears as a
live preview you can walk around.

| Feature | Fields |
| --- | --- |
| Extrude | Depth, direction (out / into / both sides), end (blind / through all), result |
| Revolve | Angle, axis (sketch X or Y, or any line or centerline in the sketch), direction, result |
| Sweep | Path (another sketch: an open line/arc chain or a closed loop), result |
| Loft | Target sketch (a profile on another plane), result |

Result is *Add material*, *Cut away* or *New body*.

| Controller | Keyboard | Action |
| --- | --- | --- |
| D-pad ↑ / ↓ | ↑ / ↓ | Pick a field |
| D-pad ← / →, RT / LT | ← / → | Change it (lengths by your snap step, angles by 15°) |
| Y | N | Type a value or expression |
| A | Enter | OK |
| B | Esc | Cancel (the part returns to how it was) |

Edit a finished feature from the model panel (*Edit Extrude 1*). Push/Pull also works on
sketch extrudes: pushing the end face changes the depth.

## In the core

- `fpcad/Sketch.h` — sketch data and the constraint solver (Levenberg–Marquardt with a
  minimum-norm step, degrees of freedom from the Jacobian's rank, conflicts named). Entities:
  line, circle, arc, ellipse, spline (fit points, open or closed) and stand-alone points. 22
  relation and dimension kinds, listed at the top of the header. Tangency where a line or arc
  shares an end with an arc is solved as a square radius (or centres in line with the joint), so
  the solver always has a slope to follow and the degrees of freedom count correctly.
- `core/src/SketchGeom.*` — closed regions with holes, loops and open paths as Open CASCADE
  geometry; ellipses and splines become true ellipse and B-spline edges.
- `PartModel` — `sketch`, `extrude` (with `sketch`), `revolve`, `sweep`, `loft` features;
  `planeFromHit`, `pickSketch`, `sketchViews`, `projectFace` (Convert edges).
- `CadPart` (GDExtension) — `standard_plane`, `plane_from_hit`, `solve_sketch`, `sketch_curves`,
  `project_face`, `add_sketch`, `set_sketch`, `insert_feature` / `update_feature` / `abandon` for
  live preview.
- `godot/scripts/sketch_geom.gd` — the 2D geometry behind the editing tools: intersections
  between segments, arcs and polylines, positions along them, circumcentres, tangent-arc centres
  and reflections.
