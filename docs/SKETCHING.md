# Sketches and sketch-based features

FPS-CAD follows the workflow of desktop CAD tools: **pick a plane → sketch → constrain →
build a feature**. Everything is recorded in the part's history and re-solved on every rebuild.

## Starting a sketch

Pick **Sketch** from the wheel (Model page).

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

The crosshair (screen centre) is the cursor. Points snap to existing points, the sketch origin
and the grid (your snap step, which follows the zoom).

| Controller | Keyboard and mouse | Action |
| --- | --- | --- |
| Hold RB | Hold Q | Sketch tools: Line, Rectangle, Circle, Arc, Dimension, Relation, Delete |
| RT | Left click | Place a point / pick geometry |
| LT, B | Right click | End the line chain, drop the shape being drawn |
| LB | E | Tool option (construction geometry, arc direction, dimension or relation type) |
| Left stick / right stick (fine) | WASD / mouse | Pan across the sketch; the view stays square to it |
| D-pad ↑ / ↓ | Scroll, = / − | Zoom in / out |
| Y | I | Switch between the sketch view and free look (walk or fly around it) |
| D-pad ← / → | Ctrl+Z / Ctrl+Shift+Z | Undo / redo inside the sketch |
| X | Enter | Finish (Menu → Discard sketch leaves without changes) |

- **Line** chains point to point; ending on an existing point closes the chain. Horizontal and
  vertical relations are added automatically.
- **Rectangle** takes two corners and adds horizontal and vertical relations.
- **Circle**: centre, then a point on the edge. **Arc**: centre, start, end (counter-clockwise,
  or clockwise with LB).
- **Dimension**: aim at a line (length), circle (diameter), arc (radius), or two points
  (aligned, horizontal or vertical distance). A number pad opens; plain numbers are in the
  part's units, anything else is an expression (`width / 2`, `25 mm`).
- **Relation**: horizontal, vertical, coincident (or point on line / circle), parallel,
  perpendicular, equal, tangent, fix.
- **Delete**: RT deletes geometry; LT removes only the relations and dimensions holding it.

The HUD shows the sketch's state: blue while it has degrees of freedom left, white when fully
defined. A change that would conflict with existing relations or dimensions is refused.

## Features

Pick a feature tool, aim at a sketch (or just press RT to use the newest unused sketch). RT adds
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
  minimum-norm step, degrees of freedom from the Jacobian's rank, conflicts named).
- `core/src/SketchGeom.*` — closed regions with holes, loops and open paths as Open CASCADE
  geometry.
- `PartModel` — `sketch`, `extrude` (with `sketch`), `revolve`, `sweep`, `loft` features;
  `planeFromHit`, `pickSketch`, `sketchViews`.
- `CadPart` (GDExtension) — `standard_plane`, `plane_from_hit`, `solve_sketch`, `add_sketch`,
  `set_sketch`, `insert_feature` / `update_feature` / `abandon` for live preview.
