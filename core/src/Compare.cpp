#include "CompareShapes.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepGProp.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <GProp_PrincipalProps.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <gp_Ax2.hxx>
#include <gp_Mat.hxx>
#include <gp_Trsf.hxx>

#include "fpcad/Model.h"

namespace fpcad {

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Props {
  double volume = 0, area = 0, size = 1;
  gp_XYZ centre;
  gp_Mat inertia;        // about the centre of mass
  double moments[3]{};   // ascending
  gp_XYZ axes[3];
};

Props propsOf(const TopoDS_Shape& s) {
  Props p;
  GProp_GProps vp, sp;
  BRepGProp::VolumeProperties(s, vp);
  BRepGProp::SurfaceProperties(s, sp);
  p.volume = std::abs(vp.Mass());
  p.area = sp.Mass();
  p.centre = vp.CentreOfMass().XYZ();
  p.inertia = vp.MatrixOfInertia();
  GProp_PrincipalProps pp = vp.PrincipalProperties();
  double m[3];
  pp.Moments(m[0], m[1], m[2]);
  gp_XYZ ax[3] = {pp.FirstAxisOfInertia().XYZ(), pp.SecondAxisOfInertia().XYZ(), pp.ThirdAxisOfInertia().XYZ()};
  int order[3] = {0, 1, 2};
  std::sort(order, order + 3, [&](int a, int b) { return m[a] < m[b]; });
  for (int i = 0; i < 3; ++i) {
    p.moments[i] = m[order[i]];
    p.axes[i] = ax[order[i]];
  }
  Bnd_Box bb;
  BRepBndLib::Add(s, bb);
  if (!bb.IsVoid()) p.size = std::sqrt(bb.SquareExtent());
  return p;
}

// A direction (sign-free line) carried by the shape, weighted by how much of the shape
// defines it. Congruent shapes have the same weighted directions, rotated.
struct Line {
  gp_XYZ d;
  double w;
};

void addLine(std::vector<Line>& lines, gp_XYZ d, double w) {
  double n = d.Modulus();
  if (n < 1e-12 || w <= 0) return;
  d /= n;
  for (auto& l : lines) {
    if (std::abs(l.d.Dot(d)) > 1 - 1e-7) {
      l.w += w;
      return;
    }
  }
  lines.push_back({d, w});
}

std::vector<Line> linesOf(const TopoDS_Shape& s, const Props& p) {
  std::vector<Line> lines;
  // Distinct principal axes come first: they need no faces at all.
  double mx = std::max(p.moments[2], 1e-30);
  for (int i = 0; i < 3; ++i) {
    bool distinct = true;
    for (int j = 0; j < 3; ++j)
      if (j != i && std::abs(p.moments[i] - p.moments[j]) < 1e-3 * mx) distinct = false;
    if (distinct) addLine(lines, p.axes[i], 1e12 * (3 - i));
  }
  for (TopExp_Explorer ex(s, TopAbs_FACE); ex.More(); ex.Next()) {
    const TopoDS_Face& f = TopoDS::Face(ex.Current());
    GProp_GProps fp;
    BRepGProp::SurfaceProperties(f, fp);
    double a = fp.Mass();
    BRepAdaptor_Surface su(f, false);
    gp_Ax1 axis;
    switch (su.GetType()) {
      case GeomAbs_Plane: addLine(lines, su.Plane().Axis().Direction().XYZ(), a); continue;
      case GeomAbs_Cylinder: axis = su.Cylinder().Axis(); break;
      case GeomAbs_Cone: axis = su.Cone().Axis(); break;
      case GeomAbs_Torus: axis = su.Torus().Axis(); break;
      default: continue;
    }
    gp_XYZ d = axis.Direction().XYZ();
    addLine(lines, d, a);
    // An off-centre hole or boss also fixes the rotation about its axis.
    gp_XYZ v = p.centre - axis.Location().XYZ();
    v -= d * v.Dot(d);
    if (v.Modulus() > 1e-4 * p.size) addLine(lines, v, a * 0.5);
  }
  std::sort(lines.begin(), lines.end(), [](const Line& a, const Line& b) { return a.w > b.w; });
  if (lines.size() > 6) lines.resize(6);
  return lines;
}

gp_Mat frame(const gp_XYZ& xIn, const gp_XYZ& v) {
  gp_XYZ x = xIn.Normalized();
  gp_XYZ z = x.Crossed(v);
  z.Normalize();
  gp_XYZ y = z.Crossed(x);
  return gp_Mat(x, y, z);  // columns
}

gp_XYZ anyPerpendicular(const gp_XYZ& d) {
  gp_XYZ t = std::abs(d.X()) < 0.9 ? gp_XYZ(1, 0, 0) : gp_XYZ(0, 1, 0);
  gp_XYZ p = d.Crossed(t);
  return p.Normalized();
}

gp_XYZ rotateAbout(const gp_XYZ& v, const gp_XYZ& axis, double angle) {
  // Rodrigues
  return v * std::cos(angle) + axis.Crossed(v) * std::sin(angle) + axis * (axis.Dot(v) * (1 - std::cos(angle)));
}

bool approx(double a, double b, double rel) { return std::abs(a - b) <= rel * std::max({std::abs(a), std::abs(b), 1e-30}); }

// Directions, square to axis, from the axis to the vertices farthest from it: a shape that has
// only one defining direction (a square-to-round loft, a cylinder with flats) is fixed in its
// turn about that axis by these.
std::vector<gp_XYZ> farthestRadials(const TopoDS_Shape& s, const gp_XYZ& centre, const gp_XYZ& axis, double size) {
  TopTools_IndexedMapOfShape verts;
  TopExp::MapShapes(s, TopAbs_VERTEX, verts);
  std::vector<std::pair<double, gp_XYZ>> radial;
  double farthest = 0;
  for (int i = 1; i <= verts.Extent(); ++i) {
    gp_XYZ v = BRep_Tool::Pnt(TopoDS::Vertex(verts(i))).XYZ() - centre;
    v -= axis * v.Dot(axis);
    double r = v.Modulus();
    if (r < 1e-6 * size) continue;
    radial.push_back({r, v / r});
    farthest = std::max(farthest, r);
  }
  std::vector<gp_XYZ> out;
  for (auto& [r, d] : radial)
    if (r > farthest * (1 - 1e-6) && out.size() < 24) out.push_back(d);
  return out;
}

// Candidate rotations taking the player's shape onto the target's.
std::vector<gp_Mat> candidateRotations(const std::vector<Line>& pl, const std::vector<Line>& tl,
                                       const TopoDS_Shape& player, const Props& pp,
                                       const TopoDS_Shape& target, const Props& tp) {
  std::vector<gp_Mat> out;
  if (pl.empty() || tl.empty()) {
    out.push_back(gp_Mat(1, 0, 0, 0, 1, 0, 0, 0, 1));
    return out;
  }
  if (pl.size() == 1 || tl.size() == 1) {
    // One defining direction: align it, then fix the turn about it by the farthest vertices,
    // or for a shape with none off the axis (a plain cylinder), try turns in 5° steps.
    auto prad = farthestRadials(player, pp.centre, pl[0].d, pp.size);
    gp_Mat fp = frame(pl[0].d, prad.empty() ? anyPerpendicular(pl[0].d) : prad[0]);
    for (auto& t : tl) {
      if (!approx(t.w, pl[0].w, 1e-3)) continue;
      for (double s : {1.0, -1.0}) {
        gp_XYZ x = t.d * s;
        auto trad = farthestRadials(target, tp.centre, x, tp.size);
        if (!prad.empty() && !trad.empty()) {
          for (auto& v : trad) out.push_back(frame(x, v) * fp.Transposed());
          continue;
        }
        gp_XYZ p0 = anyPerpendicular(x);
        for (int k = 0; k < 72; ++k) {
          gp_XYZ v = rotateAbout(p0, x, k * kPi / 36.0);
          out.push_back(frame(x, v) * fp.Transposed());
        }
      }
    }
    return out;
  }
  gp_Mat fp = frame(pl[0].d, pl[1].d);
  double cosP = std::abs(pl[0].d.Dot(pl[1].d));
  for (size_t i = 0; i < tl.size(); ++i) {
    if (!approx(tl[i].w, pl[0].w, 1e-3)) continue;
    for (size_t j = 0; j < tl.size(); ++j) {
      if (i == j || !approx(tl[j].w, pl[1].w, 1e-3)) continue;
      if (std::abs(std::abs(tl[i].d.Dot(tl[j].d)) - cosP) > 1e-4) continue;
      for (double su : {1.0, -1.0})
        for (double sv : {1.0, -1.0}) {
          // Keep the angle between the two directions, not just their lines.
          if (std::abs((tl[i].d * su).Dot(tl[j].d * sv) - pl[0].d.Dot(pl[1].d)) > 1e-4) continue;
          out.push_back(frame(tl[i].d * su, tl[j].d * sv) * fp.Transposed());
        }
    }
  }
  return out;
}

gp_Trsf placement(const gp_Mat& r, const gp_XYZ& from, const gp_XYZ& to) {
  gp_XYZ rf = from;
  rf.Multiply(r);  // r * from
  gp_XYZ t = to - rf;
  gp_Trsf tr;
  tr.SetValues(r(1, 1), r(1, 2), r(1, 3), t.X(), r(2, 1), r(2, 2), r(2, 3), t.Y(), r(3, 1), r(3, 2), r(3, 3), t.Z());
  return tr;
}

double inertiaGap(const gp_Mat& r, const gp_Mat& ip, const gp_Mat& it) {
  gp_Mat d = r * ip * r.Transposed() - it;
  double num = 0, den = 0;
  for (int a = 1; a <= 3; ++a)
    for (int b = 1; b <= 3; ++b) {
      num += d(a, b) * d(a, b);
      den += it(a, b) * it(a, b);
    }
  return std::sqrt(num / std::max(den, 1e-60));
}

double volumeOf(const TopoDS_Shape& s) {
  GProp_GProps g;
  BRepGProp::VolumeProperties(s, g);
  return std::abs(g.Mass());
}

double commonVolume(const TopoDS_Shape& a, const TopoDS_Shape& b, double fuzzy) {
  BRepAlgoAPI_Common op;
  TopTools_ListOfShape args, tools;
  args.Append(a);
  tools.Append(b);
  op.SetArguments(args);
  op.SetTools(tools);
  op.SetFuzzyValue(fuzzy);
  op.Build();
  if (!op.IsDone()) return 0;
  return volumeOf(op.Shape());
}

// Best overlap (common volume / target volume) over the candidate alignments; stops early at a
// match.
double bestOverlap(const TopoDS_Shape& player, const Props& pp, const TopoDS_Shape& target, const Props& tp,
                   double tolerance) {
  auto pl = linesOf(player, pp);
  auto tl = linesOf(target, tp);
  TopTools_IndexedMapOfShape verts;
  TopExp::MapShapes(player, TopAbs_VERTEX, verts);
  BRepClass3d_SolidClassifier cls(target);
  double tol = 1e-5 * tp.size;
  double best = 0;
  int booleans = 0;
  for (const gp_Mat& r : candidateRotations(pl, tl, player, pp, target, tp)) {
    if (inertiaGap(r, pp.inertia, tp.inertia) > 0.01) continue;
    gp_Trsf tr = placement(r, pp.centre, tp.centre);
    bool inside = true;
    int step = std::max(1, verts.Extent() / 32);
    for (int i = 1; i <= verts.Extent() && inside; i += step) {
      gp_Pnt q = BRep_Tool::Pnt(TopoDS::Vertex(verts(i))).Transformed(tr);
      cls.Perform(q, tol);
      if (cls.State() == TopAbs_OUT) inside = false;
    }
    if (!inside) continue;
    if (++booleans > 24) break;
    TopoDS_Shape moved = BRepBuilderAPI_Transform(player, tr, true).Shape();
    double ov = commonVolume(target, moved, 1e-6 * tp.size) / std::max(tp.volume, 1e-30);
    best = std::max(best, ov);
    if (best >= 1 - tolerance) break;
  }
  return best;
}

std::string percent(double r) {
  char buf[32];
  std::snprintf(buf, sizeof buf, "%.0f%%", r * 100);
  return buf;
}

}  // namespace

ShapeMatch compareShapes(const TopoDS_Shape& player, const TopoDS_Shape& target, double tolerance) {
  ShapeMatch m;
  try {
    Props tp = propsOf(target);
    Props pp = propsOf(player);
    if (pp.volume < 1e-12 * std::max(tp.volume, 1e-30) + 1e-18) {
      m.empty = true;
      m.message = "Nothing built yet";
      return m;
    }
    m.volumeRatio = pp.volume / tp.volume;
    m.areaRatio = pp.area / tp.area;
    if (std::abs(m.volumeRatio - 1) > 0.02) {
      m.message = "Your part has " + percent(m.volumeRatio) + " of the target's volume";
      return m;
    }
    bool momentsMatch = true;
    for (int i = 0; i < 3; ++i)
      if (!approx(pp.moments[i], tp.moments[i], 0.02)) momentsMatch = false;
    if (std::abs(m.areaRatio - 1) > 0.02 || !momentsMatch) {
      m.message = "The volume is right (" + percent(m.volumeRatio) + ") but the shape is different";
      return m;
    }
    m.overlap = bestOverlap(player, pp, target, tp, tolerance);
    if (m.overlap >= 1 - tolerance && std::abs(m.volumeRatio - 1) <= tolerance) {
      m.match = true;
      m.message = "Match";
      return m;
    }
    // A mirror image has all the same measurements; check for one so the hint can say so.
    gp_Trsf mirror;
    mirror.SetMirror(gp_Ax2(gp_Pnt(pp.centre), gp::DX()));
    TopoDS_Shape flipped = BRepBuilderAPI_Transform(player, mirror, true).Shape();
    Props fp = propsOf(flipped);
    double mirrored = bestOverlap(flipped, fp, target, tp, tolerance);
    if (mirrored >= 1 - tolerance) {
      m.mirrored = true;
      m.message = "That is a mirror image of the target";
      return m;
    }
    m.message = "Close: the size is right but something differs (best overlap " + percent(m.overlap) + ")";
  } catch (const Standard_Failure& e) {
    m.message = std::string("Could not compare: ") + (e.what() ? e.what() : "geometry error");
  }
  return m;
}

ShapeMatch compareParts(const PartModel& player, const PartModel& target, double tolerance) {
  auto merged = [](const PartModel& pm) -> TopoDS_Shape {
    if (pm.bodyCount() == 0) return {};
    TopoDS_Shape s = pm.body(0);
    for (int i = 1; i < pm.bodyCount(); ++i) {
      BRepAlgoAPI_Fuse fuse(s, pm.body(i));
      if (fuse.IsDone()) {
        s = fuse.Shape();
      } else {
        TopoDS_Compound c;
        BRep_Builder b;
        b.MakeCompound(c);
        b.Add(c, s);
        b.Add(c, pm.body(i));
        s = c;
      }
    }
    return s;
  };
  TopoDS_Shape t = merged(target);
  TopoDS_Shape p = merged(player);
  ShapeMatch m;
  if (t.IsNull()) {
    m.message = "The target has no geometry";
    return m;
  }
  if (p.IsNull()) {
    m.empty = true;
    m.message = "Nothing built yet";
    return m;
  }
  return compareShapes(p, t, tolerance);
}

}  // namespace fpcad
