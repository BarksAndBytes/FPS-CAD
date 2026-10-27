#include "fpcad/Model.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <stdexcept>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <ElSLib.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <NCollection_DataMap.hxx>
#include <NCollection_IndexedMap.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Lin.hxx>
#include <gp_Pln.hxx>

#include "fpcad/Expression.h"
#include "fpcad/Sketch.h"
#include "SketchGeom.h"

#include <BRepBndLib.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRep_Builder.hxx>
#include <Bnd_Box.hxx>
#include <TopoDS_Compound.hxx>
#include <gp_Ax1.hxx>

namespace fpcad {
namespace {

using FaceTags = NCollection_DataMap<TopoDS_Shape, int, TopTools_ShapeMapHasher>;
using ShapeIndex = NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>;

constexpr double kPi = 3.14159265358979323846;

struct FeatureError : std::runtime_error {
  using std::runtime_error::runtime_error;
};

gp_Vec toVec(const Json& j, const char* what) {
  if (!j.is_array() || j.size() != 3) throw FeatureError(std::string(what) + " must be [x, y, z]");
  return gp_Vec(j[0].get<double>(), j[1].get<double>(), j[2].get<double>());
}

gp_Dir outwardNormal(const TopoDS_Face& face, double u, double v) {
  BRepAdaptor_Surface s(face);
  gp_Pnt p;
  gp_Vec du, dv;
  s.D1(u, v, p, du, dv);
  gp_Vec n = du.Crossed(dv);
  if (n.Magnitude() < 1e-14) {
    // Degenerate point (a cone apex, a sphere pole): nudge into the face.
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    s.D1(0.5 * (u0 + u1), 0.5 * (v0 + v1), p, du, dv);
    n = du.Crossed(dv);
    if (n.Magnitude() < 1e-14) return gp_Dir(0, 0, 1);
  }
  gp_Dir d(n);
  if (face.Orientation() == TopAbs_REVERSED) d.Reverse();
  return d;
}

std::string surfaceKind(const TopoDS_Face& face) {
  switch (BRepAdaptor_Surface(face).GetType()) {
    case GeomAbs_Plane: return "plane";
    case GeomAbs_Cylinder: return "cylinder";
    case GeomAbs_Cone: return "cone";
    case GeomAbs_Sphere: return "sphere";
    case GeomAbs_Torus: return "torus";
    default: return "other";
  }
}

void tagAll(const TopoDS_Shape& s, int owner, FaceTags& tags) {
  for (TopExp_Explorer e(s, TopAbs_FACE); e.More(); e.Next())
    if (!tags.IsBound(e.Current())) tags.Bind(e.Current(), owner);
}

// Carries face ownership through a modelling operation using its history.
FaceTags remap(BRepBuilderAPI_MakeShape& op, const FaceTags& old, const TopoDS_Shape& result, int owner) {
  FaceTags moved;
  for (FaceTags::Iterator it(old); it.More(); it.Next()) {
    const TopoDS_Shape& f = it.Key();
    if (op.IsDeleted(f)) continue;
    const auto& mods = op.Modified(f);
    if (mods.IsEmpty()) {
      moved.Bind(f, it.Value());
    } else {
      for (const auto& m : mods) if (!moved.IsBound(m)) moved.Bind(m, it.Value());
    }
  }
  FaceTags out;
  for (TopExp_Explorer e(result, TopAbs_FACE); e.More(); e.Next()) {
    const TopoDS_Shape& f = e.Current();
    if (out.IsBound(f)) continue;
    out.Bind(f, moved.IsBound(f) ? moved.Find(f) : owner);
  }
  return out;
}

bool hasSolid(const TopoDS_Shape& s) {
  TopExp_Explorer e(s, TopAbs_SOLID);
  return e.More();
}

}  // namespace

struct SketchState {
  Sketch sketch;
  SolveResult solve;
  SketchGeometry geom;
};

struct PartModel::Impl {
  PartDocument doc;
  std::map<std::string, SketchState> sketches;  // by feature id, filled during rebuild
  RebuildReport report;
  std::vector<TopoDS_Shape> bodies;
  std::vector<FaceTags> tags;          // per body: face -> owner index
  std::vector<std::string> owners;     // owner index -> feature id
  std::vector<ShapeIndex> faceIndex;   // per body: stable face numbering for meshes and picks
  std::map<std::string, double> vars;
  mutable std::vector<std::unique_ptr<IntCurvesFace_ShapeIntersector>> pickers;

  double unit() const { return unitScale(doc.units); }

  double value(const Json& j, Quantity q) const {
    if (j.is_number()) return j.get<double>();
    if (j.is_string()) return evaluate(j.get<std::string>(), vars, q, unit());
    throw FeatureError("parameter must be a number or an expression");
  }

  double get(const Json& params, const std::string& key, Quantity q = Quantity::Length) const {
    if (!params.contains(key)) throw FeatureError("missing parameter '" + key + "'");
    return value(params.at(key), q);
  }

  double positive(const Json& params, const std::string& key) const {
    double v = get(params, key);
    if (!(v > 1e-9)) throw FeatureError("'" + key + "' must be greater than zero");
    return v;
  }

  int ownerIndex(const std::string& id) {
    for (size_t i = 0; i < owners.size(); ++i) if (owners[i] == id) return static_cast<int>(i);
    owners.push_back(id);
    return static_cast<int>(owners.size() - 1);
  }

  void evaluateVariables(RebuildReport& r) {
    vars.clear();
    for (auto& v : doc.variables) {
      try {
        vars[v.name] = evaluate(v.expr, vars, Quantity::Length, unit());
      } catch (const std::exception& e) {
        r.ok = false;
        r.features.push_back({"var:" + v.name, false, e.what()});
      }
    }
  }

  gp_Ax3 sketchPlane(const Json& p) const {
    gp_Vec o = toVec(p.at("origin"), "plane origin");
    gp_Vec n = toVec(p.at("normal"), "plane normal");
    gp_Vec x = toVec(p.at("xdir"), "plane xdir");
    if (n.Magnitude() < 1e-12 || x.Magnitude() < 1e-12) throw FeatureError("plane directions must be non-zero");
    if (n.IsParallel(x, 1e-6)) throw FeatureError("plane xdir must not be parallel to its normal");
    return gp_Ax3(gp_Pnt(o.XYZ()), gp_Dir(n), gp_Dir(x));
  }

  TopoDS_Face profileFace(const gp_Ax3& ax, const Json& prof) const {
    gp_Pln pln(ax);
    std::string kind = prof.value("kind", std::string());
    auto P = [&](double u, double v) { return ElSLib::Value(u, v, pln); };
    TopoDS_Wire wire;
    if (kind == "rect") {
      double cx = get(prof, "cx"), cy = get(prof, "cy"), w = positive(prof, "w"), h = positive(prof, "h");
      BRepBuilderAPI_MakePolygon poly(P(cx - w / 2, cy - h / 2), P(cx + w / 2, cy - h / 2),
                                      P(cx + w / 2, cy + h / 2), P(cx - w / 2, cy + h / 2), true);
      wire = poly.Wire();
    } else if (kind == "circle") {
      double cx = get(prof, "cx"), cy = get(prof, "cy"), r = positive(prof, "r");
      gp_Ax2 cax(P(cx, cy), ax.Direction(), ax.XDirection());
      wire = BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(gp_Circ(cax, r))).Wire();
    } else if (kind == "polyline") {
      const Json& pts = prof.at("points");
      if (!pts.is_array() || pts.size() < 3) throw FeatureError("a polyline profile needs at least 3 points");
      BRepBuilderAPI_MakePolygon poly;
      for (auto& q : pts) poly.Add(P(value(q.at(0), Quantity::Length), value(q.at(1), Quantity::Length)));
      poly.Close();
      if (!poly.IsDone()) throw FeatureError("polyline profile is invalid");
      wire = poly.Wire();
    } else {
      throw FeatureError("unknown profile kind '" + kind + "'");
    }
    BRepBuilderAPI_MakeFace mf(wire, true);
    if (!mf.IsDone()) throw FeatureError("profile does not form a flat closed face");
    return mf.Face();
  }

  SketchValueFn valueFn() const {
    return [this](const Json& v, Quantity q) { return value(v, q); };
  }

  // Solves a sketch feature, writes the solved positions back into the history and builds its
  // geometry. Throws when the sketch's dimensions conflict.
  void processSketch(Feature& f) {
    SketchState st;
    st.sketch = Sketch::fromJson(f.params);
    st.solve = solveSketch(st.sketch, valueFn());
    if (st.solve.ok) {
      Json solved = st.sketch.toJson();
      for (auto& [k, v] : f.params.items())
        if (!solved.contains(k)) solved[k] = v;  // keep any extra keys
      f.params = solved;
    }
    st.geom = buildSketchGeometry(st.sketch);
    sketches[f.id] = std::move(st);
    const SketchState& done = sketches[f.id];
    if (!done.solve.ok) throw FeatureError("sketch: " + done.solve.message);
  }

  const SketchState& sketchRef(const Json& params, const char* key) const {
    if (!params.contains(key) || !params.at(key).is_string()) throw FeatureError(std::string("choose a sketch (") + key + ")");
    std::string id = params.at(key).get<std::string>();
    auto it = sketches.find(id);
    if (it == sketches.end()) {
      const Feature* f = doc.find(id);
      throw FeatureError(f ? f->name + " must come before this feature" : "the sketch no longer exists");
    }
    return it->second;
  }

  static TopoDS_Shape compoundOf(const std::vector<TopoDS_Face>& faces) {
    if (faces.size() == 1) return faces[0];
    TopoDS_Compound c;
    BRep_Builder bb;
    bb.MakeCompound(c);
    for (auto& f : faces) bb.Add(c, f);
    return c;
  }

  const std::vector<TopoDS_Face>& profileOf(const SketchState& st) const {
    if (st.geom.regions.empty()) {
      std::string why = st.geom.problems.empty() ? "" : ": " + st.geom.problems.front();
      throw FeatureError("the sketch has no closed profile" + why);
    }
    return st.geom.regions;
  }

  // Length that reaches through everything built so far, for "through all".
  double throughAllLength(const SketchState& st) const {
    Bnd_Box box;
    for (auto& b : bodies) BRepBndLib::Add(b, box);
    for (auto& f : st.geom.regions) BRepBndLib::Add(f, box);
    if (box.IsVoid()) return 1.0;
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    return 2.0 * std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0)) + 1.0;
  }

  // Direction an extrude grows in: the sketch normal, or its reverse.
  static gp_Dir extrudeDir(const SketchState& st, const Json& p) {
    gp_Dir n = sketchAxes(st.sketch.plane).Direction();
    return p.value("direction", std::string("normal")) == "reverse" ? n.Reversed() : n;
  }

  TopoDS_Shape sketchExtrude(const Feature& f) const {
    const Json& p = f.params;
    const SketchState& st = sketchRef(p, "sketch");
    TopoDS_Shape prof = compoundOf(profileOf(st));
    std::string dirMode = p.value("direction", std::string("normal"));
    bool symmetric = dirMode == "symmetric";
    gp_Vec dir(extrudeDir(st, p));
    double depth = p.value("end", std::string("blind")) == "through_all" ? throughAllLength(st) : positive(p, "depth");
    double offset = p.contains("offset") ? get(p, "offset") : 0.0;
    double shift = offset - (symmetric ? depth / 2 : 0.0);
    if (std::abs(shift) > 1e-15) {
      gp_Trsf t;
      t.SetTranslation(dir * shift);
      prof = BRepBuilderAPI_Transform(prof, t, true).Shape();
    }
    return BRepPrimAPI_MakePrism(prof, dir * depth).Shape();
  }

  TopoDS_Shape sketchRevolve(const Feature& f) const {
    const Json& p = f.params;
    const SketchState& st = sketchRef(p, "sketch");
    TopoDS_Shape prof = compoundOf(profileOf(st));
    const SketchPlane& pl = st.sketch.plane;
    std::string axis = p.value("axis", std::string("y"));
    Vec3d o, d;
    if (axis == "x" || axis == "y") {
      o = pl.origin;
      d = axis == "x" ? pl.xdir : pl.ydir();
    } else {
      const SketchEntity* e = st.sketch.entity(axis);
      if (!e || e->kind != "line") throw FeatureError("the revolve axis must be a line in the sketch");
      const SketchPoint* a = st.sketch.point(e->pts[0]);
      const SketchPoint* b = st.sketch.point(e->pts[1]);
      o = pl.toWorld(a->x, a->y);
      Vec3d w = pl.toWorld(b->x, b->y);
      d = {w[0] - o[0], w[1] - o[1], w[2] - o[2]};
    }
    gp_Ax1 ax(gp_Pnt(o[0], o[1], o[2]), gp_Dir(d[0], d[1], d[2]));
    double angle = p.contains("angle") ? get(p, "angle", Quantity::Angle) : 2 * kPi;
    if (!(angle > 1e-9)) throw FeatureError("the revolve angle must be greater than zero");
    if (p.value("direction", std::string("normal")) == "reverse") ax.Reverse();
    if (angle >= 2 * kPi - 1e-9) {
      BRepPrimAPI_MakeRevol rev(prof, ax);
      if (!rev.IsDone()) throw FeatureError("revolve failed: the profile may cross the axis");
      return rev.Shape();
    }
    BRepPrimAPI_MakeRevol rev(prof, ax, angle);
    if (!rev.IsDone()) throw FeatureError("revolve failed: the profile may cross the axis");
    return rev.Shape();
  }

  TopoDS_Shape sketchSweep(const Feature& f) const {
    const Json& p = f.params;
    const SketchState& prof = sketchRef(p, "sketch");
    const SketchState& path = sketchRef(p, "path");
    TopoDS_Wire spine;
    if (!path.geom.paths.empty()) spine = path.geom.paths.front();
    else if (!path.geom.loops.empty()) spine = path.geom.loops.front();
    else throw FeatureError("the path sketch has no connected chain of lines or arcs");
    BRepOffsetAPI_MakePipe pipe(spine, compoundOf(profileOf(prof)));
    pipe.Build();
    if (!pipe.IsDone()) throw FeatureError("sweep failed: the profile may be too large for the path's bends");
    return pipe.Shape();
  }

  TopoDS_Shape sketchLoft(const Feature& f) const {
    const Json& p = f.params;
    const Json& ids = p.value("sketches", Json::array());
    if (!ids.is_array() || ids.size() < 2) throw FeatureError("a loft needs at least two sketches");
    BRepOffsetAPI_ThruSections loft(true, p.value("ruled", false));
    for (auto& id : ids) {
      Json ref = {{"s", id}};
      const SketchState& st = sketchRef(ref, "s");
      if (st.geom.loops.empty()) throw FeatureError("every loft section needs one closed loop");
      loft.AddWire(st.geom.loops.front());
    }
    loft.Build();
    if (!loft.IsDone()) throw FeatureError("loft failed: the sections may be twisted or mismatched");
    return loft.Shape();
  }

  TopoDS_Shape toolShape(const Feature& f) const {
    if (f.type == "extrude" && f.params.contains("sketch")) return sketchExtrude(f);
    if (f.type == "revolve") return sketchRevolve(f);
    if (f.type == "sweep") return sketchSweep(f);
    if (f.type == "loft") return sketchLoft(f);
    const Json& p = f.params;
    if (f.type == "box") {
      double w = positive(p, "w"), d = positive(p, "d"), h = positive(p, "h");
      gp_Pnt c(get(p, "x") - w / 2, get(p, "y") - d / 2, get(p, "z"));
      return BRepPrimAPI_MakeBox(c, w, d, h).Shape();
    }
    if (f.type == "cylinder") {
      gp_Ax2 ax(gp_Pnt(get(p, "x"), get(p, "y"), get(p, "z")), gp::DZ());
      return BRepPrimAPI_MakeCylinder(ax, positive(p, "r"), positive(p, "h")).Shape();
    }
    if (f.type == "sphere") {
      return BRepPrimAPI_MakeSphere(gp_Pnt(get(p, "x"), get(p, "y"), get(p, "z")), positive(p, "r")).Shape();
    }
    if (f.type == "cone") {
      double r1 = get(p, "r1"), r2 = get(p, "r2"), h = positive(p, "h");
      if (r1 < 0 || r2 < 0 || std::abs(r1 - r2) < 1e-9) throw FeatureError("cone radii must differ and be zero or more");
      gp_Ax2 ax(gp_Pnt(get(p, "x"), get(p, "y"), get(p, "z")), gp::DZ());
      return BRepPrimAPI_MakeCone(ax, r1, r2, h).Shape();
    }
    if (f.type == "extrude") {
      gp_Ax3 ax = sketchPlane(p.at("plane"));
      double depth = positive(p, "depth");
      TopoDS_Face face = profileFace(ax, p.at("profile"));
      gp_Vec dir(ax.Direction());
      if (p.value("symmetric", false)) {
        gp_Trsf t;
        t.SetTranslation(dir * (-depth / 2));
        face = TopoDS::Face(BRepBuilderAPI_Transform(face, t, true).Shape());
      }
      return BRepPrimAPI_MakePrism(face, dir * depth).Shape();
    }
    throw FeatureError("unknown feature type '" + f.type + "'");
  }

  // Edges of the faces that the target feature owns in this body, filtered by a selector.
  std::vector<TopoDS_Edge> targetEdges(int b, const std::string& target, const std::string& selector) const {
    int owner = -1;
    for (size_t i = 0; i < owners.size(); ++i) if (owners[i] == target) owner = static_cast<int>(i);
    std::vector<TopoDS_Face> faces;
    for (FaceTags::Iterator it(tags[b]); it.More(); it.Next())
      if (it.Value() == owner) faces.push_back(TopoDS::Face(it.Key()));
    if (faces.empty()) return {};
    double zmin = 1e300, zmax = -1e300;
    for (auto& f : faces)
      for (TopExp_Explorer e(f, TopAbs_VERTEX); e.More(); e.Next()) {
        double z = BRep_Tool::Pnt(TopoDS::Vertex(e.Current())).Z();
        zmin = std::min(zmin, z);
        zmax = std::max(zmax, z);
      }
    const double tol = 1e-7;
    ShapeIndex edges;
    for (auto& f : faces) TopExp::MapShapes(f, TopAbs_EDGE, edges);
    std::vector<TopoDS_Edge> out;
    for (int i = 1; i <= edges.Extent(); ++i) {
      TopoDS_Edge e = TopoDS::Edge(edges(i));
      if (BRep_Tool::Degenerated(e)) continue;
      TopoDS_Vertex v1, v2;
      TopExp::Vertices(e, v1, v2);
      double z1 = BRep_Tool::Pnt(v1).Z(), z2 = BRep_Tool::Pnt(v2).Z();
      bool keep = true;
      if (selector == "vertical") {
        BRepAdaptor_Curve c(e);
        keep = c.GetType() == GeomAbs_Line && std::abs(c.Line().Direction().Z()) > 0.9999;
      } else if (selector == "top") {
        keep = std::abs(z1 - zmax) < tol && std::abs(z2 - zmax) < tol;
      } else if (selector == "bottom") {
        keep = std::abs(z1 - zmin) < tol && std::abs(z2 - zmin) < tol;
      } else if (selector != "all") {
        throw FeatureError("unknown edge selector '" + selector + "'");
      }
      if (keep) out.push_back(e);
    }
    return out;
  }

  void applyEdgeFeature(const Feature& f, int self) {
    std::string target = f.params.value("target", std::string());
    if (target.empty()) throw FeatureError("choose a target feature");
    const Feature* tf = doc.find(target);
    if (!tf) throw FeatureError("target feature no longer exists");
    std::string sel = f.params.value("edges", std::string("all"));
    bool fillet = f.type == "fillet";
    double size = positive(f.params, fillet ? "r" : "d");
    bool any = false;
    for (size_t b = 0; b < bodies.size(); ++b) {
      auto edges = targetEdges(static_cast<int>(b), target, sel);
      if (edges.empty()) continue;
      any = true;
      TopoDS_Shape result;
      if (fillet) {
        BRepFilletAPI_MakeFillet mk(bodies[b]);
        for (auto& e : edges) mk.Add(size, e);
        mk.Build();
        if (!mk.IsDone()) throw FeatureError("fillet failed: the radius may be too large for these edges");
        result = mk.Shape();
        tags[b] = remap(mk, tags[b], result, self);
      } else {
        BRepFilletAPI_MakeChamfer mk(bodies[b]);
        for (auto& e : edges) mk.Add(size, e);
        mk.Build();
        if (!mk.IsDone()) throw FeatureError("chamfer failed: the distance may be too large for these edges");
        result = mk.Shape();
        tags[b] = remap(mk, tags[b], result, self);
      }
      bodies[b] = result;
    }
    if (!any) throw FeatureError("no edges of '" + tf->name + "' match '" + sel + "'");
  }

  void applyBoolean(const Feature& f, const TopoDS_Shape& tool, int self) {
    FaceTags toolTags;
    tagAll(tool, self, toolTags);
    auto merged = [&](const FaceTags& a) {
      FaceTags m = a;
      for (FaceTags::Iterator it(toolTags); it.More(); it.Next()) m.Bind(it.Key(), it.Value());
      return m;
    };
    if (f.op == BodyOp::NewBody || (bodies.empty() && f.op == BodyOp::Add)) {
      bodies.push_back(tool);
      tags.push_back(toolTags);
      return;
    }
    if (bodies.empty()) throw FeatureError("there is no body to " + toString(f.op) + " yet");
    if (f.op == BodyOp::Cut) {
      for (size_t b = 0; b < bodies.size();) {
        BRepAlgoAPI_Cut op(bodies[b], tool);
        if (!op.IsDone() || op.HasErrors()) throw FeatureError("cut failed");
        TopoDS_Shape r = op.Shape();
        if (!hasSolid(r)) {
          bodies.erase(bodies.begin() + static_cast<long>(b));
          tags.erase(tags.begin() + static_cast<long>(b));
          continue;
        }
        tags[b] = remap(op, merged(tags[b]), r, self);
        bodies[b] = r;
        ++b;
      }
      return;
    }
    int b = std::clamp(f.body, 0, static_cast<int>(bodies.size()) - 1);
    if (f.op == BodyOp::Add) {
      BRepAlgoAPI_Fuse op(bodies[b], tool);
      if (!op.IsDone() || op.HasErrors()) throw FeatureError("adding to the body failed");
      TopoDS_Shape r = op.Shape();
      tags[b] = remap(op, merged(tags[b]), r, self);
      bodies[b] = r;
    } else {
      BRepAlgoAPI_Common op(bodies[b], tool);
      if (!op.IsDone() || op.HasErrors()) throw FeatureError("intersect failed");
      TopoDS_Shape r = op.Shape();
      if (!hasSolid(r)) throw FeatureError("intersect leaves nothing: the shapes do not overlap");
      tags[b] = remap(op, merged(tags[b]), r, self);
      bodies[b] = r;
    }
  }

  RebuildReport rebuild() {
    auto t0 = std::chrono::steady_clock::now();
    RebuildReport r;
    bodies.clear();
    tags.clear();
    owners.clear();
    pickers.clear();
    sketches.clear();
    evaluateVariables(r);
    for (auto& f : doc.features) {
      FeatureStatus st{f.id, true, {}};
      if (f.suppressed) {
        st.message = "suppressed";
        r.features.push_back(st);
        continue;
      }
      try {
        int self = ownerIndex(f.id);
        if (f.type == "sketch") processSketch(f);
        else if (f.type == "fillet" || f.type == "chamfer") applyEdgeFeature(f, self);
        else applyBoolean(f, toolShape(f), self);
      } catch (const Standard_Failure& e) {
        st.ok = false;
        st.message = std::string("geometry kernel error: ") + e.GetMessageString();
      } catch (const std::exception& e) {
        st.ok = false;
        st.message = e.what();
      }
      r.ok = r.ok && st.ok;
      r.features.push_back(st);
    }
    faceIndex.assign(bodies.size(), ShapeIndex());
    for (size_t b = 0; b < bodies.size(); ++b) TopExp::MapShapes(bodies[b], TopAbs_FACE, faceIndex[b]);
    r.milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    report = r;
    return r;
  }

  std::string ownerOf(int b, const TopoDS_Shape& face) const {
    if (b < 0 || b >= static_cast<int>(tags.size()) || !tags[b].IsBound(face)) return {};
    return owners[tags[b].Find(face)];
  }
};

PartModel::PartModel(PartDocument doc) : d_(std::make_unique<Impl>()) {
  d_->doc = std::move(doc);
}
PartModel::~PartModel() = default;
PartModel::PartModel(PartModel&&) noexcept = default;
PartModel& PartModel::operator=(PartModel&&) noexcept = default;

const PartDocument& PartModel::document() const { return d_->doc; }
PartDocument& PartModel::document() { return d_->doc; }
RebuildReport PartModel::rebuild() { return d_->rebuild(); }
const RebuildReport& PartModel::lastReport() const { return d_->report; }
int PartModel::bodyCount() const { return static_cast<int>(d_->bodies.size()); }
const TopoDS_Shape& PartModel::body(int i) const { return d_->bodies.at(static_cast<size_t>(i)); }
const std::map<std::string, double>& PartModel::variables() const { return d_->vars; }

double PartModel::param(const Feature& f, const std::string& key, double fallback) const {
  if (!f.params.contains(key)) return fallback;
  try {
    return d_->value(f.params.at(key), Quantity::Length);
  } catch (...) {
    return fallback;
  }
}

BodyMesh PartModel::mesh(int b, double defl, double ang) const {
  BodyMesh out;
  const TopoDS_Shape& shape = body(b);
  BRepMesh_IncrementalMesh mesher(shape, defl, false, ang, true);
  const ShapeIndex& faces = d_->faceIndex.at(static_cast<size_t>(b));
  out.faces.resize(static_cast<size_t>(faces.Extent()));
  for (int fi = 1; fi <= faces.Extent(); ++fi) {
    TopoDS_Face face = TopoDS::Face(faces(fi));
    FaceInfo& info = out.faces[static_cast<size_t>(fi - 1)];
    info.featureId = d_->ownerOf(b, face);
    info.kind = surfaceKind(face);
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    gp_Dir n = outwardNormal(face, 0.5 * (u0 + u1), 0.5 * (v0 + v1));
    info.normal = {n.X(), n.Y(), n.Z()};

    TopLoc_Location loc;
    occ::handle<Poly_Triangulation> tri = BRep_Tool::Triangulation(face, loc);
    if (tri.IsNull() || tri->NbTriangles() == 0) continue;
    if (!tri->HasNormals()) BRepLib_ToolTriangulatedShape::ComputeNormals(face, tri);
    const gp_Trsf trsf = loc.Transformation();
    const bool reversed = face.Orientation() == TopAbs_REVERSED;
    const uint32_t base = static_cast<uint32_t>(out.positions.size() / 3);
    for (int i = 1; i <= tri->NbNodes(); ++i) {
      gp_Pnt p = tri->Node(i).Transformed(trsf);
      gp_Dir nn = tri->Normal(i).Transformed(trsf);
      if (reversed) nn.Reverse();
      out.positions.insert(out.positions.end(), {float(p.X()), float(p.Y()), float(p.Z())});
      out.normals.insert(out.normals.end(), {float(nn.X()), float(nn.Y()), float(nn.Z())});
    }
    for (int i = 1; i <= tri->NbTriangles(); ++i) {
      int a, c, e;
      tri->Triangle(i).Get(a, c, e);
      if (reversed) std::swap(c, e);
      out.indices.insert(out.indices.end(), {base + uint32_t(a - 1), base + uint32_t(c - 1), base + uint32_t(e - 1)});
      out.triangleFace.push_back(fi - 1);
    }
  }
  ShapeIndex edges;
  TopExp::MapShapes(shape, TopAbs_EDGE, edges);
  for (int i = 1; i <= edges.Extent(); ++i) {
    TopoDS_Edge e = TopoDS::Edge(edges(i));
    if (BRep_Tool::Degenerated(e)) continue;
    BRepAdaptor_Curve c(e);
    GCPnts_TangentialDeflection pts(c, ang, defl);
    for (int k = 1; k < pts.NbPoints(); ++k) {
      gp_Pnt a = pts.Value(k), z = pts.Value(k + 1);
      out.edgeLines.insert(out.edgeLines.end(), {float(a.X()), float(a.Y()), float(a.Z()),
                                                 float(z.X()), float(z.Y()), float(z.Z())});
    }
  }
  return out;
}

std::optional<PickHit> PartModel::pick(const Vec3& o, const Vec3& dir, double maxDistance) const {
  gp_Vec dv(dir[0], dir[1], dir[2]);
  if (dv.Magnitude() < 1e-12) return std::nullopt;
  gp_Lin line(gp_Pnt(o[0], o[1], o[2]), gp_Dir(dv));
  d_->pickers.resize(d_->bodies.size());
  std::optional<PickHit> best;
  for (size_t b = 0; b < d_->bodies.size(); ++b) {
    auto& pk = d_->pickers[b];
    if (!pk) {
      pk = std::make_unique<IntCurvesFace_ShapeIntersector>();
      pk->Load(d_->bodies[b], 1e-7);
    }
    pk->PerformNearest(line, 0, maxDistance);
    if (!pk->IsDone() || pk->NbPnt() < 1) continue;
    double w = pk->WParameter(1);
    if (best && w >= best->distance) continue;
    const TopoDS_Face& face = pk->Face(1);
    gp_Pnt p = pk->Pnt(1);
    gp_Dir n = outwardNormal(face, pk->UParameter(1), pk->VParameter(1));
    PickHit h;
    h.body = static_cast<int>(b);
    h.face = d_->faceIndex[b].FindIndex(face) - 1;
    h.featureId = d_->ownerOf(static_cast<int>(b), face);
    h.point = {p.X(), p.Y(), p.Z()};
    h.normal = {n.X(), n.Y(), n.Z()};
    h.distance = w;
    best = h;
  }
  return best;
}


namespace {

// Push/pull tokens: which parameter a face drives and in which direction it moves.
//   +w -w +d -d   box width/depth (the opposite face stays put)
//   +h -h         top / bottom of boxes, cylinders and cones
//   r             radius (cylinder, sphere, cone side)
//   +depth -depth extrude end faces
//   p+w p-w p+h p-h pr   extrude profile sides (rect width/height, circle radius)
//   fr cd         fillet radius, chamfer distance
struct Drive {
  std::string token;
  std::string label;
};

std::optional<Drive> driveFor(const Feature& f, const gp_Dir& n, const gp_Ax3* plane) {
  const double nx = n.X(), ny = n.Y(), nz = n.Z();
  auto axis = [&](const char* pos, const char* neg, double c, const char* lpos, const char* lneg) {
    return Drive{c > 0 ? pos : neg, c > 0 ? lpos : lneg};
  };
  if (f.type == "box") {
    if (std::abs(nx) > 0.9) return axis("+w", "-w", nx, "right face · width", "left face · width");
    if (std::abs(ny) > 0.9) return axis("+d", "-d", ny, "back face · depth", "front face · depth");
    if (std::abs(nz) > 0.9) return axis("+h", "-h", nz, "top face · height", "bottom face · height");
    return std::nullopt;
  }
  if (f.type == "cylinder" || f.type == "cone") {
    if (std::abs(nz) > 0.9) return axis("+h", "-h", nz, "top face · height", "bottom face · height");
    return Drive{"r", "side · radius"};
  }
  if (f.type == "sphere") return Drive{"r", "surface · radius"};
  if (f.type == "fillet") return Drive{"fr", "fillet · radius"};
  if (f.type == "chamfer") return Drive{"cd", "chamfer · distance"};
  if (f.type == "extrude" && plane) {
    gp_Dir N = plane->Direction(), X = plane->XDirection(), Y = plane->YDirection();
    double a = n.Dot(N);
    if (a > 0.9) return Drive{"+depth", "end face · depth"};
    if (a < -0.9) return Drive{"-depth", "start face · depth"};
    std::string kind = f.params.at("profile").value("kind", std::string());
    if (kind == "circle") return Drive{"pr", "side · profile radius"};
    if (kind == "rect") {
      double u = n.Dot(X), v = n.Dot(Y);
      if (std::abs(u) > 0.9) return Drive{u > 0 ? "p+w" : "p-w", "side · profile width"};
      if (std::abs(v) > 0.9) return Drive{v > 0 ? "p+h" : "p-h", "side · profile height"};
    }
  }
  return std::nullopt;
}

}  // namespace

std::optional<FaceDrive> PartModel::faceDrive(const PickHit& hit) const {
  const Feature* f = d_->doc.find(hit.featureId);
  if (!f) return std::nullopt;
  if (f->type == "extrude" && f->params.contains("sketch")) {
    // The end face drives the depth; the start face moves the start offset.
    try {
      if (f->params.value("end", std::string("blind")) == "through_all") return std::nullopt;
      const SketchState& st = d_->sketchRef(f->params, "sketch");
      gp_Dir dir = Impl::extrudeDir(st, f->params);
      double a = gp_Dir(hit.normal[0], hit.normal[1], hit.normal[2]).Dot(dir);
      bool sym = f->params.value("direction", std::string("normal")) == "symmetric";
      FaceDrive fd;
      fd.featureId = f->id;
      fd.value = d_->get(f->params, "depth");
      if (a > 0.9) { fd.param = "+depth"; fd.label = sym ? "end face · depth (both sides)" : "end face · depth"; return fd; }
      if (a < -0.9) { fd.param = "-depth"; fd.label = sym ? "end face · depth (both sides)" : "start face · depth"; return fd; }
    } catch (...) {
    }
    return std::nullopt;
  }
  try {
    // A cut's faces bound empty space: seen from the tool body their normal points the other way.
    gp_Dir n(hit.normal[0], hit.normal[1], hit.normal[2]);
    if (f->op == BodyOp::Cut) n.Reverse();
    std::optional<gp_Ax3> plane;
    if (f->type == "extrude") plane = d_->sketchPlane(f->params.at("plane"));
    auto drv = driveFor(*f, n, plane ? &*plane : nullptr);
    if (!drv) return std::nullopt;
    const std::string& t = drv->token;
    const Json& p = f->params;
    FaceDrive fd;
    fd.featureId = f->id;
    fd.param = t;
    fd.label = drv->label;
    if (t == "+w" || t == "-w") fd.value = d_->get(p, "w");
    else if (t == "+d" || t == "-d") fd.value = d_->get(p, "d");
    else if (t == "+h" || t == "-h") fd.value = d_->get(p, "h");
    else if (t == "r") fd.value = d_->get(p, f->type == "cone" ? "r1" : "r");
    else if (t == "fr") fd.value = d_->get(p, "r");
    else if (t == "cd") fd.value = d_->get(p, "d");
    else if (t == "+depth" || t == "-depth") fd.value = d_->get(p, "depth");
    else if (t == "pr") fd.value = d_->get(p.at("profile"), "r");
    else if (t == "p+w" || t == "p-w") fd.value = d_->get(p.at("profile"), "w");
    else if (t == "p+h" || t == "p-h") fd.value = d_->get(p.at("profile"), "h");
    return fd;
  } catch (...) {
    return std::nullopt;
  }
}

bool PartModel::pushPull(const PickHit& hit, double delta, std::string* message) {
  auto say = [&](const std::string& m) { if (message) *message = m; };
  auto fd = faceDrive(hit);
  if (!fd) { say("this face has no driving dimension"); return false; }
  Feature* f = d_->doc.find(fd->featureId);
  const PartDocument backup = d_->doc;
  const bool wasOk = d_->report.ok;
  const double kMin = 1e-5;
  const std::string& t = fd->param;
  // Pushing a face moves it along its outward normal. For a cut that shrinks the hole.
  if (f->op == BodyOp::Cut) delta = -delta;
  Json& p = f->params;
  try {
    auto grow = [&](Json& obj, const char* key, double sign, const char* posKey) {
      double cur = d_->get(obj, key);
      double next = std::max(kMin, cur + delta);
      obj[key] = next;
      if (posKey) obj[posKey] = d_->get(obj, posKey) + sign * (next - cur) / 2;
      return next - cur;
    };
    if (t == "+w") grow(p, "w", +1, "x");
    else if (t == "-w") grow(p, "w", -1, "x");
    else if (t == "+d") grow(p, "d", +1, "y");
    else if (t == "-d") grow(p, "d", -1, "y");
    else if (t == "+h") grow(p, "h", 0, nullptr);
    else if (t == "-h") { double moved = grow(p, "h", 0, nullptr); p["z"] = d_->get(p, "z") - moved; }
    else if (t == "r" && f->type == "cone") {
      p["r1"] = std::max(0.0, d_->get(p, "r1") + delta);
      p["r2"] = std::max(0.0, d_->get(p, "r2") + delta);
    }
    else if (t == "r") grow(p, "r", 0, nullptr);
    else if (t == "fr") grow(p, "r", 0, nullptr);
    else if (t == "cd") grow(p, "d", 0, nullptr);
    else if (t == "pr") grow(p["profile"], "r", 0, nullptr);
    else if (t == "p+w") grow(p["profile"], "w", +1, "cx");
    else if (t == "p-w") grow(p["profile"], "w", -1, "cx");
    else if (t == "p+h") grow(p["profile"], "h", +1, "cy");
    else if (t == "p-h") grow(p["profile"], "h", -1, "cy");
    else if ((t == "+depth" || t == "-depth") && p.contains("sketch")) {
      bool sym = p.value("direction", std::string("normal")) == "symmetric";
      double cur = d_->get(p, "depth");
      double next = std::max(kMin, cur + (sym ? 2 * delta : delta));
      p["depth"] = next;
      if (t == "-depth" && !sym) p["offset"] = (p.contains("offset") ? d_->get(p, "offset") : 0.0) - (next - cur);
    }
    else if (t == "+depth" || t == "-depth") {
      gp_Ax3 ax = d_->sketchPlane(p.at("plane"));
      bool sym = p.value("symmetric", false);
      double moved = grow(p, "depth", 0, nullptr);
      gp_Vec N(ax.Direction());
      gp_Vec shift = t == "+depth" ? (sym ? N * (moved / 2) : gp_Vec(0, 0, 0))
                                   : (sym ? N * (-moved / 2) : N * (-moved));
      gp_Pnt o = ax.Location().Translated(shift);
      p["plane"]["origin"] = {o.X(), o.Y(), o.Z()};
    }
  } catch (const std::exception& e) {
    d_->doc = backup;
    say(e.what());
    return false;
  }
  RebuildReport r = rebuild();
  bool targetOk = true;
  for (auto& st : r.features) if (st.featureId == fd->featureId) targetOk = st.ok;
  if (!targetOk || (wasOk && !r.ok)) {
    std::string why;
    for (auto& st : r.features) if (!st.ok) { why = st.message; break; }
    d_->doc = backup;
    rebuild();
    say("that change would break the model" + (why.empty() ? std::string() : ": " + why));
    return false;
  }
  say(f->name + " " + fd->label);
  return true;
}

MassProperties PartModel::massProperties() const {
  MassProperties m;
  gp_XYZ moment(0, 0, 0);
  for (auto& b : d_->bodies) {
    GProp_GProps vp, sp;
    BRepGProp::VolumeProperties(b, vp);
    BRepGProp::SurfaceProperties(b, sp);
    m.volume += vp.Mass();
    m.area += sp.Mass();
    moment += vp.CentreOfMass().XYZ() * vp.Mass();
  }
  m.bodies = bodyCount();
  m.mass = m.volume * d_->doc.density;
  if (m.volume > 0) {
    gp_XYZ c = moment / m.volume;
    m.centreOfMass = {c.X(), c.Y(), c.Z()};
  }
  return m;
}

std::vector<Vec3> PartModel::faceVertices(int b, int face) const {
  std::vector<Vec3> out;
  if (b < 0 || b >= bodyCount()) return out;
  const ShapeIndex& faces = d_->faceIndex[static_cast<size_t>(b)];
  if (face < 0 || face >= faces.Extent()) return out;
  ShapeIndex verts;
  TopExp::MapShapes(faces(face + 1), TopAbs_VERTEX, verts);
  for (int i = 1; i <= verts.Extent(); ++i) {
    gp_Pnt p = BRep_Tool::Pnt(TopoDS::Vertex(verts(i)));
    out.push_back({p.X(), p.Y(), p.Z()});
  }
  return out;
}

// ----- Sketches -----

SolveResult PartModel::solve(Sketch& s) const { return solveSketch(s, d_->valueFn()); }

bool PartModel::isConsumed(const std::string& id) const {
  bool after = false;
  for (auto& f : d_->doc.features) {
    if (f.id == id) { after = true; continue; }
    if (!after || f.suppressed) continue;
    const Json& p = f.params;
    for (const char* k : {"sketch", "path"})
      if (p.contains(k) && p.at(k).is_string() && p.at(k).get<std::string>() == id) return true;
    if (p.contains("sketches") && p.at("sketches").is_array())
      for (auto& v : p.at("sketches"))
        if (v.is_string() && v.get<std::string>() == id) return true;
  }
  return false;
}

std::string PartModel::latestUnusedSketch() const {
  for (auto it = d_->doc.features.rbegin(); it != d_->doc.features.rend(); ++it)
    if (it->type == "sketch" && !it->suppressed && !isConsumed(it->id)) return it->id;
  return {};
}

std::vector<SketchView> PartModel::sketchViews() const {
  std::vector<SketchView> out;
  for (auto& f : d_->doc.features) {
    if (f.type != "sketch") continue;
    auto it = d_->sketches.find(f.id);
    if (it == d_->sketches.end()) continue;
    const SketchState& st = it->second;
    SketchView v;
    v.featureId = f.id;
    v.name = f.name;
    v.planeName = st.sketch.planeName;
    v.consumed = isConsumed(f.id);
    v.ok = st.solve.ok;
    v.dof = st.solve.dof;
    v.message = st.solve.message;
    v.regions = static_cast<int>(st.geom.regions.size());
    for (auto& pl : sketchPolylines(st.sketch)) {
      auto& dst = pl.construction ? v.constructionSegments : v.segments;
      for (size_t i = 0; i + 1 < pl.points.size(); ++i) {
        Vec3d a = st.sketch.plane.toWorld(pl.points[i][0], pl.points[i][1]);
        Vec3d b = st.sketch.plane.toWorld(pl.points[i + 1][0], pl.points[i + 1][1]);
        dst.push_back(a);
        dst.push_back(b);
      }
    }
    out.push_back(std::move(v));
  }
  return out;
}

std::optional<SketchPlane> PartModel::planeFromHit(const PickHit& hit, std::string* name) const {
  if (hit.body < 0 || hit.body >= bodyCount()) return std::nullopt;
  const ShapeIndex& faces = d_->faceIndex[static_cast<size_t>(hit.body)];
  if (hit.face < 0 || hit.face >= faces.Extent()) return std::nullopt;
  TopoDS_Face face = TopoDS::Face(faces(hit.face + 1));
  if (BRepAdaptor_Surface(face).GetType() != GeomAbs_Plane) return std::nullopt;
  Vec3d n = hit.normal;
  double len = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
  if (len < 1e-12) return std::nullopt;
  for (auto& c : n) c /= len;
  SketchPlane pl;
  pl.normal = n;
  // The part origin projected onto the face's plane keeps sketch coordinates meaningful.
  double k = hit.point[0] * n[0] + hit.point[1] * n[1] + hit.point[2] * n[2];
  pl.origin = {n[0] * k, n[1] * k, n[2] * k};
  Vec3d axis = std::abs(n[0]) < 0.9 ? Vec3d{1, 0, 0} : Vec3d{0, 1, 0};
  double d = axis[0] * n[0] + axis[1] * n[1] + axis[2] * n[2];
  pl.xdir = {axis[0] - d * n[0], axis[1] - d * n[1], axis[2] - d * n[2]};
  pl = SketchPlane::fromJson(pl.toJson());  // normalises xdir
  if (name) {
    const Feature* f = d_->doc.find(hit.featureId);
    *name = "Face of " + (f ? f->name : std::string("the part"));
  }
  return pl;
}

std::optional<SketchHit> PartModel::pickSketch(const Vec3& o, const Vec3& dir, double maxDistance, double tolerance,
                                               bool includeConsumed) const {
  std::optional<SketchHit> best;
  for (auto& [id, st] : d_->sketches) {
    if (!includeConsumed && isConsumed(id)) continue;
    const SketchPlane& pl = st.sketch.plane;
    const Vec3d& n = pl.normal;
    double denom = dir[0] * n[0] + dir[1] * n[1] + dir[2] * n[2];
    if (std::abs(denom) < 1e-12) continue;
    double t = ((pl.origin[0] - o[0]) * n[0] + (pl.origin[1] - o[1]) * n[1] + (pl.origin[2] - o[2]) * n[2]) / denom;
    if (t < 0 || t > maxDistance || (best && t >= best->distance)) continue;
    Vec3 p{o[0] + dir[0] * t, o[1] + dir[1] * t, o[2] + dir[2] * t};
    auto q = pl.toPlane(p);
    int region = -1;
    for (size_t i = 0; i < st.geom.regionOutlines.size() && region < 0; ++i) {
      if (!pointInPolygon(st.geom.regionOutlines[i], q[0], q[1])) continue;
      bool inHole = false;
      for (auto& h : st.geom.regionHoles[i]) inHole = inHole || pointInPolygon(h, q[0], q[1]);
      if (!inHole) region = static_cast<int>(i);
    }
    bool nearLine = false;
    if (region < 0) {
      double tol = tolerance * std::max(t, 1e-6);
      for (auto& pl2 : sketchPolylines(st.sketch)) {
        for (size_t i = 0; i + 1 < pl2.points.size() && !nearLine; ++i) {
          auto a = pl2.points[i], b = pl2.points[i + 1];
          double dx = b[0] - a[0], dy = b[1] - a[1];
          double L2 = dx * dx + dy * dy;
          double s = L2 > 0 ? std::clamp(((q[0] - a[0]) * dx + (q[1] - a[1]) * dy) / L2, 0.0, 1.0) : 0.0;
          nearLine = std::hypot(a[0] + s * dx - q[0], a[1] + s * dy - q[1]) < tol;
        }
        if (nearLine) break;
      }
    }
    if (region < 0 && !nearLine) continue;
    best = SketchHit{id, region, p, t};
  }
  return best;
}

}  // namespace fpcad
