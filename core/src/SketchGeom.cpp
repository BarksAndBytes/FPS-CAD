#include "SketchGeom.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <map>
#include <set>

#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangulation.hxx>
#include <TopLoc_Location.hxx>
#include <ElSLib.hxx>
#include <Standard_Failure.hxx>
#include <TopoDS.hxx>
#include <GeomAPI.hxx>
#include <Geom2dAPI_Interpolate.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom_Curve.hxx>
#include <TColgp_Array1OfVec2d.hxx>
#include <TColgp_HArray1OfPnt2d.hxx>
#include <TColStd_HArray1OfBoolean.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <gp_Circ.hxx>
#include <gp_Elips.hxx>
#include <gp_Pln.hxx>

namespace fpcad {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kCircleSegments = 48;

struct UnionFind {
  std::map<std::string, std::string> parent;
  std::string find(const std::string& a) {
    auto it = parent.find(a);
    if (it == parent.end() || it->second == a) return a;
    std::string root = find(it->second);
    parent[a] = root;
    return root;
  }
  void unite(const std::string& a, const std::string& b) {
    std::string ra = find(a), rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }
};

std::array<double, 2> uv(const Sketch& s, const std::string& id) {
  const SketchPoint* p = s.point(id);
  return {p->x, p->y};
}

// Samples an arc from angle a0 counter-clockwise to a1 (a1 > a0).
Poly2 arcPoints(double cx, double cy, double r, double a0, double a1) {
  int n = std::max(8, static_cast<int>(std::ceil((a1 - a0) / (2 * kPi) * kCircleSegments)));
  Poly2 out;
  for (int i = 0; i <= n; ++i) {
    double a = a0 + (a1 - a0) * i / n;
    out.push_back({cx + r * std::cos(a), cy + r * std::sin(a)});
  }
  return out;
}

struct ArcGeom {
  double cx, cy, r, a0, a1;
};

ArcGeom arcGeom(const Sketch& s, const SketchEntity& e) {
  auto c = uv(s, e.pts[0]), st = uv(s, e.pts[1]), en = uv(s, e.pts[2]);
  ArcGeom g{c[0], c[1], std::hypot(st[0] - c[0], st[1] - c[1]), std::atan2(st[1] - c[1], st[0] - c[0]),
            std::atan2(en[1] - c[1], en[0] - c[0])};
  while (g.a1 <= g.a0 + 1e-12) g.a1 += 2 * kPi;
  return g;
}

// Ellipse: centre, the axis through pts[1] (semi-axis a) and the square axis (semi-axis r).
struct EllipseGeom {
  double cx, cy, ax, ay, a, r;  // (ax, ay) unit direction of the pts[1] axis
};

EllipseGeom ellipseGeom(const Sketch& s, const SketchEntity& e) {
  auto c = uv(s, e.pts[0]), m = uv(s, e.pts[1]);
  double a = std::hypot(m[0] - c[0], m[1] - c[1]);
  if (a < 1e-12 || e.r < 1e-12) throw std::runtime_error("ellipse " + e.id + " has no size");
  return {c[0], c[1], (m[0] - c[0]) / a, (m[1] - c[1]) / a, a, e.r};
}

Poly2 ellipsePoints(const EllipseGeom& g) {
  Poly2 out;
  for (int i = 0; i <= kCircleSegments * 2; ++i) {
    double t = 2 * kPi * i / (kCircleSegments * 2);
    double u = g.a * std::cos(t), v = g.r * std::sin(t);
    out.push_back({g.cx + u * g.ax - v * g.ay, g.cy + u * g.ay + v * g.ax});
  }
  return out;
}

bool splineClosed(const SketchEntity& e) { return e.pts.size() > 2 && e.pts.front() == e.pts.back(); }

// Direction leaving entity other at its end point p (a line's or an arc's), or nothing.
bool leavingAt(const Sketch& s, const SketchEntity& other, const std::string& p, std::array<double, 2>& t) {
  auto P = uv(s, p);
  if (other.kind == "line") {
    if (other.pts[0] != p && other.pts[1] != p) return false;
    auto q = uv(s, other.pts[0] == p ? other.pts[1] : other.pts[0]);
    t = {P[0] - q[0], P[1] - q[1]};
  } else if (other.kind == "arc") {
    if (other.pts[1] != p && other.pts[2] != p) return false;
    auto c = uv(s, other.pts[0]);
    double rx = P[0] - c[0], ry = P[1] - c[1];
    double sgn = other.pts[2] == p ? 1.0 : -1.0;  // counter-clockwise past the end, back past the start
    t = {-ry * sgn, rx * sgn};
  } else {
    return false;
  }
  double n = std::hypot(t[0], t[1]);
  if (n < 1e-15) return false;
  t = {t[0] / n, t[1] / n};
  return true;
}

// The fit-point spline through the entity's points, in plane coordinates. Tangent relations to a
// line or arc sharing an end set the direction it leaves (or arrives at) that end.
Handle(Geom2d_BSplineCurve) splineCurve(const Sketch& s, const SketchEntity& e) {
  bool closed = splineClosed(e);
  size_t n = closed ? e.pts.size() - 1 : e.pts.size();
  if (n < 2) throw std::runtime_error("spline " + e.id + " needs at least two points");
  Handle(TColgp_HArray1OfPnt2d) pts = new TColgp_HArray1OfPnt2d(1, static_cast<int>(n));
  for (size_t i = 0; i < n; ++i) {
    auto q = uv(s, e.pts[i]);
    if (i > 0) {
      auto prev = uv(s, e.pts[i - 1]);
      if (std::hypot(q[0] - prev[0], q[1] - prev[1]) < 1e-12)
        throw std::runtime_error("spline " + e.id + " has two points on top of each other");
    }
    pts->SetValue(static_cast<int>(i + 1), gp_Pnt2d(q[0], q[1]));
  }
  Geom2dAPI_Interpolate interp(pts, closed, 1e-9);
  if (!closed) {
    TColgp_Array1OfVec2d tans(1, static_cast<int>(n));
    Handle(TColStd_HArray1OfBoolean) flags = new TColStd_HArray1OfBoolean(1, static_cast<int>(n));
    for (int i = 1; i <= static_cast<int>(n); ++i) {
      tans.SetValue(i, gp_Vec2d(1, 0));
      flags->SetValue(i, false);
    }
    bool any = false;
    for (auto& c : s.constraints) {
      if (c.kind != "tangent" || c.refs.size() != 2) continue;
      std::string otherId = c.refs[0] == e.id ? c.refs[1] : (c.refs[1] == e.id ? c.refs[0] : "");
      const SketchEntity* other = otherId.empty() ? nullptr : s.entity(otherId);
      if (!other) continue;
      std::array<double, 2> t;
      if (leavingAt(s, *other, e.pts.front(), t)) {
        tans.SetValue(1, gp_Vec2d(t[0], t[1]));
        flags->SetValue(1, true);
        any = true;
      }
      if (leavingAt(s, *other, e.pts.back(), t)) {
        tans.SetValue(static_cast<int>(n), gp_Vec2d(-t[0], -t[1]));  // arriving: against the leaving way
        flags->SetValue(static_cast<int>(n), true);
        any = true;
      }
    }
    if (any) interp.Load(tans, flags, true);
  }
  interp.Perform();
  if (!interp.IsDone()) throw std::runtime_error("spline " + e.id + " could not be fitted");
  return interp.Curve();
}

Poly2 splinePoints(const Handle(Geom2d_BSplineCurve)& c, size_t fitPoints) {
  Poly2 out;
  int n = std::max(16, static_cast<int>(fitPoints) * 12);
  double t0 = c->FirstParameter(), t1 = c->LastParameter();
  for (int i = 0; i <= n; ++i) {
    gp_Pnt2d p = c->Value(t0 + (t1 - t0) * i / n);
    out.push_back({p.X(), p.Y()});
  }
  return out;
}

// A text's glyph outlines placed at its anchor and scaled to its cap height.
std::vector<Poly2> textContours(const Sketch& s, const SketchEntity& e) {
  std::vector<Poly2> out;
  auto a = uv(s, e.pts[0]);
  for (auto& c : e.contours) {
    if (c.size() < 3) continue;
    Poly2 poly;
    for (auto& q : c) poly.push_back({a[0] + q[0] * e.r, a[1] + q[1] * e.r});
    out.push_back(poly);
  }
  return out;
}

double signedArea(const Poly2& p) {
  double a = 0;
  for (size_t i = 0; i < p.size(); ++i) {
    const auto& q = p[i];
    const auto& r = p[(i + 1) % p.size()];
    a += q[0] * r[1] - r[0] * q[1];
  }
  return a / 2;
}

struct Loop {
  TopoDS_Wire wire;
  Poly2 poly;
  double area = 0;  // absolute
  int depth = 0;
  int parent = -1;
};

}  // namespace

gp_Ax3 sketchAxes(const SketchPlane& p) {
  return gp_Ax3(gp_Pnt(p.origin[0], p.origin[1], p.origin[2]), gp_Dir(p.normal[0], p.normal[1], p.normal[2]),
                gp_Dir(p.xdir[0], p.xdir[1], p.xdir[2]));
}

bool pointInPolygon(const Poly2& poly, double u, double v) {
  bool in = false;
  for (size_t i = 0, j = poly.size() - 1; i < poly.size(); j = i++) {
    const auto& a = poly[i];
    const auto& b = poly[j];
    if ((a[1] > v) != (b[1] > v) && u < (b[0] - a[0]) * (v - a[1]) / (b[1] - a[1]) + a[0]) in = !in;
  }
  return in;
}

std::vector<SketchPolyline> sketchPolylines(const Sketch& s) {
  std::vector<SketchPolyline> out;
  for (auto& e : s.entities) {
    SketchPolyline pl{e.id, e.construction, {}};
    try {
      if (e.kind == "line") {
        pl.points = {uv(s, e.pts[0]), uv(s, e.pts[1])};
      } else if (e.kind == "circle") {
        auto c = uv(s, e.pts[0]);
        pl.points = arcPoints(c[0], c[1], e.r, 0, 2 * kPi);
      } else if (e.kind == "arc") {
        ArcGeom g = arcGeom(s, e);
        pl.points = arcPoints(g.cx, g.cy, g.r, g.a0, g.a1);
      } else if (e.kind == "ellipse") {
        pl.points = ellipsePoints(ellipseGeom(s, e));
      } else if (e.kind == "spline") {
        pl.points = splinePoints(splineCurve(s, e), e.pts.size());
      } else if (e.kind == "text") {
        for (auto& c : textContours(s, e)) {
          SketchPolyline part{e.id, e.construction, c};
          part.points.push_back(c.front());
          out.push_back(std::move(part));
        }
        continue;
      }
    } catch (...) {
      continue;
    }
    if (!pl.points.empty()) out.push_back(std::move(pl));
  }
  return out;
}

SketchGeometry buildSketchGeometry(const Sketch& s) {
  SketchGeometry g;
  const gp_Ax3 ax = sketchAxes(s.plane);
  const gp_Pln pln(ax);
  auto P = [&](const std::array<double, 2>& q) { return ElSLib::Value(q[0], q[1], pln); };
  const gp_Dir N = ax.Direction(), X = ax.XDirection();

  // Points joined by a coincident relation, or sitting on top of each other, are one vertex.
  UnionFind uf;
  for (auto& c : s.constraints)
    if (c.kind == "coincident" && c.refs.size() == 2) uf.unite(c.refs[0], c.refs[1]);
  std::vector<std::string> ids{"o"};
  for (auto& p : s.points) ids.push_back(p.id);
  for (size_t i = 0; i < ids.size(); ++i)
    for (size_t j = i + 1; j < ids.size(); ++j) {
      auto a = uv(s, ids[i]), b = uv(s, ids[j]);
      if (std::hypot(a[0] - b[0], a[1] - b[1]) < 1e-9) uf.unite(ids[i], ids[j]);
    }

  struct Seg {
    const SketchEntity* e;
    std::string a, b;  // vertex representatives at start and end
  };
  std::vector<Seg> segs;
  std::vector<Loop> loops;
  for (auto& e : s.entities) {
    if (e.construction) continue;
    if (e.kind == "line") {
      segs.push_back({&e, uf.find(e.pts[0]), uf.find(e.pts[1])});
    } else if (e.kind == "arc") {
      segs.push_back({&e, uf.find(e.pts[1]), uf.find(e.pts[2])});
    } else if (e.kind == "spline" && !splineClosed(e)) {
      segs.push_back({&e, uf.find(e.pts.front()), uf.find(e.pts.back())});
    } else if (e.kind == "text") {
      // Each glyph outline is a loop; the nesting below cuts the holes in letters like "o".
      if (e.r <= 1e-12) continue;
      for (auto& c : textContours(s, e)) {
        try {
          BRepBuilderAPI_MakePolygon mp;
          for (auto& q : c) mp.Add(P(q));
          mp.Close();
          if (!mp.IsDone()) continue;
          Loop L;
          L.wire = mp.Wire();
          L.poly = c;
          loops.push_back(L);
        } catch (const Standard_Failure&) {
          g.problems.push_back("a letter of text " + e.id + " could not be built");
        }
      }
    } else if (e.kind == "spline" || e.kind == "ellipse") {
      // Closed on their own, like a circle.
      try {
        Loop L;
        if (e.kind == "spline") {
          Handle(Geom2d_BSplineCurve) c2 = splineCurve(s, e);
          L.wire = BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(GeomAPI::To3d(c2, pln))).Wire();
          L.poly = splinePoints(c2, e.pts.size());
        } else {
          EllipseGeom eg = ellipseGeom(s, e);
          gp_Dir A = gp_Dir(eg.ax * X.XYZ() + eg.ay * N.Crossed(X).XYZ());
          gp_Dir B = N.Crossed(A);
          bool alongA = eg.a >= eg.r;
          gp_Elips el(gp_Ax2(P({eg.cx, eg.cy}), N, alongA ? A : B), std::max(eg.a, eg.r), std::min(eg.a, eg.r));
          L.wire = BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(el)).Wire();
          L.poly = ellipsePoints(eg);
        }
        L.poly.pop_back();
        loops.push_back(L);
      } catch (const Standard_Failure& ex) {
        g.problems.push_back(std::string(e.kind) + " " + e.id + " could not be built: " + ex.GetMessageString());
      } catch (const std::exception& ex) {
        g.problems.push_back(ex.what());
      }
    } else if (e.kind == "circle") {
      if (e.r <= 1e-12) {
        g.problems.push_back("circle " + e.id + " has no size");
        continue;
      }
      auto c = uv(s, e.pts[0]);
      gp_Circ circ(gp_Ax2(P(c), N, X), e.r);
      Loop L;
      L.wire = BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(circ)).Wire();
      L.poly = arcPoints(c[0], c[1], e.r, 0, 2 * kPi);
      L.poly.pop_back();
      loops.push_back(L);
    }
  }

  // Edge for one segment, traversed from its start (forward) or its end.
  auto edgeOf = [&](const Seg& sg) -> TopoDS_Edge {
    const SketchEntity& e = *sg.e;
    if (e.kind == "line") {
      auto a = uv(s, e.pts[0]), b = uv(s, e.pts[1]);
      if (std::hypot(b[0] - a[0], b[1] - a[1]) < 1e-12) throw std::runtime_error("zero-length line " + e.id);
      return BRepBuilderAPI_MakeEdge(P(a), P(b)).Edge();
    }
    if (e.kind == "spline") return BRepBuilderAPI_MakeEdge(GeomAPI::To3d(splineCurve(s, e), pln)).Edge();
    ArcGeom ag = arcGeom(s, e);
    gp_Circ circ(gp_Ax2(P({ag.cx, ag.cy}), N, X), ag.r);
    return BRepBuilderAPI_MakeEdge(circ, ag.a0, ag.a1).Edge();
  };
  auto pointsOf = [&](const Seg& sg, bool reversed) -> Poly2 {
    const SketchEntity& e = *sg.e;
    Poly2 pts;
    if (e.kind == "line") {
      pts = {uv(s, e.pts[0]), uv(s, e.pts[1])};
    } else if (e.kind == "spline") {
      pts = splinePoints(splineCurve(s, e), e.pts.size());
    } else {
      ArcGeom ag = arcGeom(s, e);
      pts = arcPoints(ag.cx, ag.cy, ag.r, ag.a0, ag.a1);
    }
    if (reversed) std::reverse(pts.begin(), pts.end());
    return pts;
  };

  std::map<std::string, std::vector<int>> adj;
  for (size_t i = 0; i < segs.size(); ++i) {
    adj[segs[i].a].push_back(static_cast<int>(i));
    adj[segs[i].b].push_back(static_cast<int>(i));
  }
  std::vector<bool> seen(segs.size(), false);
  for (size_t start = 0; start < segs.size(); ++start) {
    if (seen[start]) continue;
    // Gather the connected component.
    std::vector<int> comp;
    std::vector<int> stack{static_cast<int>(start)};
    seen[start] = true;
    while (!stack.empty()) {
      int i = stack.back();
      stack.pop_back();
      comp.push_back(i);
      for (const std::string* v : {&segs[i].a, &segs[i].b})
        for (int j : adj[*v])
          if (!seen[j]) { seen[j] = true; stack.push_back(j); }
    }
    std::map<std::string, int> degree;
    for (int i : comp) {
      degree[segs[i].a]++;
      degree[segs[i].b]++;
    }
    std::vector<std::string> ends;
    bool branching = false;
    for (auto& [v, d] : degree) {
      if (d == 1) ends.push_back(v);
      else if (d != 2) branching = true;
    }
    bool closed = ends.empty() && !branching;
    bool open = ends.size() == 2 && !branching;
    if (!closed && !open) {
      g.problems.push_back("some lines branch or overlap, so they form no clean profile");
      continue;
    }
    // Walk the chain.
    std::string at = closed ? segs[comp[0]].a : ends[0];
    std::set<int> used;
    BRepBuilderAPI_MakeWire mw;
    Poly2 poly;
    try {
      for (size_t k = 0; k < comp.size(); ++k) {
        int next = -1;
        for (int j : adj[at])
          if (!used.count(j)) { next = j; break; }
        if (next < 0) break;
        used.insert(next);
        bool reversed = segs[next].a != at;
        mw.Add(edgeOf(segs[next]));
        Poly2 pts = pointsOf(segs[next], reversed);
        poly.insert(poly.end(), pts.begin() + (poly.empty() ? 0 : 1), pts.end());
        at = reversed ? segs[next].a : segs[next].b;
      }
      if (!mw.IsDone()) throw std::runtime_error("edges do not join");
    } catch (const Standard_Failure& e) {
      g.problems.push_back(std::string("profile could not be built: ") + e.GetMessageString());
      continue;
    } catch (const std::exception& e) {
      g.problems.push_back(std::string("profile could not be built: ") + e.what());
      continue;
    }
    if (open) {
      g.paths.push_back(mw.Wire());
      continue;
    }
    if (!poly.empty()) poly.pop_back();  // closing point repeats the first
    Loop L;
    L.wire = mw.Wire();
    L.poly = poly;
    loops.push_back(L);
  }

  // Orient every loop counter-clockwise about the plane normal and work out nesting.
  for (auto& L : loops) {
    double a = signedArea(L.poly);
    if (a < 0) {
      L.wire.Reverse();
      std::reverse(L.poly.begin(), L.poly.end());
    }
    L.area = std::abs(a);
  }
  for (size_t i = 0; i < loops.size(); ++i) {
    double best = 1e300;
    for (size_t j = 0; j < loops.size(); ++j) {
      if (i == j || loops[j].area <= loops[i].area || loops[i].poly.empty()) continue;
      if (pointInPolygon(loops[j].poly, loops[i].poly[0][0], loops[i].poly[0][1])) {
        loops[i].depth++;
        if (loops[j].area < best) { best = loops[j].area; loops[i].parent = static_cast<int>(j); }
      }
    }
  }
  for (size_t i = 0; i < loops.size(); ++i) {
    if (loops[i].depth % 2 != 0) continue;
    try {
      BRepBuilderAPI_MakeFace mf(pln, loops[i].wire, true);
      std::vector<Poly2> holes;
      for (size_t j = 0; j < loops.size(); ++j)
        if (loops[j].parent == static_cast<int>(i) && loops[j].depth == loops[i].depth + 1) {
          mf.Add(TopoDS::Wire(loops[j].wire.Reversed()));
          holes.push_back(loops[j].poly);
        }
      if (!mf.IsDone()) {
        g.problems.push_back("a closed loop could not be made into a face");
        continue;
      }
      g.regions.push_back(mf.Face());
      g.regionOutlines.push_back(loops[i].poly);
      g.regionHoles.push_back(holes);
      if (loops[i].depth == 0) g.loops.push_back(loops[i].wire);
    } catch (const Standard_Failure& e) {
      g.problems.push_back(std::string("face could not be built: ") + e.GetMessageString());
    }
  }
  return g;
}

std::vector<std::array<double, 2>> regionTriangles(const SketchGeometry& g, const SketchPlane& plane) {
  std::vector<std::array<double, 2>> out;
  double size = 0;
  for (auto& o : g.regionOutlines)
    for (auto& q : o) size = std::max({size, std::abs(q[0]), std::abs(q[1])});
  double deflection = std::max(size * 0.002, 1e-7);
  for (const TopoDS_Face& face : g.regions) {
    try {
      BRepMesh_IncrementalMesh mesher(face, deflection, false, 0.25);
      TopLoc_Location loc;
      Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
      if (tri.IsNull()) continue;
      for (int t = 1; t <= tri->NbTriangles(); ++t) {
        int n[3];
        tri->Triangle(t).Get(n[0], n[1], n[2]);
        for (int k : n) {
          gp_Pnt p = tri->Node(k).Transformed(loc.Transformation());
          out.push_back(plane.toPlane({p.X(), p.Y(), p.Z()}));
        }
      }
    } catch (const Standard_Failure&) {
      // A face that will not mesh is simply left unshaded.
    }
  }
  return out;
}

std::vector<std::array<double, 2>> sketchFill(const Sketch& s) {
  try {
    return regionTriangles(buildSketchGeometry(s), s.plane);
  } catch (...) {
    return {};
  }
}

std::vector<SketchCurve> sketchCurves(const Sketch& s) {
  std::vector<SketchCurve> out;
  for (auto& pl : sketchPolylines(s)) out.push_back({pl.entityId, pl.construction, pl.points});
  return out;
}

}  // namespace fpcad
