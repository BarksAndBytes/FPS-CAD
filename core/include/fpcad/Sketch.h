#pragma once
// 2D sketches on a plane: points, lines, arcs and circles held in place by geometric constraints
// and dimensions, solved numerically. Sketches feed extrude, revolve, sweep and loft features.
//
// Sketch coordinates (u, v) are metres on the sketch plane; world = origin + u·xdir + v·ydir,
// with ydir = normal × xdir. The sketch origin is the implicit fixed point "o" at (0, 0).
//
// JSON form (a "sketch" feature's params):
//   plane        {origin[3], normal[3], xdir[3]}
//   planeName    "Top" | "Front" | "Right" | "Face of …" | a reference plane's name
//   planeRef     optional: the id of a plane or csys feature the sketch sits on (rebuilds move it)
//   points       [{id, x, y, fixed?}]   (a point no entity uses is a stand-alone sketch point)
//   entities     [{id, kind: line|circle|arc|ellipse|spline, pts, r?, construction?}]
//                  line: pts [a, b]   circle: pts [centre], r   arc: pts [centre, start, end] (CCW)
//                  ellipse: pts [centre, end of one axis], r = the other semi-axis
//                  spline: pts [p0, p1, …] fit points the curve passes through, in order; closed
//                          (periodic) when the last point is the first
//                  text: pts [anchor] (start of the baseline), r = cap height, text, contours: the
//                        glyph outlines as closed polygons [[[x, y], …], …] for a cap height of 1
//                        with the anchor at (0, 0)
//                  pattern (copies only): the id of the pattern that made the entity
//   patterns     [{id, kind: linear|circular, entities, count, spacing?, angle?, centre?, total?}]
//                  linear: copies spacing apart along angle; circular: round point centre, spread
//                  over total (default a full turn). The core regenerates the copies (ids
//                  "<pattern>.<k>.<source id>") on every solve and holds them to their sources.
//   links        [{id, probe[3], normal[3], feature?, entities, points}]: geometry converted from
//                  a model face; the face nearest probe (with that normal, preferably made by
//                  feature) is projected again on every rebuild, keeping the entities' ids
//   constraints  [{id, kind, refs, value?}]   value: number (SI) or expression string
//
// Constraint kinds and refs:
//   horizontal [line] or [p, q] · vertical [line] or [p, q] · coincident [p, q]
//   parallel [l1, l2] · perpendicular [l1, l2] · collinear [l1, l2] · equal [e1, e2] (lines, or curves' radii)
//   point_on_line [p, line] · point_on_circle [p, circle|arc] · midpoint [p, line]
//   tangent [line, circle|arc] or [circle|arc, circle|arc] (touching outside or inside, whichever
//           is nearer when the relation is made), or [spline, line|arc] / [line|arc, spline] where
//           they share an end (the spline leaves that end along the other's direction)
//   concentric [e1, e2] (circles, arcs, ellipses)
//   symmetric [p, q, line] (mirror images about the line) · fix [p]
//   distance [line], [p, q], [p, line] (square to the line) or [l1, l2] (between parallel lines);
//            [text] sets a text's cap height
//   hdistance [p, q] · vdistance [p, q] (signed, q − p)
//   radius [circle|arc|ellipse] · diameter [circle|arc|ellipse] (an ellipse's free semi-axis r)
//   angle [l1, l2] (value in angle units)

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
  std::string kind;  // line, circle, arc, ellipse, spline, text
  std::vector<std::string> pts;
  double r = 0;  // circles, ellipses, text (cap height); arcs take their radius from centre to start
  bool construction = false;
  std::string pattern;  // set on pattern copies
  std::string text;     // text only
  std::vector<std::vector<std::array<double, 2>>> contours;  // text only, for a cap height of 1
};

struct SketchPattern {
  std::string id;
  std::string kind = "linear";  // linear, circular
  std::vector<std::string> entities;
  int count = 2;          // instances including the original
  Json spacing;           // linear: distance between instances
  Json angle;             // linear: direction (angle units)
  std::string centre;     // circular: point id
  Json total;             // circular: angle spread (default a full turn)
};

struct SketchLink {
  std::string id;
  std::array<double, 3> probe{0, 0, 0};
  std::array<double, 3> normal{0, 0, 1};
  std::string feature;
  std::vector<std::string> entities;
  std::vector<std::string> points;
};

struct SketchConstraint {
  std::string id;
  std::string kind;
  std::vector<std::string> refs;
  Json value;  // dimensions only; a driven dimension's value is what the solver measured
  bool driven = false;  // a reference dimension: shows the size, does not drive it
};

struct Sketch {
  SketchPlane plane;
  std::string planeName = "Top";
  std::string planeRef;  // a plane (or csys) feature the sketch sits on; it follows that plane
  std::vector<SketchPoint> points;
  std::vector<SketchEntity> entities;
  std::vector<SketchConstraint> constraints;
  std::vector<SketchPattern> patterns;
  std::vector<SketchLink> links;

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
  // Under-defined geometry: points that can still move, and circles, ellipses and text whose
  // size can still change (empty when the sketch is fully defined).
  std::vector<std::string> freePoints;
  std::vector<std::string> freeEntities;
};

// Evaluates a dimension value (number or expression) in SI units.
using SketchValueFn = std::function<double(const Json& value, Quantity q)>;

// Moves the sketch's free points (and circle radii) so every constraint holds, staying as close
// as possible to where they started. Pattern copies are regenerated first. On failure the sketch
// is left at the best attempt.
SolveResult solveSketch(Sketch& s, const SketchValueFn& value);

// Brings every pattern's copies up to date (adding, moving and removing them); copies of patterns
// that no longer exist are removed. solveSketch calls this.
void expandPatterns(Sketch& s, const SketchValueFn& value);

// A unique id in the sketch starting with prefix.
std::string freshSketchId(const Sketch& s, const std::string& prefix);

// The sketch's closed regions (construction geometry excluded, holes cut out) as triangles in
// plane coordinates, three points each, for shading. Empty when nothing is closed.
std::vector<std::array<double, 2>> sketchFill(const Sketch& s);

// Every entity as a polyline in plane coordinates (curves sampled), for display and picking.
struct SketchCurve {
  std::string entityId;
  bool construction = false;
  std::vector<std::array<double, 2>> points;
};
std::vector<SketchCurve> sketchCurves(const Sketch& s);

}  // namespace fpcad
