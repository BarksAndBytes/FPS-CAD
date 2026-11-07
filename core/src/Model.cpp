#include "fpcad/Model.h"

#include <algorithm>
#include <sstream>
#include <chrono>
#include <cmath>
#include <stdexcept>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BinTools.hxx>
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
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <gp_Cylinder.hxx>
#include <set>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepPrimAPI_MakeHalfSpace.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRep_Builder.hxx>
#include <Bnd_Box.hxx>
#include <TopoDS_Compound.hxx>
#include <gp_Ax1.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <gp_Trsf.hxx>

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

// A face's edges flattened onto a sketch plane (see PartModel::projectFace).
std::vector<PartModel::ProjectedCurve> projectFaceEdges(const TopoDS_Face& faceShape, const SketchPlane& plane) {
  std::vector<PartModel::ProjectedCurve> out;
  const gp_Dir N(plane.normal[0], plane.normal[1], plane.normal[2]);
  auto flat = [&](const gp_Pnt& p) { return plane.toPlane({p.X(), p.Y(), p.Z()}); };
  auto gap = [](const std::array<double, 2>& a, const std::array<double, 2>& c) {
    return std::hypot(a[0] - c[0], a[1] - c[1]);
  };
  ShapeIndex edges;
  TopExp::MapShapes(faceShape, TopAbs_EDGE, edges);
  for (int i = 1; i <= edges.Extent(); ++i) {
    const TopoDS_Edge& edge = TopoDS::Edge(edges(i));
    if (BRep_Tool::Degenerated(edge)) continue;
    try {
      BRepAdaptor_Curve c(edge);
      double t0 = c.FirstParameter(), t1 = c.LastParameter();
      gp_Pnt s3 = c.Value(t0), e3 = c.Value(t1);
      bool closedEdge = s3.Distance(e3) < 1e-9;
      PartModel::ProjectedCurve pc;
      if (c.GetType() == GeomAbs_Line) {
        pc.kind = "line";
        pc.pts = {flat(s3), flat(e3)};
        if (gap(pc.pts[0], pc.pts[1]) < 1e-9) continue;
      } else if (c.GetType() == GeomAbs_Circle && std::abs(c.Circle().Axis().Direction().Dot(N)) > 1 - 1e-9) {
        gp_Circ circ = c.Circle();
        auto centre = flat(circ.Location());
        if (closedEdge) {
          pc.kind = "circle";
          pc.pts = {centre};
          pc.r = circ.Radius();
        } else {
          pc.kind = "arc";
          // Parameters run counter-clockwise about the circle's own axis.
          bool ccw = circ.Axis().Direction().Dot(N) > 0;
          pc.pts = {centre, flat(ccw ? s3 : e3), flat(ccw ? e3 : s3)};
        }
      } else {
        // Anything else is sampled into a spline; one that flattens to a straight run is a line.
        int n = closedEdge ? 16 : 9;
        std::vector<std::array<double, 2>> pts;
        for (int k = 0; k < n; ++k) pts.push_back(flat(c.Value(t0 + (t1 - t0) * k / (closedEdge ? n : n - 1))));
        size_t ia = 0, ib = 0;
        double span = 0;
        for (size_t a = 0; a < pts.size(); ++a)
          for (size_t z = a + 1; z < pts.size(); ++z)
            if (gap(pts[a], pts[z]) > span) { span = gap(pts[a], pts[z]); ia = a; ib = z; }
        if (span < 1e-9) continue;
        double off = 0;
        auto A = pts[ia], B = pts[ib];
        for (auto& q : pts)
          off = std::max(off, std::abs((B[0] - A[0]) * (q[1] - A[1]) - (B[1] - A[1]) * (q[0] - A[0])) / span);
        if (off < 1e-7 * std::max(1.0, span)) {
          pc.kind = "line";
          pc.pts = {A, B};
        } else {
          pc.kind = "spline";
          pc.pts = pts;
          pc.closed = closedEdge;
        }
      }
      out.push_back(pc);
    } catch (const Standard_Failure&) {
      continue;
    }
  }
  return out;
}

// The point of face f nearest p, and the face's outward normal there.
bool nearestOnFace(const TopoDS_Face& f, const gp_Pnt& p, gp_Pnt& at, gp_Dir& n) {
  BRepExtrema_DistShapeShape d(BRepBuilderAPI_MakeVertex(p).Vertex(), f);
  if (!d.IsDone() || d.NbSolution() < 1) return false;
  at = d.PointOnShape2(1);
  double u = 0, v = 0;
  if (d.SupportTypeShape2(1) == BRepExtrema_IsInFace) {
    d.ParOnFaceS2(1, u, v);
  } else {
    // On an edge or a vertex (a cylinder's seam, say): read the surface there directly.
    GeomAPI_ProjectPointOnSurf proj(at, BRep_Tool::Surface(f));
    if (proj.NbPoints() < 1) return false;
    proj.LowerDistanceParameters(u, v);
  }
  BRepGProp_Face gf(f);
  gp_Pnt q;
  gp_Vec nv;
  gf.Normal(u, v, q, nv);
  if (nv.Magnitude() < 1e-15) return false;
  n = gp_Dir(nv);
  return true;
}

// Key points of a sketch entity and of a projected curve, for matching one to the other.
std::vector<std::string> keyIds(const SketchEntity& e) {
  if (e.kind == "spline" && e.pts.size() > 2 && e.pts.front() == e.pts.back())
    return std::vector<std::string>(e.pts.begin(), e.pts.end() - 1);
  return e.pts;
}

// Lays projected curves into the sketch under link l. Entities the link made before keep their
// ids (moved onto the new edges); edges that went away are removed along with the relations that
// mention them. New edges are added only when addNew (the first conversion), so a converted line
// the player deleted or unlinked stays gone. Converted points are fixed.
void applyLink(Sketch& s, SketchLink& l, const std::vector<PartModel::ProjectedCurve>& curves, bool addNew) {
  const Sketch& cs = s;
  auto pos = [&](const std::string& id) {
    const SketchPoint* p = cs.point(id);
    return p ? std::array<double, 2>{p->x, p->y} : std::array<double, 2>{1e300, 1e300};
  };
  auto gap = [](const std::array<double, 2>& a, const std::array<double, 2>& b) { return std::hypot(a[0] - b[0], a[1] - b[1]); };
  double scale = 1e-3;
  for (auto& c : curves)
    for (auto& q : c.pts) scale = std::max({scale, std::abs(q[0]), std::abs(q[1])});
  const double tol = 1e-9 * scale;

  // Match old entities to new curves, cheapest first.
  struct Pair { double cost; size_t e, c; bool rev; };
  std::vector<SketchEntity> old;  // copies: s.entities grows below
  for (auto& id : l.entities)
    if (const SketchEntity* e = s.entity(id)) old.push_back(*e);
  std::vector<Pair> pairs;
  for (size_t i = 0; i < old.size(); ++i)
    for (size_t j = 0; j < curves.size(); ++j) {
      auto ids = keyIds(old[i]);
      const auto& c = curves[j];
      if (old[i].kind != c.kind || ids.size() != c.pts.size()) continue;
      for (int rev = 0; rev < (c.kind == "line" ? 2 : 1); ++rev) {
        double cost = 0;
        for (size_t k = 0; k < ids.size(); ++k) cost += gap(pos(ids[k]), c.pts[rev ? ids.size() - 1 - k : k]);
        if (c.kind == "circle") cost += std::abs(old[i].r - c.r);
        pairs.push_back({cost, i, j, rev == 1});
      }
    }
  std::sort(pairs.begin(), pairs.end(), [](const Pair& a, const Pair& b) { return a.cost < b.cost; });
  std::vector<int> matchOf(curves.size(), -1);
  std::vector<bool> revOf(curves.size(), false), oldUsed(old.size(), false);
  for (auto& p : pairs) {
    if (oldUsed[p.e] || matchOf[p.c] >= 0) continue;
    oldUsed[p.e] = true;
    matchOf[p.c] = static_cast<int>(p.e);
    revOf[p.c] = p.rev;
  }

  // Where each point goes this time; a point asked to be in two places is split.
  std::map<std::string, std::array<double, 2>> placed;
  auto pointAt = [&](const std::string& want, const std::array<double, 2>& at) -> std::string {
    if (gap(at, {0, 0}) < tol) return "o";
    for (auto& [id, q] : placed)
      if (gap(q, at) < tol) return id;
    if (!want.empty() && want != "o" && !placed.count(want)) {
      if (SketchPoint* p = s.point(want)) {
        p->x = at[0];
        p->y = at[1];
        p->fixed = true;
        placed[want] = at;
        return want;
      }
    }
    for (auto& p : s.points)
      if (p.fixed && gap({p.x, p.y}, at) < tol) {
        placed[p.id] = at;
        return p.id;
      }
    std::string id = freshSketchId(s, l.id + "p");
    s.points.push_back({id, at[0], at[1], true});
    placed[id] = at;
    return id;
  };

  std::vector<std::string> keep;
  for (size_t j = 0; j < curves.size(); ++j) {
    const auto& c = curves[j];
    std::vector<std::string> want(c.pts.size());
    SketchEntity* e = nullptr;
    if (matchOf[j] >= 0) {
      for (auto& x : s.entities)
        if (x.id == old[static_cast<size_t>(matchOf[j])].id) e = &x;
      auto ids = keyIds(*e);
      for (size_t k = 0; k < ids.size(); ++k) want[revOf[j] ? ids.size() - 1 - k : k] = ids[k];
    } else if (!addNew) {
      continue;
    }
    std::vector<std::string> ids;
    for (size_t k = 0; k < c.pts.size(); ++k) ids.push_back(pointAt(want[k], c.pts[k]));
    if (c.kind == "spline" && c.closed) ids.push_back(ids.front());
    if (!e) {
      SketchEntity ne;
      ne.id = freshSketchId(s, c.kind == "line" ? "l" : c.kind == "circle" ? "k" : c.kind == "arc" ? "a" : "s");
      ne.kind = c.kind;
      s.entities.push_back(ne);
      e = &s.entities.back();
      if (c.kind == "circle") s.constraints.push_back({freshSketchId(s, "d"), "radius", {ne.id}, c.r});
    }
    e->pts = ids;
    if (c.kind == "circle") {
      e->r = c.r;
      for (auto& k : s.constraints)
        if (k.kind == "radius" && k.refs.size() == 1 && k.refs[0] == e->id && k.value.is_number()) k.value = c.r;
    }
    keep.push_back(e->id);
  }

  // Edges that are gone: their entities, then points nothing uses, then relations to either.
  std::set<std::string> gone;
  for (size_t i = 0; i < old.size(); ++i)
    if (!oldUsed[i]) gone.insert(old[i].id);
  std::vector<SketchEntity> ents;
  for (auto& e : s.entities)
    if (!gone.count(e.id)) ents.push_back(e);
  s.entities = ents;
  std::set<std::string> used;
  for (auto& e : s.entities)
    for (auto& q : e.pts) used.insert(q);
  std::vector<SketchPoint> pts;
  for (auto& p : s.points) {
    bool mine = std::find(l.points.begin(), l.points.end(), p.id) != l.points.end();
    if (mine && !used.count(p.id)) gone.insert(p.id);
    else pts.push_back(p);
  }
  s.points = pts;
  std::vector<SketchConstraint> cons;
  for (auto& c : s.constraints) {
    bool drop = false;
    for (auto& r : c.refs) drop = drop || gone.count(r);
    if (!drop) cons.push_back(c);
  }
  s.constraints = cons;
  l.entities = keep;
  l.points.clear();
  for (auto& id : keep)
    if (const SketchEntity* e = s.entity(id))
      for (auto& q : e->pts)
        if (q != "o" && std::find(l.points.begin(), l.points.end(), q) == l.points.end()) l.points.push_back(q);
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
  // Reference geometry by feature id, filled during rebuild.
  struct RefGeom {
    std::string kind;   // plane, axis, point, csys
    gp_Ax3 frame;       // planes, csys; axes: location + direction; points: location
    double size = 0.5;  // half-size for drawing
  };
  std::map<std::string, RefGeom> refs;
  RebuildReport report;
  std::vector<TopoDS_Shape> bodies;
  std::vector<FaceTags> tags;          // per body: face -> owner index
  std::vector<std::string> owners;     // owner index -> feature id
  std::vector<ShapeIndex> faceIndex;   // per body: stable face numbering for meshes and picks
  std::map<std::string, double> vars;
  mutable std::vector<std::unique_ptr<IntCurvesFace_ShapeIntersector>> pickers;
  // Section view: each body cut by the section plane (what is shown, walked on and picked) and,
  // per body, which original face each of the cut shape's faces came from (-1: the cut face).
  std::optional<gp_Pln> section;
  std::vector<TopoDS_Shape> sectBodies;
  std::vector<ShapeIndex> sectFaces;
  std::vector<std::vector<int>> sectOrig;

  void buildSection() {
    sectBodies.clear();
    sectFaces.clear();
    sectOrig.clear();
    pickers.clear();
    if (!section) return;
    gp_Pnt o = section->Location();
    gp_Vec n(section->Axis().Direction());
    TopoDS_Face big = BRepBuilderAPI_MakeFace(*section).Face();
    TopoDS_Shape keep = BRepPrimAPI_MakeHalfSpace(big, o.Translated(-n)).Solid();
    for (size_t b = 0; b < bodies.size(); ++b) {
      TopoDS_Shape cut;
      NCollection_DataMap<TopoDS_Shape, int, TopTools_ShapeMapHasher> from;
      try {
        BRepAlgoAPI_Common op(bodies[b], keep);
        if (op.IsDone() && !op.HasErrors()) {
          cut = op.Shape();
          const ShapeIndex& faces = faceIndex[b];
          for (int fi = 1; fi <= faces.Extent(); ++fi) {
            const TopoDS_Shape& f = faces(fi);
            if (op.IsDeleted(f)) continue;
            const auto& mods = op.Modified(f);
            if (mods.IsEmpty()) from.Bind(f, fi - 1);
            else
              for (const auto& m : mods) if (!from.IsBound(m)) from.Bind(m, fi - 1);
          }
        }
      } catch (const Standard_Failure&) {
        cut.Nullify();
      }
      ShapeIndex idx;
      std::vector<int> orig;
      if (!cut.IsNull()) {
        TopExp::MapShapes(cut, TopAbs_FACE, idx);
        for (int i = 1; i <= idx.Extent(); ++i) orig.push_back(from.IsBound(idx(i)) ? from.Find(idx(i)) : -1);
      }
      sectBodies.push_back(cut);
      sectFaces.push_back(idx);
      sectOrig.push_back(orig);
    }
  }

  bool sectioned(size_t b) const { return section && b < sectBodies.size(); }

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
    if (f.params.contains("planeRef") && f.params.at("planeRef").is_string()) {
      // On a reference plane: the sketch follows it.
      std::string pid = f.params.at("planeRef").get<std::string>();
      auto it = refs.find(pid);
      if (it == refs.end() || (it->second.kind != "plane" && it->second.kind != "csys")) {
        const Feature* pf = doc.find(pid);
        throw FeatureError(pf ? pf->name + " must come before this sketch" : "the plane it is on no longer exists");
      }
      const gp_Ax3& a = it->second.frame;
      st.sketch.plane.origin = {a.Location().X(), a.Location().Y(), a.Location().Z()};
      st.sketch.plane.normal = {a.Direction().X(), a.Direction().Y(), a.Direction().Z()};
      st.sketch.plane.xdir = {a.XDirection().X(), a.XDirection().Y(), a.XDirection().Z()};
    }
    refreshLinks(st.sketch);
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

  // Converted edges follow the model: each link's face is found again in the bodies built so far
  // and projected afresh. A face that cannot be found leaves the geometry as it was.
  // A face found again after the model changed: the one nearest probe whose outward normal there
  // is close to want, preferring faces made by feature owner. Returns false when none matches.
  bool findFace(const gp_Pnt& probe, const gp_Dir& want, const std::string& owner, int& body,
                TopoDS_Face& found, gp_Pnt& at, gp_Dir& n, const std::string& role = {}) const {
    if (!owner.empty() && !role.empty()) {
      // The same face of the same feature, wherever it went: nearest to the probe among the
      // faces carrying that role (a face a later feature split in two keeps the role on both).
      std::string want_tag = owner + "#" + role;
      double bestRole = 1e300;
      for (size_t b = 0; b < bodies.size(); ++b)
        for (TopExp_Explorer ex(bodies[b], TopAbs_FACE); ex.More(); ex.Next()) {
          const TopoDS_Face& f = TopoDS::Face(ex.Current());
          if (tagOf(static_cast<int>(b), f) != want_tag) continue;
          gp_Pnt q;
          gp_Dir fn;
          if (!nearestOnFace(f, probe, q, fn)) continue;
          double d = q.Distance(probe);
          if (d < bestRole) {
            bestRole = d;
            found = f;
            at = q;
            n = fn;
            body = static_cast<int>(b);
          }
        }
      if (!found.IsNull()) return true;
    }
    double best = 1e300;
    bool bestOwned = false;
    for (size_t b = 0; b < bodies.size(); ++b) {
      for (TopExp_Explorer ex(bodies[b], TopAbs_FACE); ex.More(); ex.Next()) {
        const TopoDS_Face& f = TopoDS::Face(ex.Current());
        gp_Pnt q;
        gp_Dir fn;
        if (!nearestOnFace(f, probe, q, fn) || fn.Dot(want) < 0.9) continue;
        bool owned = !owner.empty() && ownerOf(static_cast<int>(b), f) == owner;
        double d = q.Distance(probe);
        if ((owned && !bestOwned) || (owned == bestOwned && d < best)) {
          best = d;
          bestOwned = owned;
          found = f;
          at = q;
          n = fn;
          body = static_cast<int>(b);
        }
      }
    }
    return !found.IsNull();
  }

  // A face reference {probe, normal, feature, role} found again; the reference is updated to
  // where it was found.
  bool findFaceRef(Json& ref, int& body, TopoDS_Face& found, gp_Pnt& at, gp_Dir& n) const {
    if (!findFace(gp_Pnt(xyz(ref.at("probe"))), gp_Dir(xyz(ref.at("normal"))), ref.value("feature", std::string()), body,
                  found, at, n, ref.value("role", std::string())))
      return false;
    ref["probe"] = {at.X(), at.Y(), at.Z()};
    ref["normal"] = {n.X(), n.Y(), n.Z()};
    return true;
  }

  // ---------- reference geometry ----------

  static gp_XYZ xyz(const Json& a) {
    return gp_XYZ(a.at(0).get<double>(), a.at(1).get<double>(), a.at(2).get<double>());
  }

  // Half the diagonal of everything built so far (for drawing references), at least 0.25 m.
  double extent() const {
    Bnd_Box b;
    for (auto& s : bodies) BRepBndLib::Add(s, b);
    if (b.IsVoid()) return 0.25;
    return std::max(0.25, std::sqrt(b.SquareExtent()) / 2);
  }

  static gp_Ax3 frameOf(const SketchPlane& p) {
    return gp_Ax3(gp_Pnt(p.origin[0], p.origin[1], p.origin[2]), gp_Dir(p.normal[0], p.normal[1], p.normal[2]),
                  gp_Dir(p.xdir[0], p.xdir[1], p.xdir[2]));
  }

  const RefGeom& refFeature(const Json& r, const char* want1, const char* want2 = nullptr) const {
    std::string id = r.at("feature").get<std::string>();
    auto it = refs.find(id);
    if (it == refs.end() || (it->second.kind != want1 && (!want2 || it->second.kind != want2))) {
      const Feature* f = doc.find(id);
      throw FeatureError(f ? f->name + " must come before this feature" : "a reference it uses no longer exists");
    }
    return it->second;
  }

  // A flat face found again from {probe, normal, feature}; the probe is moved onto it.
  gp_Ax3 facePlane(Json& face, double* size) const {
    int b = 0;
    TopoDS_Face f;
    gp_Pnt at;
    gp_Dir n;
    if (!findFaceRef(face, b, f, at, n))
      throw FeatureError("the face it is based on is no longer there");
    BRepAdaptor_Surface sa(f);
    if (sa.GetType() != GeomAbs_Plane) throw FeatureError("the face it is based on is not flat");
    face["probe"] = {at.X(), at.Y(), at.Z()};
    face["normal"] = {n.X(), n.Y(), n.Z()};
    if (size) {
      Bnd_Box bb;
      BRepBndLib::Add(f, bb);
      *size = std::max(0.02, std::sqrt(bb.SquareExtent()) * 0.6);
    }
    gp_Dir x = sa.Plane().XAxis().Direction();
    if (std::abs(x.Dot(n)) > 0.99) x = std::abs(n.Z()) < 0.9 ? gp::DZ().Crossed(n) : gp::DX();
    gp_Vec xv = gp_Vec(x) - gp_Vec(n) * gp_Vec(x).Dot(gp_Vec(n));
    return gp_Ax3(at, n, gp_Dir(xv));
  }

  gp_Ax3 planeRef(Json& r, double* size) const {
    if (size) *size = extent();
    if (r.is_string()) return frameOf(standardPlane(r.get<std::string>()));
    if (r.contains("feature")) {
      const RefGeom& g = refFeature(r, "plane", "csys");
      if (size) *size = g.size;
      return g.frame;
    }
    if (r.contains("face")) return facePlane(r["face"], size);
    throw FeatureError("unknown plane reference");
  }

  // The straight edge nearest p in the bodies built so far: its line and its two ends.
  bool nearestStraightEdge(const gp_Pnt& p, gp_Pnt& a, gp_Pnt& b, gp_Pnt& on) const {
    double best = 1e300;
    for (auto& body : bodies)
      for (TopExp_Explorer ex(body, TopAbs_EDGE); ex.More(); ex.Next()) {
        const TopoDS_Edge& e = TopoDS::Edge(ex.Current());
        if (BRep_Tool::Degenerated(e)) continue;
        BRepAdaptor_Curve c(e);
        if (c.GetType() != GeomAbs_Line) continue;
        BRepExtrema_DistShapeShape d(BRepBuilderAPI_MakeVertex(p).Vertex(), e);
        if (!d.IsDone() || d.NbSolution() < 1 || d.Value() >= best) continue;
        best = d.Value();
        on = d.PointOnShape2(1);
        a = c.Value(c.FirstParameter());
        b = c.Value(c.LastParameter());
      }
    return best < 1e300;
  }

  gp_Ax1 axisRef(Json& r, double* size) const {
    if (size) *size = extent();
    if (r.is_string()) {
      std::string k = r.get<std::string>();
      gp_Dir d = k == "x" ? gp::DX() : k == "y" ? gp::DY() : gp::DZ();
      return gp_Ax1(gp::Origin(), d);
    }
    if (r.contains("feature")) {
      const RefGeom& g = refFeature(r, "axis");
      if (size) *size = g.size;
      return gp_Ax1(g.frame.Location(), g.frame.Direction());
    }
    if (r.contains("edge")) {
      Json& e = r["edge"];
      gp_Pnt a, b, on;
      if (!nearestStraightEdge(gp_Pnt(xyz(e.at("probe"))), a, b, on)) throw FeatureError("the edge it is based on is no longer there");
      if (a.Distance(b) < 1e-12) throw FeatureError("that edge has no length");
      e["probe"] = {on.X(), on.Y(), on.Z()};
      if (size) *size = a.Distance(b) * 0.6;
      return gp_Ax1(gp_Pnt((a.XYZ() + b.XYZ()) / 2), gp_Dir(gp_Vec(a, b)));
    }
    if (r.contains("cylinder")) {
      Json& c = r["cylinder"];
      int b = 0;
      TopoDS_Face f;
      gp_Pnt at;
      gp_Dir n;
      if (!findFaceRef(c, b, f, at, n))
        throw FeatureError("the round face it is based on is no longer there");
      BRepAdaptor_Surface sa(f);
      if (sa.GetType() != GeomAbs_Cylinder) throw FeatureError("the face it is based on is not a cylinder");
      c["probe"] = {at.X(), at.Y(), at.Z()};
      c["normal"] = {n.X(), n.Y(), n.Z()};
      gp_Ax1 ax = sa.Cylinder().Axis();
      Bnd_Box bb;
      BRepBndLib::Add(f, bb);
      if (size) *size = std::max(0.02, std::sqrt(bb.SquareExtent()) * 0.6);
      // Centre the axis on the face.
      double xmin, ymin, zmin, xmax, ymax, zmax;
      bb.Get(xmin, ymin, zmin, xmax, ymax, zmax);
      gp_Pnt mid((xmin + xmax) / 2, (ymin + ymax) / 2, (zmin + zmax) / 2);
      double t = gp_Vec(ax.Location(), mid).Dot(gp_Vec(ax.Direction()));
      return gp_Ax1(ax.Location().Translated(gp_Vec(ax.Direction()) * t), ax.Direction());
    }
    throw FeatureError("unknown axis reference");
  }

  gp_Pnt pointRef(Json& r) const {
    if (r.is_string()) return gp::Origin();
    if (r.contains("feature")) return refFeature(r, "point", "csys").frame.Location();
    if (r.contains("vertex")) {
      Json& v = r["vertex"];
      gp_Pnt p(xyz(v.at("probe")));
      double best = 1e300;
      gp_Pnt found = p;
      for (auto& body : bodies)
        for (TopExp_Explorer ex(body, TopAbs_VERTEX); ex.More(); ex.Next()) {
          gp_Pnt q = BRep_Tool::Pnt(TopoDS::Vertex(ex.Current()));
          if (q.Distance(p) < best) { best = q.Distance(p); found = q; }
        }
      if (best == 1e300) throw FeatureError("there is no corner to put it on");
      v["probe"] = {found.X(), found.Y(), found.Z()};
      return found;
    }
    if (r.contains("at")) return gp_Pnt(xyz(r.at("at")));
    throw FeatureError("unknown point reference");
  }

  // Works out a plane, axis, point or coordinate system from its references (writing back where
  // the faces, edges and corners it follows were found this time).
  void applyReference(Feature& f) {
    Json& p = f.params;
    RefGeom g;
    g.kind = f.type;
    std::string kind = p.value("kind", std::string());
    if (f.type == "plane") {
      if (kind == "offset" || kind.empty()) {
        gp_Ax3 base = planeRef(p["base"], &g.size);
        double d = get(p, "distance");
        g.frame = base;
        g.frame.Translate(gp_Vec(base.Direction()) * d);
      } else if (kind == "angle") {
        gp_Ax3 base = planeRef(p["base"], &g.size);
        gp_Ax1 ax = axisRef(p["axis"], nullptr);
        double a = get(p, "angle", Quantity::Angle);
        if (std::abs(ax.Direction().Dot(base.Direction())) > 1e-6)
          throw FeatureError("the axis must lie along the plane (square to its normal)");
        gp_Dir n = base.Direction().Rotated(ax, a);
        g.frame = gp_Ax3(ax.Location(), n, ax.Direction());
      } else if (kind == "points") {
        Json& pts = p["points"];
        if (!pts.is_array() || pts.size() != 3) throw FeatureError("a plane through points needs three");
        gp_Pnt a = pointRef(pts[0]), b = pointRef(pts[1]), c = pointRef(pts[2]);
        gp_Vec n = gp_Vec(a, b).Crossed(gp_Vec(a, c));
        if (n.Magnitude() < 1e-12 * std::max(1.0, a.Distance(b) * a.Distance(c))) throw FeatureError("the three points are in a line");
        g.frame = gp_Ax3(a, gp_Dir(n), gp_Dir(gp_Vec(a, b)));
        g.size = std::max({a.Distance(b), a.Distance(c), b.Distance(c), 0.02}) * 0.7;
      } else if (kind == "midplane") {
        double s1 = 0, s2 = 0;
        gp_Ax3 a = planeRef(p["base"], &s1), b = planeRef(p["other"], &s2);
        gp_Dir na = a.Direction(), nb = b.Direction();
        g.size = std::max(s1, s2);
        if (na.IsParallel(nb, 1e-6)) {
          gp_Vec gap(a.Location(), b.Location());
          double dist = gap.Dot(gp_Vec(na));
          g.frame = a;
          g.frame.Translate(gp_Vec(na) * (dist / 2));
        } else {
          // Not parallel: the plane halving the angle between them, through where they meet.
          gp_Dir d = na.Crossed(nb);
          gp_XYZ m = (na.Dot(nb) < 0 ? na.XYZ() - nb.XYZ() : na.XYZ() + nb.XYZ());
          gp_Dir n(m);
          double c1 = gp_Vec(a.Location().XYZ()).Dot(gp_Vec(na)), c2 = gp_Vec(b.Location().XYZ()).Dot(gp_Vec(nb));
          gp_XYZ dx = d.XYZ();
          gp_XYZ pt = (c1 * nb.XYZ().Crossed(dx) + c2 * dx.Crossed(na.XYZ())) / dx.SquareModulus();
          g.frame = gp_Ax3(gp_Pnt(pt), n, d);
        }
      } else {
        throw FeatureError("unknown kind of plane '" + kind + "'");
      }
    } else if (f.type == "axis") {
      gp_Ax1 ax;
      if (kind == "ref" || kind.empty()) {
        ax = axisRef(p["ref"], &g.size);
      } else if (kind == "points") {
        Json& pts = p["points"];
        if (!pts.is_array() || pts.size() != 2) throw FeatureError("an axis through points needs two");
        gp_Pnt a = pointRef(pts[0]), b = pointRef(pts[1]);
        if (a.Distance(b) < 1e-12) throw FeatureError("the two points are the same");
        ax = gp_Ax1(gp_Pnt((a.XYZ() + b.XYZ()) / 2), gp_Dir(gp_Vec(a, b)));
        g.size = a.Distance(b) * 0.6;
      } else if (kind == "planes") {
        gp_Ax3 a = planeRef(p["base"], &g.size), b = planeRef(p["other"], nullptr);
        gp_Dir na = a.Direction(), nb = b.Direction();
        if (na.IsParallel(nb, 1e-6)) throw FeatureError("parallel planes do not meet");
        gp_XYZ d = na.Crossed(nb).XYZ();
        double c1 = a.Location().XYZ().Dot(na.XYZ()), c2 = b.Location().XYZ().Dot(nb.XYZ());
        gp_XYZ pt = (c1 * nb.XYZ().Crossed(d) + c2 * d.Crossed(na.XYZ())) / d.SquareModulus();
        ax = gp_Ax1(gp_Pnt(pt), gp_Dir(d));
      } else {
        throw FeatureError("unknown kind of axis '" + kind + "'");
      }
      gp_Dir x = std::abs(ax.Direction().Z()) < 0.9 ? gp::DZ() : gp::DX();
      g.frame = gp_Ax3(ax.Location(), ax.Direction(), gp_Dir(x.XYZ() - ax.Direction().XYZ() * x.Dot(ax.Direction())));
    } else if (f.type == "point") {
      gp_Pnt pt;
      if (kind == "xyz" || kind.empty()) {
        pt = gp_Pnt(get(p, "x"), get(p, "y"), get(p, "z"));
      } else if (kind == "ref") {
        pt = pointRef(p["ref"]);
      } else if (kind == "centre") {
        Json& face = p["face"];
        int b = 0;
        TopoDS_Face fc;
        gp_Pnt at;
        gp_Dir n;
        if (!findFaceRef(face, b, fc, at, n))
          throw FeatureError("the face it is based on is no longer there");
        face["probe"] = {at.X(), at.Y(), at.Z()};
        GProp_GProps sp;
        BRepGProp::SurfaceProperties(fc, sp);
        pt = sp.CentreOfMass();
      } else {
        throw FeatureError("unknown kind of point '" + kind + "'");
      }
      g.frame = gp_Ax3(pt, gp::DZ(), gp::DX());
      g.size = extent() * 0.04;
    } else {  // csys
      gp_Pnt o = p.contains("origin") ? pointRef(p["origin"]) : gp::Origin();
      gp_Dir z = p.contains("z") ? gp_Dir(xyz(p.at("z"))) : gp::DZ();
      gp_XYZ x = p.contains("x") ? xyz(p.at("x")) : gp::DX().XYZ();
      x -= z.XYZ() * x.Dot(z.XYZ());
      if (x.Modulus() < 1e-9) x = (std::abs(z.Z()) < 0.9 ? gp::DZ().XYZ().Crossed(z.XYZ()) : gp::DX().XYZ());
      g.frame = gp_Ax3(o, z, gp_Dir(x));
      g.size = extent() * 0.25;
    }
    refs[f.id] = g;
  }

  // Push/pull of a face with no driving dimension: the face thickened outward by distance adds
  // stock to its body, or (negative) cut inward removes it. The face is found again on every
  // rebuild like converted sketch edges, so the feature follows earlier changes.
  void applyFaceOffset(Feature& f, int self) {
    double d = get(f.params, "distance");
    if (std::abs(d) < 1e-9) return;
    auto v3 = [&](const char* k) {
      const Json& a = f.params.at(k);
      return gp_XYZ(a.at(0).get<double>(), a.at(1).get<double>(), a.at(2).get<double>());
    };
    gp_Pnt probe(v3("probe"));
    gp_Dir want(v3("normal"));
    int b = 0;
    TopoDS_Face face;
    gp_Pnt at;
    gp_Dir n;
    if (!findFace(probe, want, f.params.value("feature", std::string()), b, face, at, n, f.params.value("role", std::string())))
      throw FeatureError("the face it pushes is no longer there");
    f.params["probe"] = {at.X(), at.Y(), at.Z()};
    f.params["normal"] = {n.X(), n.Y(), n.Z()};
    TopoDS_Shape tool;
    if (BRepAdaptor_Surface(face).GetType() == GeomAbs_Plane) {
      tool = BRepPrimAPI_MakePrism(face, gp_Vec(n) * d).Shape();
    } else {
      // Curved faces thicken along their own normals, so a cylinder grows round, not sideways.
      BRepOffset_MakeOffset mo;
      mo.Initialize(face, d, 1e-7, BRepOffset_Skin, false, false, GeomAbs_Arc, true);
      mo.MakeOffsetShape();
      if (!mo.IsDone()) throw FeatureError("that curved face cannot be pushed so far");
      tool = mo.Shape();
    }
    GProp_GProps props;
    BRepGProp::VolumeProperties(tool, props);
    if (props.Mass() < 0) tool.Reverse();  // an inside-out solid from a reversed face
    Feature g = f;
    g.op = d > 0 ? BodyOp::Add : BodyOp::Cut;
    g.body = b;
    applyBoolean(g, tool, self);
  }

  void refreshLinks(Sketch& sk) {
    for (auto& l : sk.links) {
      gp_Pnt probe(l.probe[0], l.probe[1], l.probe[2]);
      gp_Dir want(l.normal[0], l.normal[1], l.normal[2]);
      int body = 0;
      TopoDS_Face found;
      gp_Pnt at;
      gp_Dir n;
      if (!findFace(probe, want, l.feature, body, found, at, n)) continue;
      auto curves = projectFaceEdges(found, sk.plane);
      if (curves.empty()) continue;
      applyLink(sk, l, curves, false);
      l.probe = {at.X(), at.Y(), at.Z()};
      l.normal = {n.X(), n.Y(), n.Z()};
    }
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
    std::string end = p.value("end", std::string("blind"));
    bool symmetric = dirMode == "symmetric";
    gp_Vec dir(extrudeDir(st, p));
    bool upTo = end == "up_to_face";
    double depth = end == "through_all" || upTo ? throughAllLength(st) : positive(p, "depth");
    // Two directions: depth forward and depth2 the other way.
    double back = dirMode == "two" ? positive(p, "depth2") : 0.0;
    double offset = p.contains("offset") ? get(p, "offset") : 0.0;
    double shift = offset - (symmetric ? depth / 2 : 0.0) - back;
    if (std::abs(shift) > 1e-15) {
      gp_Trsf t;
      t.SetTranslation(dir * shift);
      prof = BRepBuilderAPI_Transform(prof, t, true).Shape();
    }
    TopoDS_Shape prism = BRepPrimAPI_MakePrism(prof, dir * (depth + back)).Shape();
    if (!upTo) return prism;
    // Up to face: run through everything, then keep what lies on the sketch's side of the face's
    // plane. Needs a flat face.
    if (!p.contains("face")) throw FeatureError("aim at the face to extrude up to");
    Json face = p.at("face");
    int b;
    TopoDS_Face fc;
    gp_Pnt at;
    gp_Dir n;
    if (!findFaceRef(face, b, fc, at, n))
      throw FeatureError("the face to extrude up to is gone");
    BRepAdaptor_Surface surf(fc);
    if (surf.GetType() != GeomAbs_Plane) throw FeatureError("up to face needs a flat face");
    gp_Pln pln = surf.Plane();
    gp_Pnt inside = sketchAxes(st.sketch.plane).Location();
    if (pln.Distance(inside) < 1e-9) throw FeatureError("the face is in the sketch's own plane");
    TopoDS_Face big = BRepBuilderAPI_MakeFace(pln).Face();
    TopoDS_Shape half = BRepPrimAPI_MakeHalfSpace(big, inside).Solid();
    BRepAlgoAPI_Common keep(prism, half);
    if (!keep.IsDone() || keep.HasErrors() || !hasSolid(keep.Shape())) throw FeatureError("the extrude doesn't reach that face");
    return keep.Shape();
  }

  TopoDS_Shape sketchRevolve(const Feature& f) const {
    const Json& p = f.params;
    const SketchState& st = sketchRef(p, "sketch");
    TopoDS_Shape prof = compoundOf(profileOf(st));
    const SketchPlane& pl = st.sketch.plane;
    std::string axis = p.value("axis", std::string("y"));
    Vec3d o, d;
    auto ref = refs.find(axis);
    if (ref != refs.end() && ref->second.kind == "axis") {
      const gp_Ax3& a = ref->second.frame;
      o = {a.Location().X(), a.Location().Y(), a.Location().Z()};
      d = {a.Direction().X(), a.Direction().Y(), a.Direction().Z()};
    } else if (axis == "x" || axis == "y") {
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

  // Imported shapes, parsed once per shape (an import can be large).
  mutable std::map<std::string, TopoDS_Shape> importCache;

  TopoDS_Shape importShape(const Feature& f) const {
    std::string id = f.params.value("shape", std::string());
    auto it = doc.imports.find(id);
    if (it == doc.imports.end()) throw FeatureError("the imported shape is missing from the file");
    std::string key = id + ":" + std::to_string(it->second.size());
    auto c = importCache.find(key);
    if (c == importCache.end()) {
      std::istringstream is(it->second, std::ios::binary);
      TopoDS_Shape s;
      BinTools::Read(s, is);
      if (s.IsNull()) throw FeatureError("the imported shape could not be read");
      c = importCache.emplace(key, s).first;
    }
    gp_Trsf t;
    t.SetTranslation(gp_Vec(get(f.params, "x"), get(f.params, "y"), get(f.params, "z")));
    return BRepBuilderAPI_Transform(c->second, t, true).Shape();
  }

  TopoDS_Shape toolShape(const Feature& f) const {
    if (f.type == "import") return importShape(f);
    if (f.type == "hole") return holeTool(f);
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
    std::vector<TopoDS_Face> faces;
    for (FaceTags::Iterator it(tags[b]); it.More(); it.Next()) {
      const std::string& t = owners[it.Value()];
      if (t.substr(0, t.find('#')) == target) faces.push_back(TopoDS::Face(it.Key()));
    }
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

  // The size of everything built so far: a scale for tolerances and "through" lengths.
  double modelSpan() const {
    Bnd_Box box;
    for (auto& b : bodies) BRepBndLib::Add(b, box);
    if (box.IsVoid()) return 1.0;
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    return std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0));
  }

  // The edge of any body nearest p: picks are stored as a point on the edge (its middle).
  bool findEdge(const gp_Pnt& p, int& body, TopoDS_Edge& edge, double& dist) const {
    dist = 1e300;
    TopoDS_Vertex v = BRepBuilderAPI_MakeVertex(p).Vertex();
    for (size_t b = 0; b < bodies.size(); ++b) {
      TopTools_IndexedMapOfShape edges;
      TopExp::MapShapes(bodies[b], TopAbs_EDGE, edges);
      for (int i = 1; i <= edges.Extent(); ++i) {
        const TopoDS_Edge& e = TopoDS::Edge(edges(i));
        if (BRep_Tool::Degenerated(e)) continue;
        BRepExtrema_DistShapeShape d(v, e);
        if (!d.IsDone() || d.NbSolution() == 0) continue;
        if (d.Value() < dist) {
          dist = d.Value();
          edge = e;
          body = static_cast<int>(b);
        }
      }
    }
    return !edge.IsNull();
  }

  void applyPickedEdges(const Feature& f, int self) {
    bool fillet = f.type == "fillet";
    double size = positive(f.params, fillet ? "r" : "d");
    double tol = std::max(1e-6, 0.02 * modelSpan());
    std::map<int, std::vector<TopoDS_Edge>> byBody;
    for (auto& pk : f.params.at("picks")) {
      int b;
      TopoDS_Edge e;
      double d;
      if (!findEdge(gp_Pnt(xyz(pk)), b, e, d) || d > tol) throw FeatureError("an edge you picked is no longer there");
      byBody[b].push_back(e);
    }
    if (byBody.empty()) throw FeatureError("pick at least one edge");
    for (auto& [b, edges] : byBody) {
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
  }

  // A hole's cutting tool: a drilled cylinder, with a counterbore or countersink at the top, going
  // into the material from point against the face's outward normal.
  TopoDS_Shape holeTool(const Feature& f) const {
    const Json& p = f.params;
    gp_Pnt at(xyz(p.at("point")));
    gp_Dir out(xyz(p.at("normal")));
    gp_Dir in = out.Reversed();
    double d = positive(p, "d");
    std::string kind = p.value("kind", std::string("simple"));
    bool through = p.value("end", std::string("blind")) == "through_all";
    double depth = through ? 2.0 * modelSpan() + 1.0 : positive(p, "depth");
    double lead = std::max(1e-6, d * 0.02);  // start a little above the face so the cut is clean
    gp_Pnt start = at.Translated(gp_Vec(out) * lead);
    gp_Ax2 ax(start, in);
    TopoDS_Shape tool = BRepPrimAPI_MakeCylinder(ax, d / 2, depth + lead).Shape();
    if (kind == "counterbore") {
      double cd = positive(p, "cbore_d"), ch = positive(p, "cbore_depth");
      if (cd <= d) throw FeatureError("the counterbore must be wider than the hole");
      tool = BRepAlgoAPI_Fuse(tool, BRepPrimAPI_MakeCylinder(ax, cd / 2, ch + lead).Shape()).Shape();
    } else if (kind == "countersink") {
      double cd = positive(p, "csink_d");
      double angle = p.contains("csink_angle") ? get(p, "csink_angle", Quantity::Angle) : 90.0 * kPi / 180.0;
      if (cd <= d) throw FeatureError("the countersink must be wider than the hole");
      if (!(angle > 0.1 && angle < kPi - 0.1)) throw FeatureError("the countersink angle must be between 6 and 174 degrees");
      double h = (cd - d) / 2 / std::tan(angle / 2);
      double r0 = cd / 2 + lead * std::tan(angle / 2);  // the cone, widened to start above the face
      tool = BRepAlgoAPI_Fuse(tool, BRepPrimAPI_MakeCone(ax, r0, d / 2, h + lead).Shape()).Shape();
    }
    return tool;
  }

  // Shell: hollows the body holding the picked faces to wall thickness t, leaving those faces
  // open; with no faces, hollows it closed.
  void applyShell(Feature& f, int self) {
    double t = positive(f.params, "t");
    if (!f.params.contains("faces")) f.params["faces"] = Json::array();
    Json& faces = f.params["faces"];
    int body = -1;
    TopTools_ListOfShape open;
    for (auto& fr : faces) {
      int b;
      TopoDS_Face fc;
      gp_Pnt at;
      gp_Dir n;
      if (!findFaceRef(fr, b, fc, at, n))
        throw FeatureError("a face you picked is no longer there");
      if (body >= 0 && b != body) throw FeatureError("the open faces must all be on one body");
      body = b;
      open.Append(fc);
    }
    if (bodies.empty()) throw FeatureError("there is no body to shell");
    if (body < 0) body = std::clamp(f.body, 0, static_cast<int>(bodies.size()) - 1);
    BRepOffsetAPI_MakeThickSolid mk;
    mk.MakeThickSolidByJoin(bodies[body], open, -t, 1e-6);
    mk.Build();
    if (!mk.IsDone() || !hasSolid(mk.Shape())) throw FeatureError("shell failed: the wall may be too thick for the part");
    TopoDS_Shape result = mk.Shape();
    tags[body] = remap(mk, tags[body], result, self);
    bodies[body] = result;
  }

  // ---- 0.5: patterns, mirror, draft, body tools ----

  // The features a pattern or mirror repeats, checked to come before it and to make a shape.
  std::vector<const Feature*> sourceFeatures(const Feature& f) const {
    std::vector<const Feature*> out;
    if (!f.params.contains("features")) return out;
    size_t self = doc.features.size();
    for (size_t i = 0; i < doc.features.size(); ++i)
      if (doc.features[i].id == f.id) self = i;
    for (auto& idj : f.params.at("features")) {
      std::string id = idj.get<std::string>();
      size_t at = doc.features.size();
      for (size_t i = 0; i < doc.features.size(); ++i)
        if (doc.features[i].id == id) at = i;
      if (at == doc.features.size()) throw FeatureError("a feature it repeats no longer exists");
      const Feature& src = doc.features[at];
      if (at > self) throw FeatureError(src.name + " must come before this feature");
      if (src.suppressed) continue;
      static const std::set<std::string> shaped = {"box", "cylinder", "sphere", "cone", "extrude", "revolve",
                                                   "sweep", "loft", "hole", "import"};
      if (!shaped.count(src.type)) throw FeatureError(src.name + " cannot be repeated: only features that add or cut a shape can");
      out.push_back(&src);
    }
    return out;
  }

  // Applies each source feature again, once per transform, as one boolean per source.
  void repeatFeatures(const std::vector<const Feature*>& srcs, const std::vector<gp_Trsf>& moves, int self) {
    for (const Feature* src : srcs) {
      TopoDS_Shape tool = toolShape(*src);
      if (src->op == BodyOp::NewBody) {
        for (auto& t : moves) applyBoolean(*src, BRepBuilderAPI_Transform(tool, t, true).Shape(), self);
        continue;
      }
      BRep_Builder bb;
      TopoDS_Compound c;
      bb.MakeCompound(c);
      for (auto& t : moves) bb.Add(c, BRepBuilderAPI_Transform(tool, t, true).Shape());
      TopoDS_Shape all = c;
      if (moves.size() > 1 && src->op == BodyOp::Add) {
        // Overlapping copies fuse into one tool first, so the body gets a single clean boolean.
        TopExp_Explorer ex(c, TopAbs_SOLID);
        if (ex.More()) {
          TopoDS_Shape acc = ex.Current();
          for (ex.Next(); ex.More(); ex.Next()) acc = BRepAlgoAPI_Fuse(acc, ex.Current()).Shape();
          all = acc;
        }
      }
      applyBoolean(*src, all, self);
    }
  }

  void applyPattern(Feature& f, int self) {
    Json& p = f.params;
    auto srcs = sourceFeatures(f);
    if (srcs.empty()) throw FeatureError("pick the features to repeat");
    int count = static_cast<int>(std::lround(get(p, "count", Quantity::Count)));
    if (count < 1 || count > 1000) throw FeatureError("the count must be between 1 and 1000");
    std::vector<gp_Trsf> moves;
    std::string kind = p.value("kind", std::string("linear"));
    if (kind == "linear") {
      gp_Ax1 a = axisRef(p["dir"], nullptr);
      gp_Vec d1(a.Direction());
      if (p.value("flip", false)) d1.Reverse();
      double s1 = get(p, "spacing");
      int count2 = p.contains("count2") ? static_cast<int>(std::lround(get(p, "count2", Quantity::Count))) : 1;
      if (count2 < 1 || count * count2 > 1000) throw FeatureError("the pattern can have at most 1000 copies");
      gp_Vec d2;
      double s2 = 0;
      if (count2 > 1) {
        gp_Ax1 b = axisRef(p["dir2"], nullptr);
        d2 = gp_Vec(b.Direction());
        if (p.value("flip2", false)) d2.Reverse();
        if (d2.IsParallel(d1, 1e-6)) throw FeatureError("the two directions must differ");
        s2 = get(p, "spacing2");
      }
      for (int j = 0; j < count2; ++j)
        for (int i = 0; i < count; ++i) {
          if (i == 0 && j == 0) continue;
          gp_Trsf t;
          t.SetTranslation(d1 * (s1 * i) + d2 * (s2 * j));
          moves.push_back(t);
        }
    } else if (kind == "circular") {
      gp_Ax1 ax = axisRef(p["axis"], nullptr);
      double total = p.contains("angle") ? get(p, "angle", Quantity::Angle) : 2 * M_PI;
      if (std::abs(total) < 1e-9) throw FeatureError("the angle must not be zero");
      bool full = std::abs(std::abs(total) - 2 * M_PI) < 1e-9;
      double step = full ? total / count : (count > 1 ? total / (count - 1) : 0);
      for (int i = 1; i < count; ++i) {
        gp_Trsf t;
        t.SetRotation(ax, step * i);
        moves.push_back(t);
      }
    } else {
      throw FeatureError("unknown pattern kind '" + kind + "'");
    }
    if (moves.empty()) return;  // one copy: the original
    repeatFeatures(srcs, moves, self);
  }

  void applyMirror(Feature& f, int self) {
    Json& p = f.params;
    gp_Ax3 pl = planeRef(p["plane"], nullptr);
    gp_Trsf t;
    t.SetMirror(gp_Ax2(pl.Location(), pl.Direction()));
    auto srcs = sourceFeatures(f);
    if (!srcs.empty()) {
      repeatFeatures(srcs, {t}, self);
      return;
    }
    // No features picked: the whole part is mirrored and joined to itself, body by body.
    if (bodies.empty()) throw FeatureError("there is nothing to mirror yet");
    for (size_t b = 0; b < bodies.size(); ++b) {
      TopoDS_Shape m = BRepBuilderAPI_Transform(bodies[b], t, true).Shape();
      FaceTags mt;
      tagAll(m, self, mt);
      for (FaceTags::Iterator it(tags[b]); it.More(); it.Next()) mt.Bind(it.Key(), it.Value());
      BRepAlgoAPI_Fuse op(bodies[b], m);
      if (!op.IsDone() || op.HasErrors()) throw FeatureError("joining the mirror image failed");
      TopoDS_Shape r = op.Shape();
      tags[b] = remap(op, mt, r, self);
      bodies[b] = r;
    }
  }

  // A body found from a face reference {probe, normal, feature}: the body that face is on.
  int bodyRef(Json& r) const {
    int b = 0;
    TopoDS_Face f;
    gp_Pnt at;
    gp_Dir n;
    if (!findFaceRef(r, b, f, at, n))
      throw FeatureError("a body it uses is no longer there");
    r["probe"] = {at.X(), at.Y(), at.Z()};
    r["normal"] = {n.X(), n.Y(), n.Z()};
    return b;
  }

  void applyDraft(Feature& f, int self) {
    Json& p = f.params;
    double angle = get(p, "angle", Quantity::Angle);
    if (std::abs(angle) < 1e-9 || std::abs(angle) >= M_PI / 2) throw FeatureError("the draft angle must be between 0° and 90°");
    gp_Ax3 neutral = facePlane(p["neutral"], nullptr);
    // Pulled away from the neutral face, into the part: the drafted faces narrow away from it, as
    // a part drawn out of a mould does.
    gp_Dir pull = neutral.Direction().Reversed();
    if (!p.contains("faces") || p.at("faces").empty()) throw FeatureError("pick the faces to draft");
    int body = -1;
    std::vector<TopoDS_Face> faces;
    for (auto& fr : p["faces"]) {
      int b = 0;
      TopoDS_Face face;
      gp_Pnt at;
      gp_Dir n;
      if (!findFaceRef(fr, b, face, at, n))
        throw FeatureError("a face to draft is no longer there");
      if (body >= 0 && b != body) throw FeatureError("the faces to draft must be on one body");
      body = b;
      fr["probe"] = {at.X(), at.Y(), at.Z()};
      fr["normal"] = {n.X(), n.Y(), n.Z()};
      faces.push_back(face);
    }
    BRepOffsetAPI_DraftAngle mk(bodies[body]);
    gp_Pln np(neutral.Location(), neutral.Direction());
    for (auto& face : faces) {
      mk.Add(face, pull, angle, np);
      if (!mk.AddDone()) throw FeatureError("a picked face cannot be drafted from that neutral plane (it must not be parallel to it)");
    }
    mk.Build();
    if (!mk.IsDone()) throw FeatureError("the draft failed");
    TopoDS_Shape r = mk.Shape();
    tags[body] = remap(mk, tags[body], r, self);
    bodies[body] = r;
  }

  void applyBodyTool(Feature& f, int self) {
    Json& p = f.params;
    std::string kind = p.value("kind", std::string());
    if (bodies.empty()) throw FeatureError("there are no bodies yet");
    int target = bodyRef(p["target"]);
    if (kind == "delete") {
      bodies.erase(bodies.begin() + target);
      tags.erase(tags.begin() + target);
      return;
    }
    if (kind == "split") {
      gp_Ax3 pl = planeRef(p["plane"], nullptr);
      gp_Pnt o = pl.Location();
      gp_Vec n(pl.Direction());
      TopoDS_Face big = BRepBuilderAPI_MakeFace(gp_Pln(o, pl.Direction())).Face();
      TopoDS_Shape above = BRepPrimAPI_MakeHalfSpace(big, o.Translated(n)).Solid();
      TopoDS_Shape below = BRepPrimAPI_MakeHalfSpace(big, o.Translated(-n)).Solid();
      BRepAlgoAPI_Common a(bodies[target], above), c(bodies[target], below);
      if (!a.IsDone() || !c.IsDone() || a.HasErrors() || c.HasErrors()) throw FeatureError("the split failed");
      TopoDS_Shape ra = a.Shape(), rc = c.Shape();
      if (!hasSolid(ra) || !hasSolid(rc)) throw FeatureError("the plane does not cut through that body");
      FaceTags ta = remap(a, tags[target], ra, self), tc = remap(c, tags[target], rc, self);
      bodies[target] = ra;
      tags[target] = ta;
      bodies.insert(bodies.begin() + target + 1, rc);
      tags.insert(tags.begin() + target + 1, tc);
      return;
    }
    if (!p.contains("tools") || p.at("tools").empty()) throw FeatureError("pick the bodies to " + kind + " with");
    std::vector<int> tools;
    for (auto& t : p["tools"]) {
      int b = bodyRef(t);
      if (b == target) throw FeatureError("a body cannot be combined with itself");
      if (std::find(tools.begin(), tools.end(), b) == tools.end()) tools.push_back(b);
    }
    bool keep = p.value("keep", false);
    TopoDS_Shape acc = bodies[target];
    FaceTags accTags = tags[target];
    for (int b : tools) {
      FaceTags merged = accTags;
      for (FaceTags::Iterator it(tags[b]); it.More(); it.Next()) merged.Bind(it.Key(), it.Value());
      std::unique_ptr<BRepAlgoAPI_BooleanOperation> op;
      if (kind == "combine") op = std::make_unique<BRepAlgoAPI_Fuse>(acc, bodies[b]);
      else if (kind == "subtract") op = std::make_unique<BRepAlgoAPI_Cut>(acc, bodies[b]);
      else if (kind == "intersect") op = std::make_unique<BRepAlgoAPI_Common>(acc, bodies[b]);
      else throw FeatureError("unknown body tool '" + kind + "'");
      if (!op->IsDone() || op->HasErrors()) throw FeatureError(kind + " failed");
      TopoDS_Shape r = op->Shape();
      if (!hasSolid(r)) throw FeatureError(kind + " leaves nothing of the body");
      accTags = remap(*op, merged, r, self);
      acc = r;
    }
    bodies[target] = acc;
    tags[target] = accTags;
    if (!keep || kind == "combine") {
      std::sort(tools.rbegin(), tools.rend());
      for (int b : tools) {
        bodies.erase(bodies.begin() + b);
        tags.erase(tags.begin() + b);
      }
    }
  }

  void applyEdgeFeature(const Feature& f, int self) {
    if (f.params.contains("picks")) return applyPickedEdges(f, self);
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

  // A face's role within the feature that made it: "start" / "end" caps and "side<k>" (the k-th
  // profile edge) for an extrude from a sketch; for other shapes the axis a flat face looks
  // along ("p+z") or the kind of curved face ("cyl"). Empty when there is nothing stable to say.
  std::string faceRole(const Feature& f, const TopoDS_Face& face, const std::vector<TopoDS_Edge>* profileEdges,
                       const gp_Ax3* sketchAx, const gp_Dir* dir) const {
    BRepAdaptor_Surface sa(face);
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    gp_Dir nn = outwardNormal(face, (u0 + u1) / 2, (v0 + v1) / 2);
    if (profileEdges && sketchAx && dir) {
      if (sa.GetType() == GeomAbs_Plane && std::abs(nn.Dot(*dir)) > 0.999) return nn.Dot(*dir) < 0 ? "start" : "end";
      gp_Pnt c = sa.Value((u0 + u1) / 2, (v0 + v1) / 2);
      gp_Vec N(sketchAx->Direction()), d(*dir);
      double den = d.Dot(N);
      if (std::abs(den) < 1e-12) return {};
      double t = gp_Vec(sketchAx->Location(), c).Dot(N) / den;
      gp_Pnt q = c.Translated(-d * t);
      TopoDS_Vertex v = BRepBuilderAPI_MakeVertex(q).Vertex();
      double best = 1e300;
      int k = -1;
      for (size_t i = 0; i < profileEdges->size(); ++i) {
        BRepExtrema_DistShapeShape dist(v, (*profileEdges)[i]);
        if (dist.IsDone() && dist.Value() < best) {
          best = dist.Value();
          k = static_cast<int>(i);
        }
      }
      return k < 0 ? std::string() : "side" + std::to_string(k);
    }
    (void)f;
    switch (sa.GetType()) {
      case GeomAbs_Plane: {
        const char* axes[] = {"x", "y", "z"};
        double c[] = {nn.X(), nn.Y(), nn.Z()};
        for (int i = 0; i < 3; ++i)
          if (std::abs(c[i]) > 0.9999) return std::string("p") + (c[i] > 0 ? "+" : "-") + axes[i];
        return {};
      }
      case GeomAbs_Cylinder: return "cyl";
      case GeomAbs_Cone: return "cone";
      case GeomAbs_Sphere: return "sphere";
      default: return {};
    }
  }

  // Tags a new tool shape's faces with its feature and each face's role.
  FaceTags roleTags(const Feature& f, const TopoDS_Shape& tool, int self) {
    FaceTags t;
    std::vector<TopoDS_Edge> edges;
    gp_Ax3 ax;
    gp_Dir dir;
    bool sketched = false;
    if (f.type == "extrude" && f.params.contains("sketch")) {
      try {
        const SketchState& st = sketchRef(f.params, "sketch");
        ax = sketchAxes(st.sketch.plane);
        dir = extrudeDir(st, f.params);
        for (auto& pf : profileOf(st))
          for (TopExp_Explorer e(pf, TopAbs_EDGE); e.More(); e.Next()) edges.push_back(TopoDS::Edge(e.Current()));
        sketched = !edges.empty();
      } catch (const std::exception&) {
        sketched = false;
      }
    }
    for (TopExp_Explorer e(tool, TopAbs_FACE); e.More(); e.Next()) {
      if (t.IsBound(e.Current())) continue;
      std::string r;
      try {
        r = faceRole(f, TopoDS::Face(e.Current()), sketched ? &edges : nullptr, sketched ? &ax : nullptr, sketched ? &dir : nullptr);
      } catch (const Standard_Failure&) {
        r.clear();
      }
      t.Bind(e.Current(), r.empty() ? self : ownerIndex(f.id + "#" + r));
    }
    return t;
  }

  void applyBoolean(const Feature& f, const TopoDS_Shape& tool, int self) {
    FaceTags toolTags = roleTags(f, tool, self);
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
    refs.clear();
    evaluateVariables(r);
    for (size_t fi = 0; fi < doc.features.size(); ++fi) {
      Feature& f = doc.features[fi];
      FeatureStatus st{f.id, true, {}};
      if (doc.rollback >= 0 && static_cast<int>(fi) >= doc.rollback) {
        st.message = "below the rollback bar";
        st.rolledBack = true;
        r.features.push_back(st);
        continue;
      }
      if (f.suppressed) {
        st.message = "suppressed";
        r.features.push_back(st);
        continue;
      }
      try {
        int self = ownerIndex(f.id);
        if (f.type == "sketch") processSketch(f);
        else if (f.type == "face_offset") applyFaceOffset(f, self);
        else if (f.type == "plane" || f.type == "axis" || f.type == "point" || f.type == "csys") applyReference(f);
        else if (f.type == "fillet" || f.type == "chamfer") applyEdgeFeature(f, self);
        else if (f.type == "shell") applyShell(f, self);
        else if (f.type == "pattern") applyPattern(f, self);
        else if (f.type == "mirror") applyMirror(f, self);
        else if (f.type == "draft") applyDraft(f, self);
        else if (f.type == "body") applyBodyTool(f, self);
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
    buildSection();
    r.milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    report = r;
    return r;
  }

  // Tags are "featureId" or "featureId#role"; the role names the face within its feature (an
  // extrude's end caps and sides, a box's six faces) so references survive upstream edits.
  std::string tagOf(int b, const TopoDS_Shape& face) const {
    if (b < 0 || b >= static_cast<int>(tags.size()) || !tags[b].IsBound(face)) return {};
    return owners[tags[b].Find(face)];
  }
  std::string ownerOf(int b, const TopoDS_Shape& face) const {
    std::string t = tagOf(b, face);
    return t.substr(0, t.find('#'));
  }
  std::string roleOf(int b, const TopoDS_Shape& face) const {
    std::string t = tagOf(b, face);
    size_t h = t.find('#');
    return h == std::string::npos ? std::string() : t.substr(h + 1);
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

void PartModel::setSection(const std::optional<std::pair<Vec3, Vec3>>& plane) {
  if (plane) {
    gp_Vec n(plane->second[0], plane->second[1], plane->second[2]);
    if (n.Magnitude() < 1e-12) return;
    d_->section = gp_Pln(gp_Pnt(plane->first[0], plane->first[1], plane->first[2]), gp_Dir(n));
  } else {
    d_->section.reset();
  }
  d_->buildSection();
}

bool PartModel::hasSection() const { return d_->section.has_value(); }

PartModel::FaceMeasure PartModel::resolveFace(const Json& ref) const {
  FaceMeasure m;
  try {
    Json r = ref;
    int b = 0;
    TopoDS_Face f;
    gp_Pnt at;
    gp_Dir n;
    if (!d_->findFaceRef(r, b, f, at, n)) return m;
    int fi = d_->faceIndex[static_cast<size_t>(b)].FindIndex(f) - 1;
    m = faceMeasure(b, fi);
    if (m.ok && m.kind == "plane") {
      m.centre = {at.X(), at.Y(), at.Z()};
      m.normal = {n.X(), n.Y(), n.Z()};
    }
  } catch (const std::exception&) {
    m.ok = false;
  } catch (const Standard_Failure&) {
    m.ok = false;
  }
  return m;
}

PartModel::FaceMeasure PartModel::faceMeasure(int b, int fi) const {
  FaceMeasure m;
  if (b < 0 || b >= bodyCount() || fi < 0 || fi >= d_->faceIndex[static_cast<size_t>(b)].Extent()) return m;
  TopoDS_Face face = TopoDS::Face(d_->faceIndex[static_cast<size_t>(b)](fi + 1));
  GProp_GProps g;
  BRepGProp::SurfaceProperties(face, g);
  m.area = g.Mass();
  gp_Pnt c = g.CentreOfMass();
  m.centre = {c.X(), c.Y(), c.Z()};
  BRepAdaptor_Surface sa(face);
  m.kind = surfaceKind(face);
  auto put = [](Vec3& v, const gp_XYZ& x) { v = {x.X(), x.Y(), x.Z()}; };
  switch (sa.GetType()) {
    case GeomAbs_Plane: {
      double u0, u1, v0, v1;
      BRepTools::UVBounds(face, u0, u1, v0, v1);
      put(m.normal, outwardNormal(face, (u0 + u1) / 2, (v0 + v1) / 2).XYZ());
      break;
    }
    case GeomAbs_Cylinder:
      m.radius = sa.Cylinder().Radius();
      put(m.axis, sa.Cylinder().Axis().Direction().XYZ());
      put(m.centre, sa.Cylinder().Location().XYZ());
      break;
    case GeomAbs_Sphere:
      m.radius = sa.Sphere().Radius();
      put(m.centre, sa.Sphere().Location().XYZ());
      break;
    case GeomAbs_Torus:
      m.radius = sa.Torus().MinorRadius();
      m.radius2 = sa.Torus().MajorRadius();
      put(m.axis, sa.Torus().Axis().Direction().XYZ());
      put(m.centre, sa.Torus().Location().XYZ());
      break;
    case GeomAbs_Cone: {
      put(m.axis, sa.Cone().Axis().Direction().XYZ());
      put(m.centre, sa.Cone().Location().XYZ());
      double u0, u1, v0, v1;
      BRepTools::UVBounds(face, u0, u1, v0, v1);
      gp_Pnt mid = sa.Value((u0 + u1) / 2, (v0 + v1) / 2);
      m.radius = gp_Lin(sa.Cone().Axis()).Distance(mid);
      break;
    }
    default:
      break;
  }
  m.ok = true;
  return m;
}

std::vector<PartModel::Interference> PartModel::interference() const {
  std::vector<Interference> out;
  const auto& bs = d_->bodies;
  std::vector<Bnd_Box> boxes(bs.size());
  for (size_t i = 0; i < bs.size(); ++i) BRepBndLib::Add(bs[i], boxes[i]);
  for (size_t i = 0; i < bs.size(); ++i)
    for (size_t j = i + 1; j < bs.size(); ++j) {
      if (boxes[i].IsOut(boxes[j])) continue;
      BRepAlgoAPI_Common op(bs[i], bs[j]);
      if (!op.IsDone() || op.HasErrors()) continue;
      GProp_GProps g;
      BRepGProp::VolumeProperties(op.Shape(), g);
      if (g.Mass() < 1e-15) continue;
      Interference x;
      x.a = static_cast<int>(i);
      x.b = static_cast<int>(j);
      x.volume = g.Mass();
      gp_Pnt c = g.CentreOfMass();
      x.centre = {c.X(), c.Y(), c.Z()};
      out.push_back(x);
    }
  return out;
}

std::string PartModel::faceRole(int body, int face) const {
  if (body < 0 || body >= static_cast<int>(d_->faceIndex.size())) return {};
  if (face < 0 || face >= d_->faceIndex[static_cast<size_t>(body)].Extent()) return {};
  return d_->roleOf(body, d_->faceIndex[static_cast<size_t>(body)](face + 1));
}
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
  const size_t sb = static_cast<size_t>(b);
  const bool cut = d_->sectioned(sb);
  const ShapeIndex& faces = d_->faceIndex.at(sb);
  // The original faces keep their indices; in a section view the cut face is one more, last.
  out.faces.resize(static_cast<size_t>(faces.Extent()) + (cut ? 1 : 0));
  for (int fi = 1; fi <= faces.Extent(); ++fi) {
    TopoDS_Face face = TopoDS::Face(faces(fi));
    FaceInfo& info = out.faces[static_cast<size_t>(fi - 1)];
    info.featureId = d_->ownerOf(b, face);
    info.kind = surfaceKind(face);
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    gp_Dir n = outwardNormal(face, 0.5 * (u0 + u1), 0.5 * (v0 + v1));
    info.normal = {n.X(), n.Y(), n.Z()};
  }
  if (cut) {
    FaceInfo& cap = out.faces.back();
    cap.kind = "section";
    gp_Dir n = d_->section->Axis().Direction();
    cap.normal = {n.X(), n.Y(), n.Z()};
  }
  const TopoDS_Shape& shape = cut ? d_->sectBodies[sb] : body(b);
  if (shape.IsNull()) return out;
  BRepMesh_IncrementalMesh mesher(shape, defl, false, ang, true);
  const ShapeIndex& shown = cut ? d_->sectFaces[sb] : faces;
  for (int si = 1; si <= shown.Extent(); ++si) {
    TopoDS_Face face = TopoDS::Face(shown(si));
    int fi = si;
    if (cut) {
      int o = d_->sectOrig[sb][static_cast<size_t>(si - 1)];
      fi = o < 0 ? faces.Extent() + 1 : o + 1;
    }

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
    const bool cut = d_->sectioned(b);
    if (cut && d_->sectBodies[b].IsNull()) continue;
    auto& pk = d_->pickers[b];
    if (!pk) {
      pk = std::make_unique<IntCurvesFace_ShapeIntersector>();
      pk->Load(cut ? d_->sectBodies[b] : d_->bodies[b], 1e-7);
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
    if (cut) {
      int si = d_->sectFaces[b].FindIndex(face);
      h.face = si > 0 ? d_->sectOrig[b][static_cast<size_t>(si - 1)] : -1;
      if (h.face >= 0) h.featureId = d_->ownerOf(static_cast<int>(b), d_->faceIndex[b](h.face + 1));
    } else {
      h.face = d_->faceIndex[b].FindIndex(face) - 1;
      h.featureId = d_->ownerOf(static_cast<int>(b), face);
    }
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
  if (f->type == "face_offset") {
    // The pushed face itself drives the distance (outward positive); its sides drive nothing.
    try {
      const Json& nv = f->params.at("normal");
      gp_Dir want(nv.at(0).get<double>(), nv.at(1).get<double>(), nv.at(2).get<double>());
      if (gp_Dir(hit.normal[0], hit.normal[1], hit.normal[2]).Dot(want) < 0.9) return std::nullopt;
      FaceDrive fd;
      fd.featureId = f->id;
      fd.param = "distance";
      fd.label = "pushed face · distance";
      fd.value = d_->get(f->params, "distance");
      return fd;
    } catch (...) {
      return std::nullopt;
    }
  }
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
  if (!fd) return offsetFace(hit, delta, message);
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
    else if (t == "distance") {
      p["distance"] = d_->get(p, "distance") + delta;  // through zero it turns from adding to removing
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

std::vector<ReferenceView> PartModel::referenceViews() const {
  std::vector<ReferenceView> out;
  auto v3 = [](const gp_XYZ& v) { return Vec3{v.X(), v.Y(), v.Z()}; };
  for (auto& f : d_->doc.features) {
    if (f.suppressed || (f.type != "plane" && f.type != "axis" && f.type != "point" && f.type != "csys")) continue;
    ReferenceView v;
    v.featureId = f.id;
    v.name = f.name;
    v.kind = f.type;
    auto it = d_->refs.find(f.id);
    if (it == d_->refs.end()) {
      v.ok = false;
      for (auto& st : d_->report.features)
        if (st.featureId == f.id) v.message = st.message;
      out.push_back(v);
      continue;
    }
    const gp_Ax3& a = it->second.frame;
    v.origin = v3(a.Location().XYZ());
    v.normal = v3(a.Direction().XYZ());
    v.xdir = v3(f.type == "axis" ? a.Direction().XYZ() : a.XDirection().XYZ());
    v.ydir = v3(a.YDirection().XYZ());
    v.size = it->second.size;
    out.push_back(v);
  }
  return out;
}

std::optional<SketchPlane> PartModel::referencePlane(const std::string& id) const {
  auto it = d_->refs.find(id);
  if (it == d_->refs.end() || (it->second.kind != "plane" && it->second.kind != "csys")) return std::nullopt;
  const gp_Ax3& a = it->second.frame;
  SketchPlane p;
  p.origin = {a.Location().X(), a.Location().Y(), a.Location().Z()};
  p.normal = {a.Direction().X(), a.Direction().Y(), a.Direction().Z()};
  p.xdir = {a.XDirection().X(), a.XDirection().Y(), a.XDirection().Z()};
  return p;
}

std::optional<std::array<Vec3, 2>> PartModel::straightEdgeNear(const PickHit& hit, double tolerance) const {
  if (hit.body < 0 || hit.body >= bodyCount()) return std::nullopt;
  const ShapeIndex& faces = d_->faceIndex[static_cast<size_t>(hit.body)];
  if (hit.face < 0 || hit.face >= faces.Extent()) return std::nullopt;
  gp_Pnt p(hit.point[0], hit.point[1], hit.point[2]);
  double best = tolerance;
  std::optional<std::array<Vec3, 2>> out;
  for (TopExp_Explorer ex(faces(hit.face + 1), TopAbs_EDGE); ex.More(); ex.Next()) {
    const TopoDS_Edge& e = TopoDS::Edge(ex.Current());
    if (BRep_Tool::Degenerated(e)) continue;
    BRepAdaptor_Curve c(e);
    if (c.GetType() != GeomAbs_Line) continue;
    BRepExtrema_DistShapeShape d(BRepBuilderAPI_MakeVertex(p).Vertex(), e);
    if (!d.IsDone() || d.NbSolution() < 1 || d.Value() > best) continue;
    best = d.Value();
    gp_Pnt a = c.Value(c.FirstParameter()), b = c.Value(c.LastParameter());
    out = std::array<Vec3, 2>{Vec3{a.X(), a.Y(), a.Z()}, Vec3{b.X(), b.Y(), b.Z()}};
  }
  return out;
}

bool PartModel::isCylinder(const PickHit& hit) const {
  if (hit.body < 0 || hit.body >= bodyCount()) return false;
  const ShapeIndex& faces = d_->faceIndex[static_cast<size_t>(hit.body)];
  if (hit.face < 0 || hit.face >= faces.Extent()) return false;
  return BRepAdaptor_Surface(TopoDS::Face(faces(hit.face + 1))).GetType() == GeomAbs_Cylinder;
}

std::optional<BoundingBox> PartModel::boundingBox() const {
  Bnd_Box b;
  for (auto& s : d_->bodies) BRepBndLib::AddOptimal(s, b, false, false);
  if (b.IsVoid()) return std::nullopt;
  BoundingBox out;
  b.Get(out.min[0], out.min[1], out.min[2], out.max[0], out.max[1], out.max[2]);
  return out;
}

std::optional<PartModel::EdgeInfo> PartModel::edgeNear(const Vec3& point, double maxDistance) const {
  int b;
  TopoDS_Edge e;
  double dist;
  if (!d_->findEdge(gp_Pnt(point[0], point[1], point[2]), b, e, dist) || dist > maxDistance) return std::nullopt;
  EdgeInfo info;
  info.body = b;
  BRepAdaptor_Curve c(e);
  double u0 = c.FirstParameter(), u1 = c.LastParameter();
  info.length = GCPnts_AbscissaPoint::Length(c);
  GCPnts_AbscissaPoint half(c, info.length / 2, u0);
  gp_Pnt m = c.Value(half.IsDone() ? half.Parameter() : (u0 + u1) / 2);
  info.mid = {m.X(), m.Y(), m.Z()};
  const int n = c.GetType() == GeomAbs_Line ? 2 : 33;
  for (int i = 0; i < n; ++i) {
    gp_Pnt q = c.Value(u0 + (u1 - u0) * i / (n - 1));
    info.points.push_back({q.X(), q.Y(), q.Z()});
  }
  if (c.GetType() == GeomAbs_Circle) info.radius = c.Circle().Radius();
  return info;
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

std::vector<PartModel::ProjectedCurve> PartModel::projectFace(int b, int face, const SketchPlane& plane) const {
  if (b < 0 || b >= bodyCount()) return {};
  const ShapeIndex& faces = d_->faceIndex[static_cast<size_t>(b)];
  if (face < 0 || face >= faces.Extent()) return {};
  return projectFaceEdges(TopoDS::Face(faces(face + 1)), plane);
}

bool PartModel::offsetFace(const PickHit& hit, double delta, std::string* message) {
  auto say = [&](const std::string& m) { if (message) *message = m; };
  if (hit.body < 0 || hit.body >= bodyCount()) { say("aim at a face of a part"); return false; }
  const PartDocument backup = d_->doc;
  const bool wasOk = d_->report.ok;
  gp_Pnt at(hit.point[0], hit.point[1], hit.point[2]);
  gp_Dir n(hit.normal[0], hit.normal[1], hit.normal[2]);
  double scale = std::max({1.0, std::abs(at.X()), std::abs(at.Y()), std::abs(at.Z())});
  // Holding the button keeps pushing the same spot: grow that push rather than stacking another.
  Feature* f = nullptr;
  for (auto& g : d_->doc.features) {
    if (g.type != "face_offset" || g.suppressed || g.params.value("feature", std::string()) != hit.featureId) continue;
    try {
      const Json& pr = g.params.at("probe");
      const Json& nv = g.params.at("normal");
      gp_Pnt q(pr.at(0).get<double>(), pr.at(1).get<double>(), pr.at(2).get<double>());
      gp_Dir m(nv.at(0).get<double>(), nv.at(1).get<double>(), nv.at(2).get<double>());
      if (q.Distance(at) < 1e-6 * scale && m.Dot(n) > 0.999) f = &g;
    } catch (...) {
    }
  }
  std::string name;
  if (f) {
    f->params["distance"] = d_->get(f->params, "distance") + delta;
    name = f->name;
  } else {
    Feature g;
    g.type = "face_offset";
    g.name = d_->doc.uniqueName("Push/Pull");
    g.params = {{"probe", {at.X(), at.Y(), at.Z()}}, {"normal", {n.X(), n.Y(), n.Z()}},
                {"feature", hit.featureId}, {"distance", delta}};
    std::string role = faceRole(hit.body, hit.face);
    if (!role.empty()) g.params["role"] = role;
    name = d_->doc.insert(g).name;
  }
  RebuildReport r = rebuild();
  if (wasOk && !r.ok) {
    std::string why;
    for (auto& st : r.features) if (!st.ok) { why = st.message; break; }
    d_->doc = backup;
    rebuild();
    say("that change would break the model" + (why.empty() ? std::string() : ": " + why));
    return false;
  }
  say(name + (delta > 0 ? " · stock added" : " · stock removed"));
  return true;
}

bool PartModel::convertFace(Sketch& s, int b, int face, const Vec3& probe, std::string* message) {
  auto fail = [&](const char* m) {
    if (message) *message = m;
    return false;
  };
  if (b < 0 || b >= bodyCount()) return fail("no such body");
  const ShapeIndex& faces = d_->faceIndex[static_cast<size_t>(b)];
  if (face < 0 || face >= faces.Extent()) return fail("no such face");
  const TopoDS_Face& f = TopoDS::Face(faces(face + 1));
  auto curves = projectFaceEdges(f, s.plane);
  if (curves.empty()) return fail("that face has no edges to copy onto this sketch");
  SketchLink l;
  l.id = freshSketchId(s, "lk");
  gp_Pnt at;
  gp_Dir n;
  if (!nearestOnFace(f, gp_Pnt(probe[0], probe[1], probe[2]), at, n)) return fail("could not measure that face");
  l.probe = {at.X(), at.Y(), at.Z()};
  l.normal = {n.X(), n.Y(), n.Z()};
  l.feature = d_->ownerOf(b, f);
  applyLink(s, l, curves, true);
  s.links.push_back(l);
  return true;
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
    for (auto& q : regionTriangles(st.geom, st.sketch.plane)) v.fill.push_back(st.sketch.plane.toWorld(q[0], q[1]));
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
