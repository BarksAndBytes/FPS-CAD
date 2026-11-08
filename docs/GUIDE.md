# FPS-CAD 1.0 user guide

FPS-CAD is parametric CAD you play in first person: you walk around the part, grow or shrink
yourself to zoom, and pick tools from a wheel. Everything you build is kept as an editable
history in a file of its own. This guide walks through the whole workflow, from a blank part to
an assembly and a drawing.

Buttons are written controller first, then keyboard and mouse. Press **View** (F1) at any time for
the full controls map, and play **Training** from the title screen to learn the moves.

| Action | Controller | Keyboard and mouse |
| --- | --- | --- |
| Move, look | Left stick, right stick | WASD, mouse |
| Grow, shrink (zoom) | D-pad ↑ / ↓ | Mouse wheel, = / − |
| Tool wheel | Hold RB | Hold Q |
| Tool's primary / secondary action | RT / LT | Left / right click |
| Tool option | LB | E |
| Undo / redo | D-pad ← / → | Ctrl+Z / Ctrl+Shift+Z |
| Model panel (history) | Y | Tab, I |
| Controls map | View | F1 |
| Pause menu (save, files, units) | Menu | Esc |

The aim label under the crosshair says what a tool would act on before you press anything. The
wheel only shows the tools that work in what you have open: part tools in a part, assembly tools in
an assembly.

## 1. Start a part

From the title screen choose **New part**, or from the pause menu **File → New part…** and pick a
unit system (MMGS, CGS, MKS, IPS or FPS). Set the material under **Material** in the pause menu:
mass and appearance follow it.

**Save** keeps the part in your projects folder under its own name; **Save as…** renames it.
**Open…** lists every saved part, assembly and drawing, newest first, with Duplicate and Delete.
**Import STEP…** brings a STEP file in as a solid to build on.

## 2. Sketch

Pick **Sketch** and aim at the ground (the Top plane), a flat face, or a reference plane; LB/E
cycles to the Front or Right plane. The view turns square to the sketch. Draw with the sketch
wheel (lines, rectangles, circles, arcs, slots, splines, text), constrain with relations and
**Dimension**. Geometry turns from blue to dark as it becomes fully defined, entity by entity. A
dimension that would over-define the sketch is kept as a reference dimension, shown in brackets.
Finish with X / Enter. The pause menu while sketching can export the sketch true size as DXF and
PDF.

## 3. Make it solid

The **Solids** group turns a sketch into a solid: **Extrude** (blind, through all, up to the face
you aimed at; one way, the other way, both sides, or two different depths), **Revolve**,
**Sweep** and **Loft**. The feature panel previews live as you change values; the result can add
material, cut it away, or start a new body.

Solids also places boxes, cylinders and spheres directly. In **Modify**, **Push / Pull** grows or
shrinks the face you aim at by snap steps, **Move** carries a feature and **Delete** removes one.

## 4. Finish the part

The **Finish** group works on what you aim at in the room:

- **Fillet / Chamfer**: aim at edges and press the primary action to pick them (they light up),
  then the secondary to round or bevel them.
- **Hole**: aim at a face and press the primary action (snapped to the grid) or the secondary
  (exactly at the crosshair). Simple, counterbore, countersink or tapped (metric or Unified
  threads at their tap-drill size); through all or to a depth.
- **Shell**: pick the faces to leave open, then hollow the part to a wall thickness.
- **Draft**: pick the faces to draft, then aim at the flat face they lean from.

## 5. Repeat and reuse

The **Repeat** group: pick features with the primary action, then press the secondary to make a
**Linear pattern** (one or two directions; aim at a straight edge to repeat along it), a
**Circular pattern** (aim at a round face or an axis), or a **Mirror** (aim at the face or plane
to mirror in; with no features picked, the whole part is mirrored).

**Modify** also combines, subtracts, intersects, splits and deletes whole bodies.

## 6. Control the history

Open the model panel (Y / Tab). Pick a feature in the tree to change its sizes or edit it, and
to **Move up / Move down**, **Suppress**, or **Roll back to here**: the part is built only that
far, and new features go in at the orange rollback bar. Press the bar to roll forward. A feature
that fails is marked ⚠ with the reason; **Re-pick what it uses…** lets you aim at the edge or face
it should use now. Faces remember their role in the feature that made them, so references hold
when you edit earlier features.

## 7. Check the design

The **Measure** group: **Measure** (point to point; LB/E for *face or edge*: length, radius,
area; or *angle* between two picks), **Bounding box**, **Mass properties**, **Section view** (cut
the part through the crosshair or a standard plane and walk into it) and **Interference** (where
bodies overlap).

The **Boards** group sets up whiteboards in the room: part properties, your own notes, a video,
or a **Drawing board** showing the part's drawing.

## 8. Assemblies

**File → New assembly** starts an empty assembly. **Insert part** (group **Assembly**) places a
saved part where you aim; the first one is grounded. **Mate** joins a face on one component to a
face on another: coincident (facing or aligned), concentric, distance, angle or lock. Components
move only as their mates allow, including when you drag them with **Move**. **Exploded view**
spreads the parts out so you can walk between them; **Bill of materials** lists the parts.
**Interference** reports components that overlap. The model panel lists components (ground, float,
remove) and mates (delete).

## 9. Drawings

Set up a **Drawing board** (Boards group) to see the front, top and right views (third-angle
projection) with hidden lines dashed, an isometric, overall dimensions and hole diameters, on an
A3 sheet with a title block. It follows the part as you change it. The secondary action on the
board exports it as PDF and DXF; on a flat face of the part it exports that face true size.
**File → Save drawing (.fpdrw)** keeps a drawing file that opens its part with the board in
front of you.

## 10. Export

**File** exports STEP, IGES, STL and 3MF, and the drawing as PDF and DXF. Exports go to the
`exports` folder in the game's user data (shown in the message after each export).

## Files

| File | What it holds |
| --- | --- |
| `.fpprt` | A part: its history, variables, units and material, cached geometry, boards, imports |
| `.fpasm` | An assembly: components (paths to parts), placements, mates |
| `.fpdrw` | A drawing: the part it shows and its options |

All three are zip archives with a `manifest.json`; see [SPEC.md](SPEC.md) for the layout.
