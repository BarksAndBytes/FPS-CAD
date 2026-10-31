#pragma once
// 2D sketches on a plane: points, lines, arcs and circles held in place by geometric constraints
// and dimensions, solved numerically. Sketches feed extrude, revolve, sweep and loft features.
//
// Sketch coordinates (u, v) are metres on the sketch plane; world = origin + u·xdir + v·ydir,
// with ydir = normal × xdir. The sketch origin is the implicit fixed point "o" at (0, 0).
//
// JSON form (a "sketch" feature's params):
//   plane        {origin[3], normal[3], xdir[3]}
//   planeName    "Top" | "Front" | "Right" | "Face of …"
//   points       [{id, x, y, fixed?}]
//   entities     [{id, kind: line|circle|arc, pts, r?, construction?}]
//                  line: pts [a, b]   circle: pts [centre], r   arc: pts [centre, start, end] (CCW)
//   constraints  [{id, kind, refs, value?}]   value: number (SI) or expression string
//
// Constraint kinds and refs:
//   horizontal [line] · vertical [line] · coincident [p, q] · parallel [l1, l2]
//   perpendicular [l1, l2] · equal [e1, e2] · point_on_line [p, line] · point_on_circle [p, c]
//   midpoint [p, line] · tangent [line, circle|arc] · fix [p]
//   distance [line] or [p, q] · hdistance [p, q] · vdistance [p, q] (signed, q − p)
//   radius [circle|arc] · diameter [circle|arc] · angle [l1, l2] (value in angle units)

#include <array>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "fpcad/Document.h"
#include "fpcad/Expression.h"

namespace fpcad {

using Vec3d = std::array<double, 3>;

struct SketchPlane {
  Vec3d origin{0, 0, 0};
  Vec3d normal{0, 0, 1};
  Vec3d xdir{1, 0, 0};

  Vec3d ydir() const;
  Vec3d toWorld(double u, double v) const;
  // Projects a world point onto the plane, returning (u, v).
  std::array<double, 2> toPlane(const Vec3d& p) const;
  Json toJson() const;
  static SketchPlane fromJson(const Json& j);
};

// "top" (XY, normal +Z), "front" (XZ, normal −Y, facing the default viewpoint), "right" (YZ).
SketchPlane standardPlane(const std::string& name);

struct SketchPoint {
  std::string id;
  double x = 0, y = 0;
  bool fixed = false;
};

struct SketchEntity {
  std::string id;
  std::string kind;  // line, circle, arc
  std::vector<std::string> pts;
  double r = 0;  // circles only; arcs take their radius from centre to start
  bool construction = false;
};

struct SketchConstraint {
  std::string id;
  std::string kind;
  std::vector<std::string> refs;
  Json value;  // dimensions only
};

struct Sketch {
  SketchPlane plane;
  std::string planeName = "Top";
  std::vector<SketchPoint> points;
  std::vector<SketchEntity> entities;
  std::vector<SketchConstraint> constraints;

  static Sketch fromJson(const Json& j);
  Json toJson() const;

  // Point lookup, including the fixed origin "o". Returns nullptr when unknown.
  const SketchPoint* point(const std::string& id) const;
  SketchPoint* point(const std::string& id);
  const SketchEntity* entity(const std::string& id) const;
};

struct SolveResult {
  bool ok = true;            // every constraint satisfied
  int dof = 0;               // remaining degrees of freedom; 0 = fully defined
  double residual = 0;       // root-mean-square constraint error, metres
  std::vector<std::string> conflicts;  // constraint ids still violated when !ok
  std::string message;
};

// Evaluates a dimension value (number or expression) in SI units.
using SketchValueFn = std::function<double(const Json& value, Quantity q)>;

// Moves the sketch's free points (and circle radii) so every constraint holds, staying as close
// as possible to where they started. On failure the sketch is left at the best attempt.
SolveResult solveSketch(Sketch& s, const SketchValueFn& value);

}  // namespace fpcad
