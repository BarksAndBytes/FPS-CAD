#include "SketchGeom.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <map>
#include <set>

#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <ElSLib.hxx>
#include <Standard_Failure.hxx>
#include <TopoDS.hxx>
#include <gp_Circ.hxx>
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
    ArcGeom ag = arcGeom(s, e);
    gp_Circ circ(gp_Ax2(P({ag.cx, ag.cy}), N, X), ag.r);
    return BRepBuilderAPI_MakeEdge(circ, ag.a0, ag.a1).Edge();
  };
  auto pointsOf = [&](const Seg& sg, bool reversed) -> Poly2 {
    const SketchEntity& e = *sg.e;
    Poly2 pts;
    if (e.kind == "line") {
      pts = {uv(s, e.pts[0]), uv(s, e.pts[1])};
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

}  // namespace fpcad
