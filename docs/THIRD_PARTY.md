# Third-party components

| Component | Use | Licence | How it ships |
| --- | --- | --- | --- |
| [Open CASCADE Technology](https://github.com/Open-Cascade-SAS/OCCT) 8.0 | B-rep kernel, meshing, STEP/IGES/STL | LGPL 2.1 with the OCCT exception | Separate shared libraries beside the extension |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | GDExtension bindings | MIT | Statically linked into the extension |
| [Godot Engine](https://godotengine.org) | Game engine | MIT | Export templates |
| [nlohmann/json](https://github.com/nlohmann/json) | JSON in native files | MIT | Header-only |
| [miniz](https://github.com/richgel999/miniz) | ZIP containers (.fpprt, .fpasm, .3mf) | MIT | Statically linked |
| [Chakra Petch](https://github.com/google/fonts/tree/main/ofl/chakrapetch) | Display font (titles, tool names) | SIL OFL 1.1 | `godot/fonts/`, licence beside it |
| [IBM Plex Sans](https://github.com/google/fonts/tree/main/ofl/ibmplexsans) | Body font | SIL OFL 1.1 | `godot/fonts/`, licence beside it |
| ["Old Wooden Table"](https://skfb.ly/pEFA6) by [carlcapu9](https://sketchfab.com/carlcapu9) | The table parts stand on | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) | `godot/models/old_wooden_table.glb`; credited on the title screen |

## LGPL obligations for Open CASCADE

- Open CASCADE stays a set of unmodified shared libraries (`TK*.dll` / `libTK*.so`), so users can
  replace them with their own build. `tools/stage_occt.py` lists exactly which ones ship.
- The app's about screen and store listings must include the LGPL 2.1 text, the OCCT exception
  and a link to the Open CASCADE source for the shipped version (tag `V8_0_1`).
- Any change to Open CASCADE itself must be published under the same licence.

Have counsel review this before the first public release, as the spec's risk table notes.

## 3MF

3MF files are written directly by `core/src/Export.cpp` against the 3MF Core Specification
(mesh objects, units, build items with transforms). The spec named lib3mf; the small direct writer
avoids an extra native dependency on Android, and lib3mf can replace it if materials and colour
groups need more than the core spec.

## Old Wooden Table

"Old Wooden Table" (https://skfb.ly/pEFA6) by carlcapu9 is licensed under Creative Commons
Attribution 4.0 (http://creativecommons.org/licenses/by/4.0/). Changes made for FPS-CAD: textures
reduced from 4096 px to 2048 px (colour, JPEG) and 1024 px (occlusion-roughness-metal, JPEG;
normal, PNG) for phones, and the model is scaled in the game to a 4 ft × 2 ft top, 75 cm high.
