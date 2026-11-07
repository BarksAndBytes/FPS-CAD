#include "fpcad/Assembly.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <map>

#include <BRepAlgoAPI_Common.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepGProp.hxx>
#include <BRep_Builder.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <Standard_Failure.hxx>
#include <TopoDS_Compound.hxx>
#include <gp_Quaternion.hxx>
#include <gp_Trsf.hxx>

#include "fpcad/FileIO.h"

namespace fpcad {
namespace {

using Quat = std::array<double, 4>;  // x y z w

Quat mul(const Quat& a, const Quat& b) {
  return {a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
          a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
          a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
          a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]};
}

Vec3 rotate(const Quat& q, const Vec3& v) {
  Quat p{v[0], v[1], v[2], 0};
  Quat qc{-q[0], -q[1], -q[2], q[3]};
  Quat r = mul(mul(q, p), qc);
  return {r[0], r[1], r[2]};
}

Quat normalised(Quat q) {
  double n = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  if (n < 1e-12) return {0, 0, 0, 1};
  for (auto& c : q) c /= n;
  return q;
}

Quat conj(const Quat& q) { return {-q[0], -q[1], -q[2], q[3]}; }

Quat fromRotvec(double x, double y, double z) {
  double a = std::sqrt(x * x + y * y + z * z);
  if (a < 1e-15) return {x / 2, y / 2, z / 2, 1};
  double s = std::sin(a / 2) / a;
  return {x * s, y * s, z * s, std::cos(a / 2)};
}

Vec3 sub(const Vec3& a, const Vec3& b) { return {a[0] - b[0], a[1] - b[1], a[2] - b[2]}; }
double dot(const Vec3& a, const Vec3& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
Vec3 scale(const Vec3& a, double k) { return {a[0] * k, a[1] * k, a[2] * k}; }
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }
// The part of v square to the unit direction d.
Vec3 perp(const Vec3& v, const Vec3& d) { return sub(v, scale(d, dot(v, d))); }

// Solves the n×n system A x = b in place (partial pivoting). False when singular.
bool solveDense(std::vector<double>& A, std::vector<double>& b, int n) {
  for (int c = 0; c < n; ++c) {
    int piv = c;
    for (int r = c + 1; r < n; ++r)
      if (std::abs(A[r * n + c]) > std::abs(A[piv * n + c])) piv = r;
    if (std::abs(A[piv * n + c]) < 1e-300) return false;
    if (piv != c) {
      for (int k = 0; k < n; ++k) std::swap(A[c * n + k], A[piv * n + k]);
      std::swap(b[c], b[piv]);
    }
    for (int r = c + 1; r < n; ++r) {
      double f = A[r * n + c] / A[c * n + c];
      if (f == 0) continue;
      for (int k = c; k < n; ++k) A[r * n + k] -= f * A[c * n + k];
      b[r] -= f * b[c];
    }
  }
  for (int r = n - 1; r >= 0; --r) {
    double sum = b[r];
    for (int k = r + 1; k < n; ++k) sum -= A[r * n + k] * b[k];
    b[r] = sum / A[r * n + r];
  }
  return true;
}

// A mate reference's geometry in its part: a flat face (point and normal), an axis (point and
// direction), or a point (a sphere's centre).
struct RefGeom {
  std::string kind;  // plane, axis, point
  Vec3 p{}, d{};
};

}  // namespace

Vec3 transformPoint(const Placement& p, const Vec3& v) {
  Vec3 r = rotate(normalised(p.q), v);
  return {r[0] + p.t[0], r[1] + p.t[1], r[2] + p.t[2]};
}

Placement compose(const Placement& parent, const Placement& child) {
  Placement out;
  out.q = normalised(mul(normalised(parent.q), normalised(child.q)));
  out.t = transformPoint(parent, child.t);
  return out;
}

AssemblyModel::AssemblyModel(AssemblyDocument doc, std::string baseDir)
    : doc_(std::move(doc)), baseDir_(std::move(baseDir)) {}

int AssemblyModel::partFor(const PartDocument& p) {
  for (size_t i = 0; i < parts_.size(); ++i) if (parts_[i].key == p.fileId) return static_cast<int>(i);
  AssemblyPart ap;
  ap.key = p.fileId;
  ap.name = p.name;
  ap.model = std::make_shared<PartModel>(p);
  ap.model->rebuild();
  parts_.push_back(std::move(ap));
  return static_cast<int>(parts_.size() - 1);
}

void AssemblyModel::addComponents(const AssemblyDocument& doc, const std::string& dir,
                                  const Placement& parent, int depth) {
  namespace fs = std::filesystem;
  for (auto& c : doc.components) {
    if (c.suppressed) continue;
    PlacedComponent pc;
    pc.componentId = c.id;
    pc.name = c.name;
    pc.placement = compose(parent, c.placement);
    try {
      if (c.virtualPart) {
        pc.part = partFor(*c.virtualPart);
      } else {
        fs::path file = fs::path(dir) / c.path;
        FileKind kind = fileKind(file.string());
        if (kind == FileKind::Part) {
          pc.part = partFor(loadPart(file.string()));
        } else if (kind == FileKind::Assembly) {
          if (depth > 32) throw FileError("assemblies are nested too deeply (is one including itself?)");
          addComponents(loadAssembly(file.string()), file.parent_path().string(), pc.placement, depth + 1);
          continue;
        } else {
          throw FileError("cannot open '" + c.path + "'");
        }
      }
      const auto& rep = parts_[static_cast<size_t>(pc.part)].model->lastReport();
      if (!rep.ok) {
        pc.ok = false;
        pc.message = "part has rebuild errors";
      }
    } catch (const std::exception& e) {
      pc.ok = false;
      pc.message = e.what();
    }
    placed_.push_back(pc);
  }
}

bool AssemblyModel::rebuild() {
  parts_.clear();
  placed_.clear();
  nested_ = false;
  for (auto& c : doc_.components)
    if (!c.virtualPart && fileKind((std::filesystem::path(baseDir_) / c.path).string()) == FileKind::Assembly) nested_ = true;
  addComponents(doc_, baseDir_, Placement{}, 0);
  solveMates();
  for (auto& p : placed_) if (!p.ok) return false;
  return true;
}

void AssemblyModel::updatePlacements() {
  if (nested_) {
    parts_.clear();
    placed_.clear();
    addComponents(doc_, baseDir_, Placement{}, 0);
    return;
  }
  for (auto& pc : placed_)
    for (auto& c : doc_.components)
      if (c.id == pc.componentId) pc.placement = c.placement;
}

AssemblyModel::MateReport AssemblyModel::solveMates() {
  MateReport rep;
  // The geometry each mate refers to, found in its component's part.
  std::map<std::string, int> partOf;  // top-level component id -> part index
  for (auto& pc : placed_) partOf[pc.componentId] = pc.part;
  std::map<std::string, size_t> compIndex;
  for (size_t i = 0; i < doc_.components.size(); ++i) compIndex[doc_.components[i].id] = i;
  struct Live {
    const Mate* mate;
    size_t a, b;
    RefGeom ga, gb;
  };
  std::vector<Live> live;
  auto resolve = [&](const Json& ref, size_t& comp, RefGeom& g) -> bool {
    std::string cid = ref.value("component", std::string());
    auto ci = compIndex.find(cid);
    auto pi = partOf.find(cid);
    if (ci == compIndex.end() || pi == partOf.end() || pi->second < 0) return false;
    comp = ci->second;
    const PartModel& pm = *parts_[static_cast<size_t>(pi->second)].model;
    PartModel::FaceMeasure m = pm.resolveFace(ref);
    if (!m.ok) return false;
    if (m.kind == "plane") g = {"plane", m.centre, m.normal};
    else if (m.kind == "cylinder" || m.kind == "cone" || m.kind == "torus") g = {"axis", m.centre, m.axis};
    else if (m.kind == "sphere") g = {"point", m.centre, {0, 0, 1}};
    else return false;
    return true;
  };
  for (auto& m : doc_.mates) {
    if (m.suppressed) continue;
    if (!m.refs.is_array() || m.refs.size() != 2) {
      rep.failing.push_back(m.id);
      continue;
    }
    Live l{&m, 0, 0, {}, {}};
    if (!resolve(m.refs[0], l.a, l.ga) || !resolve(m.refs[1], l.b, l.gb) || l.a == l.b) {
      rep.failing.push_back(m.id);
      continue;
    }
    live.push_back(l);
  }
  // Unknowns: six per component that moves (not grounded, used by a mate).
  std::vector<int> var(doc_.components.size(), -1);
  int nv = 0;
  for (auto& l : live)
    for (size_t c : {l.a, l.b})
      if (!doc_.components[c].grounded && var[c] < 0) var[c] = nv++;
  std::vector<Placement> base(doc_.components.size());
  for (size_t i = 0; i < doc_.components.size(); ++i) base[i] = doc_.components[i].placement;
  const int n = nv * 6;
  auto placementOf = [&](const std::vector<double>& x, size_t c) {
    if (var[c] < 0) return base[c];
    const double* v = &x[static_cast<size_t>(var[c]) * 6];
    Placement p;
    p.t = {base[c].t[0] + v[0], base[c].t[1] + v[1], base[c].t[2] + v[2]};
    p.q = normalised(mul(fromRotvec(v[3], v[4], v[5]), normalised(base[c].q)));
    return p;
  };
  auto world = [](const Placement& pl, const RefGeom& g) {
    Placement r = pl;
    r.t = {0, 0, 0};
    RefGeom w = g;
    w.p = transformPoint(pl, g.p);
    w.d = transformPoint(r, g.d);
    double k = norm(w.d);
    if (k > 1e-15) w.d = scale(w.d, 1.0 / k);
    return w;
  };
  std::vector<std::string> owner;
  auto residuals = [&](const std::vector<double>& x, bool keepOwners) {
    std::vector<double> r;
    if (keepOwners) owner.clear();
    for (auto& l : live) {
      size_t before = r.size();
      Placement pa = placementOf(x, l.a), pb = placementOf(x, l.b);
      RefGeom A = world(pa, l.ga), B = world(pb, l.gb);
      const std::string& t = l.mate->type;
      const Json& prm = l.mate->params;
      bool aligned = prm.value("aligned", false);
      auto push3 = [&](const Vec3& v) { r.insert(r.end(), {v[0], v[1], v[2]}); };
      auto facing = [&]() { push3(aligned ? sub(A.d, B.d) : Vec3{A.d[0] + B.d[0], A.d[1] + B.d[1], A.d[2] + B.d[2]}); };
      if (t == "lock") {
        Placement inv;
        inv.q = conj(normalised(pa.q));
        Vec3 it = transformPoint(inv, pa.t);
        inv.t = {-it[0], -it[1], -it[2]};
        Placement rel = compose(inv, pb);
        std::vector<double> rt = prm.value("t", std::vector<double>{0, 0, 0});
        std::vector<double> rq = prm.value("q", std::vector<double>{0, 0, 0, 1});
        push3({rel.t[0] - rt[0], rel.t[1] - rt[1], rel.t[2] - rt[2]});
        Quat dq = mul(normalised(rel.q), conj(normalised({rq[0], rq[1], rq[2], rq[3]})));
        double sgn = dq[3] < 0 ? -1.0 : 1.0;
        push3({2 * sgn * dq[0], 2 * sgn * dq[1], 2 * sgn * dq[2]});
      } else if (t == "angle") {
        double a = prm.value("angle", 0.0);
        r.push_back(dot(A.d, B.d) - std::cos(a));
      } else if (t == "concentric" || (t == "coincident" && A.kind == "axis" && B.kind == "axis")) {
        if (A.kind == "axis" && B.kind == "axis") {
          push3(cross(A.d, B.d));
          push3(perp(sub(B.p, A.p), A.d));
        } else if ((A.kind == "axis" && B.kind == "point") || (A.kind == "point" && B.kind == "axis")) {
          const RefGeom& ax = A.kind == "axis" ? A : B;
          const RefGeom& pt = A.kind == "axis" ? B : A;
          push3(perp(sub(pt.p, ax.p), ax.d));
        } else if (A.kind == "point" && B.kind == "point") {
          push3(sub(B.p, A.p));
        } else {
          r.push_back(1.0);  // concentric needs round faces: never met with a flat one
        }
      } else if (t == "coincident" || t == "distance") {
        double d = t == "distance" ? prm.value("distance", 0.0) : 0.0;
        if (A.kind == "plane" && B.kind == "plane") {
          r.push_back(dot(A.d, sub(B.p, A.p)) - (aligned ? 0.0 : d) - (aligned ? d : 0.0));
          facing();
        } else if (A.kind == "plane" || B.kind == "plane") {
          const RefGeom& pl = A.kind == "plane" ? A : B;
          const RefGeom& o = A.kind == "plane" ? B : A;
          r.push_back(dot(pl.d, sub(o.p, pl.p)) - d);
          if (o.kind == "axis") r.push_back(dot(pl.d, o.d));  // an axis lies in the plane
        } else if (A.kind == "axis" && B.kind == "axis") {
          push3(cross(A.d, B.d));
          r.push_back(norm(perp(sub(B.p, A.p), A.d)) - d);
        } else {
          r.push_back(norm(sub(B.p, A.p)) - d);
        }
      } else {
        r.push_back(1.0);  // unknown mate type: never met
      }
      if (keepOwners) owner.resize(r.size(), l.mate->id);
      (void)before;
    }
    return r;
  };
  std::vector<double> x(static_cast<size_t>(n), 0.0);
  std::vector<double> r = residuals(x, true);
  const int m = static_cast<int>(r.size());
  auto cost = [](const std::vector<double>& v) {
    double c = 0;
    for (double e : v) c += e * e;
    return c;
  };
  double c0 = cost(r);
  if (n > 0 && m > 0) {
    double lambda = 1e-10;
    for (int it = 0; it < 200 && c0 > 1e-26; ++it) {
      // Numeric Jacobian.
      std::vector<double> J(static_cast<size_t>(m) * n);
      for (int j = 0; j < n; ++j) {
        std::vector<double> xp = x;
        const double h = 1e-7;
        xp[static_cast<size_t>(j)] += h;
        std::vector<double> rp = residuals(xp, false);
        for (int i = 0; i < m; ++i) J[static_cast<size_t>(i) * n + j] = (rp[static_cast<size_t>(i)] - r[static_cast<size_t>(i)]) / h;
      }
      // Minimum-norm damped step: δ = Jᵀ (J Jᵀ + λI)⁻¹ r, so parts move as little as they can.
      std::vector<double> A(static_cast<size_t>(m) * m);
      for (int i = 0; i < m; ++i)
        for (int k = 0; k < m; ++k) {
          double sum = 0;
          for (int j = 0; j < n; ++j) sum += J[static_cast<size_t>(i) * n + j] * J[static_cast<size_t>(k) * n + j];
          A[static_cast<size_t>(i) * m + k] = sum + (i == k ? lambda : 0.0);
        }
      std::vector<double> y = r;
      if (!solveDense(A, y, m)) {
        lambda = std::max(lambda * 10, 1e-10);
        if (lambda > 1e6) break;
        continue;
      }
      std::vector<double> xn = x;
      for (int j = 0; j < n; ++j) {
        double sum = 0;
        for (int i = 0; i < m; ++i) sum += J[static_cast<size_t>(i) * n + j] * y[static_cast<size_t>(i)];
        xn[static_cast<size_t>(j)] -= sum;
      }
      std::vector<double> rn = residuals(xn, false);
      double cn = cost(rn);
      if (std::isfinite(cn) && cn < c0) {
        x = xn;
        r = rn;
        c0 = cn;
        lambda = std::max(lambda * 0.1, 1e-14);
      } else {
        lambda = std::max(lambda * 10, 1e-10);
        if (lambda > 1e6) break;
      }
    }
  }
  for (size_t c = 0; c < doc_.components.size(); ++c)
    if (var[c] >= 0) doc_.components[c].placement = placementOf(x, c);
  for (int i = 0; i < m; ++i)
    if (std::abs(r[static_cast<size_t>(i)]) > 1e-7 &&
        std::find(rep.failing.begin(), rep.failing.end(), owner[static_cast<size_t>(i)]) == rep.failing.end())
      rep.failing.push_back(owner[static_cast<size_t>(i)]);
  rep.ok = rep.failing.empty();
  rep.message = rep.ok ? (live.empty() ? std::string() : std::to_string(live.size()) + (live.size() == 1 ? " mate met" : " mates met"))
                       : std::to_string(rep.failing.size()) + (rep.failing.size() == 1 ? " mate cannot be met" : " mates cannot be met");
  updatePlacements();
  mates_ = rep;
  return rep;
}

AssemblyModel::MateReport AssemblyModel::drag(const std::string& componentId, const Vec3& delta) {
  MateReport rep;
  Component* c = nullptr;
  for (auto& k : doc_.components) if (k.id == componentId) c = &k;
  if (!c) {
    rep.ok = false;
    rep.message = "that component belongs to a sub-assembly; open it to move it";
    return rep;
  }
  if (c->grounded) {
    rep.ok = false;
    rep.message = c->name + " is grounded";
    return rep;
  }
  std::vector<Placement> before;
  for (auto& k : doc_.components) before.push_back(k.placement);
  bool wasOk = mates_.ok;
  c->placement.t = {c->placement.t[0] + delta[0], c->placement.t[1] + delta[1], c->placement.t[2] + delta[2]};
  rep = solveMates();
  if (wasOk && !rep.ok) {
    for (size_t i = 0; i < doc_.components.size(); ++i) doc_.components[i].placement = before[i];
    updatePlacements();
    solveMates();
    rep.ok = false;
    rep.message = "the mates do not let it go there";
  }
  return rep;
}

std::vector<AssemblyModel::Clash> AssemblyModel::interference() const {
  std::vector<Clash> out;
  std::vector<TopoDS_Shape> shapes(placed_.size());
  std::vector<Bnd_Box> boxes(placed_.size());
  for (size_t i = 0; i < placed_.size(); ++i) {
    const auto& pc = placed_[i];
    if (pc.part < 0) continue;
    const PartModel& pm = *parts_[static_cast<size_t>(pc.part)].model;
    BRep_Builder bb;
    TopoDS_Compound comp;
    bb.MakeCompound(comp);
    gp_Trsf t;
    Quat q = normalised(pc.placement.q);
    t.SetRotation(gp_Quaternion(q[0], q[1], q[2], q[3]));
    t.SetTranslationPart(gp_Vec(pc.placement.t[0], pc.placement.t[1], pc.placement.t[2]));
    for (int b = 0; b < pm.bodyCount(); ++b) bb.Add(comp, BRepBuilderAPI_Transform(pm.body(b), t, true).Shape());
    shapes[i] = comp;
    BRepBndLib::Add(comp, boxes[i]);
  }
  for (size_t i = 0; i < placed_.size(); ++i)
    for (size_t j = i + 1; j < placed_.size(); ++j) {
      if (shapes[i].IsNull() || shapes[j].IsNull() || boxes[i].IsVoid() || boxes[j].IsVoid() || boxes[i].IsOut(boxes[j])) continue;
      try {
        BRepAlgoAPI_Common op(shapes[i], shapes[j]);
        if (!op.IsDone() || op.HasErrors()) continue;
        GProp_GProps g;
        BRepGProp::VolumeProperties(op.Shape(), g);
        if (g.Mass() < 1e-15) continue;
        Clash c;
        c.a = static_cast<int>(i);
        c.b = static_cast<int>(j);
        c.volume = g.Mass();
        gp_Pnt ctr = g.CentreOfMass();
        c.centre = {ctr.X(), ctr.Y(), ctr.Z()};
        out.push_back(c);
      } catch (const Standard_Failure&) {
      }
    }
  return out;
}

MassProperties AssemblyModel::massProperties() const {
  MassProperties m;
  double mx = 0, my = 0, mz = 0;
  for (auto& pc : placed_) {
    if (pc.part < 0) continue;
    MassProperties pm = parts_[static_cast<size_t>(pc.part)].model->massProperties();
    Vec3 c = transformPoint(pc.placement, pm.centreOfMass);
    m.volume += pm.volume;
    m.area += pm.area;
    m.mass += pm.mass;
    m.bodies += pm.bodies;
    mx += c[0] * pm.volume;
    my += c[1] * pm.volume;
    mz += c[2] * pm.volume;
  }
  if (m.volume > 0) m.centreOfMass = {mx / m.volume, my / m.volume, mz / m.volume};
  return m;
}

}  // namespace fpcad
