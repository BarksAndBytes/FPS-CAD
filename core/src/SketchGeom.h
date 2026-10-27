#pragma once
// Turns a solved sketch into Open CASCADE geometry: closed regions (faces with holes) for
// extrude, revolve and sweep profiles; outer loops for lofts; open chains for sweep paths.
// Internal to the core: the public API never exposes Open CASCADE types.

#include <array>
#include <string>
#include <vector>

#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Ax3.hxx>

#include "fpcad/Sketch.h"

namespace fpcad {

using Poly2 = std::vector<std::array<double, 2>>;

struct SketchGeometry {
  std::vector<TopoDS_Face> regions;  // closed areas, holes cut out; normals along the plane normal
  std::vector<Poly2> regionOutlines;  // outer boundary of each region, as a polygon
  std::vector<std::vector<Poly2>> regionHoles;
  std::vector<TopoDS_Wire> loops;    // every outermost closed loop, counter-clockwise (for lofts)
  std::vector<TopoDS_Wire> paths;    // open chains (for sweep paths)
  std::vector<std::string> problems; // why some geometry could not be used
};

gp_Ax3 sketchAxes(const SketchPlane& p);

SketchGeometry buildSketchGeometry(const Sketch& s);

// Polyline of every entity in plane coordinates, for display and picking.
struct SketchPolyline {
  std::string entityId;
  bool construction = false;
  Poly2 points;
};
std::vector<SketchPolyline> sketchPolylines(const Sketch& s);

bool pointInPolygon(const Poly2& poly, double u, double v);

}  // namespace fpcad
