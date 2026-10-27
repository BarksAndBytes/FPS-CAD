#include "fpcad/Sketch.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <stdexcept>

namespace fpcad {
namespace {

constexpr double kPi = 3.14159265358979323846;

Vec3d cross(const Vec3d& a, const Vec3d& b) {
  return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
double dot(const Vec3d& a, const Vec3d& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
Vec3d unit(Vec3d a) {
  double n = std::sqrt(dot(a, a));
  if (n < 1e-15) throw std::invalid_argument("plane direction has zero length");
  return {a[0] / n, a[1] / n, a[2] / n};
}

Vec3d vec3(const Json& j, const char* what) {
  if (!j.is_array() || j.size() != 3) throw std::invalid_argument(std::string(what) + " must be [x, y, z]");
  return {j[0].get<double>(), j[1].get<double>(), j[2].get<double>()};
}

// Dense linear solve with partial pivoting. A is n×n row-major; b is overwritten with x.
bool solveDense(std::vector<double> A, std::vector<double>& b, int n) {
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
    double s = b[r];
    for (int k = r + 1; k < n; ++k) s -= A[r * n + k] * b[k];
    b[r] = s / A[r * n + r];
  }
  return true;
}

// Numerical rank of an m×n row-major matrix.
int rankOf(std::vector<double> M, int m, int n) {
  double scale = 0;
  for (double v : M) scale = std::max(scale, std::abs(v));
  if (scale == 0) return 0;
  const double tol = 1e-9 * scale * std::max(m, n);
  int rank = 0;
  std::vector<bool> used(static_cast<size_t>(m), false);
  for (int c = 0; c < n && rank < m; ++c) {
    int piv = -1;
    double best = tol;
    for (int r = 0; r < m; ++r)
      if (!used[r] && std::abs(M[r * n + c]) > best) { best = std::abs(M[r * n + c]); piv = r; }
    if (piv < 0) continue;
    used[piv] = true;
    ++rank;
    for (int r = 0; r < m; ++r) {
      if (r == piv) continue;
      double f = M[r * n + c] / M[piv * n + c];
      if (f == 0) continue;
      for (int k = c; k < n; ++k) M[r * n + k] -= f * M[piv * n + k];
    }
  }
  return rank;
}

double wrapAngle(double a) {
  while (a > kPi) a -= 2 * kPi;
  while (a < -kPi) a += 2 * kPi;
  return a;
}

const SketchPoint kOrigin{"o", 0, 0, true};

// Builds the unknown vector and the residual functions for one solve.
class System {
public:
  System(Sketch& s, const SketchValueFn& value) : s_(s), value_(value) {
    for (auto& p : s_.points) {
      if (p.fixed || p.id == "o") continue;
      pidx_[p.id] = static_cast<int>(X_.size());
      X_.push_back(p.x);
      X_.push_back(p.y);
    }
    for (auto& e : s_.entities) {
      if (e.kind != "circle") continue;
      ridx_[e.id] = static_cast<int>(X_.size());
      X_.push_back(e.r);
    }
    for (auto& e : s_.entities) {
      if (e.kind == "arc") {
        if (e.pts.size() != 3) throw std::invalid_argument("arc " + e.id + " needs centre, start and end");
        // Start and end stay on one circle.
        add("", [this, e](const V& X) { return dist(X, e.pts[0], e.pts[2]) - dist(X, e.pts[0], e.pts[1]); });
      } else if (e.kind == "line") {
        if (e.pts.size() != 2) throw std::invalid_argument("line " + e.id + " needs two points");
      } else if (e.kind == "circle") {
        if (e.pts.size() != 1) throw std::invalid_argument("circle " + e.id + " needs a centre");
      } else {
        throw std::invalid_argument("unknown sketch entity kind '" + e.kind + "'");
      }
      for (auto& id : e.pts) need(id);
    }
    for (auto& c : s_.constraints) addConstraint(c);
  }

  using V = std::vector<double>;

  SolveResult solve() {
    SolveResult res;
    const int n = static_cast<int>(X_.size());
    const int m = static_cast<int>(fns_.size());
    if (n == 0 || m == 0) {
      res.dof = n;
      write(X_);
      return res;
    }
    V X = X_;
    V r = eval(X);
    double cost = norm2(r);
    double lambda = 1e-9;
    for (int it = 0; it < 200 && std::sqrt(cost / m) > 1e-13; ++it) {
      V J = jacobian(X);
      V step(n, 0.0);
      bool solved;
      if (m < n) {
        // Minimum-norm step: δ = Jᵀ (J Jᵀ + λI)⁻¹ r keeps under-defined sketches near where they were.
        V A(static_cast<size_t>(m) * m, 0.0);
        for (int i = 0; i < m; ++i)
          for (int k = 0; k < m; ++k) {
            double sum = 0;
            for (int j = 0; j < n; ++j) sum += J[i * n + j] * J[k * n + j];
            A[i * m + k] = sum + (i == k ? lambda : 0.0);
          }
        V y = r;
        solved = solveDense(A, y, m);
        if (solved)
          for (int j = 0; j < n; ++j) {
            double sum = 0;
            for (int i = 0; i < m; ++i) sum += J[i * n + j] * y[i];
            step[j] = sum;
          }
      } else {
        V A(static_cast<size_t>(n) * n, 0.0);
        for (int a = 0; a < n; ++a)
          for (int b = 0; b < n; ++b) {
            double sum = 0;
            for (int i = 0; i < m; ++i) sum += J[i * n + a] * J[i * n + b];
            A[a * n + b] = sum + (a == b ? lambda : 0.0);
          }
        for (int j = 0; j < n; ++j) {
          double sum = 0;
          for (int i = 0; i < m; ++i) sum += J[i * n + j] * r[i];
          step[j] = sum;
        }
        solved = solveDense(A, step, n);
      }
      if (!solved) {
        lambda = std::max(lambda * 10, 1e-9);
        if (lambda > 1e6) break;
        continue;
      }
      V Xn(n);
      for (int j = 0; j < n; ++j) Xn[j] = X[j] - step[j];
      V rn = eval(Xn);
      double costn = norm2(rn);
      if (std::isfinite(costn) && costn < cost) {
        double moved = 0;
        for (double d : step) moved = std::max(moved, std::abs(d));
        X = Xn;
        r = rn;
        cost = costn;
        lambda = std::max(lambda * 0.1, 1e-12);
        if (moved < 1e-15) break;
      } else {
        lambda = std::max(lambda * 10, 1e-9);
        if (lambda > 1e6) break;
      }
    }
    write(X);
    res.residual = std::sqrt(cost / m);
    res.ok = res.residual < 1e-8;
    res.dof = n - rankOf(jacobian(X), m, n);
    if (!res.ok) {
      for (int i = 0; i < m; ++i)
        if (std::abs(r[i]) > 1e-7 && !owner_[i].empty() &&
            std::find(res.conflicts.begin(), res.conflicts.end(), owner_[i]) == res.conflicts.end())
          res.conflicts.push_back(owner_[i]);
      res.message = "these dimensions or relations conflict and cannot all be met";
    } else if (res.dof == 0) {
      res.message = "fully defined";
    } else {
      res.message = std::to_string(res.dof) + (res.dof == 1 ? " degree of freedom left" : " degrees of freedom left");
    }
    return res;
  }

private:
  struct P { double x, y; };

  // Const view, so lookups see the implicit origin "o".
  const Sketch& cs() const { return s_; }

  void need(const std::string& id) const {
    if (!cs().point(id)) throw std::invalid_argument("sketch point '" + id + "' does not exist");
  }

  P pt(const V& X, const std::string& id) const {
    auto it = pidx_.find(id);
    if (it != pidx_.end()) return {X[it->second], X[it->second + 1]};
    const SketchPoint* p = cs().point(id);
    return {p->x, p->y};
  }

  double dist(const V& X, const std::string& a, const std::string& b) const {
    P p = pt(X, a), q = pt(X, b);
    return std::hypot(q.x - p.x, q.y - p.y);
  }

  const SketchEntity& ent(const std::string& id, const char* kinds) const {
    const SketchEntity* e = s_.entity(id);
    if (!e) throw std::invalid_argument("sketch entity '" + id + "' does not exist");
    if (std::string(kinds).find(e->kind) == std::string::npos)
      throw std::invalid_argument("'" + id + "' is a " + e->kind + ", expected " + kinds);
    return *e;
  }

  // Radius of a circle (unknown) or an arc (centre to start).
  double radius(const V& X, const SketchEntity& e) const {
    if (e.kind == "circle") return X[ridx_.at(e.id)];
    return dist(X, e.pts[0], e.pts[1]);
  }

  // Length of a line, or radius of a circle/arc, for "equal".
  double size(const V& X, const SketchEntity& e) const {
    return e.kind == "line" ? dist(X, e.pts[0], e.pts[1]) : radius(X, e);
  }

  std::array<double, 2> dir(const V& X, const SketchEntity& l) const {
    P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]);
    return {b.x - a.x, b.y - a.y};
  }

  void add(const std::string& owner, std::function<double(const V&)> f) {
    fns_.push_back(std::move(f));
    owner_.push_back(owner);
  }

  void refs(const SketchConstraint& c, size_t n) const {
    if (c.refs.size() != n)
      throw std::invalid_argument(c.kind + " needs " + std::to_string(n) + " references");
  }

  void addConstraint(const SketchConstraint& c) {
    const std::string& k = c.kind;
    const std::string id = c.id.empty() ? k : c.id;
    auto val = [&](Quantity q) { return value_(c.value, q); };
    if (k == "horizontal" || k == "vertical") {
      refs(c, 1);
      const SketchEntity& l = ent(c.refs[0], "line");
      bool h = k == "horizontal";
      add(id, [this, l, h](const V& X) {
        P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]);
        return h ? b.y - a.y : b.x - a.x;
      });
    } else if (k == "coincident") {
      refs(c, 2);
      need(c.refs[0]);
      need(c.refs[1]);
      std::string p = c.refs[0], q = c.refs[1];
      add(id, [this, p, q](const V& X) { return pt(X, q).x - pt(X, p).x; });
      add(id, [this, p, q](const V& X) { return pt(X, q).y - pt(X, p).y; });
    } else if (k == "parallel" || k == "perpendicular") {
      refs(c, 2);
      const SketchEntity& l1 = ent(c.refs[0], "line");
      const SketchEntity& l2 = ent(c.refs[1], "line");
      bool par = k == "parallel";
      add(id, [this, l1, l2, par](const V& X) {
        auto d1 = dir(X, l1), d2 = dir(X, l2);
        double n = std::hypot(d1[0], d1[1]) * std::hypot(d2[0], d2[1]);
        if (n < 1e-30) return 0.0;
        return par ? (d1[0] * d2[1] - d1[1] * d2[0]) / n : (d1[0] * d2[0] + d1[1] * d2[1]) / n;
      });
    } else if (k == "equal") {
      refs(c, 2);
      const SketchEntity& a = ent(c.refs[0], "line circle arc");
      const SketchEntity& b = ent(c.refs[1], "line circle arc");
      add(id, [this, a, b](const V& X) { return size(X, b) - size(X, a); });
    } else if (k == "point_on_line") {
      refs(c, 2);
      need(c.refs[0]);
      const SketchEntity& l = ent(c.refs[1], "line");
      std::string p = c.refs[0];
      add(id, [this, p, l](const V& X) {
        P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]), q = pt(X, p);
        double len = std::hypot(b.x - a.x, b.y - a.y);
        if (len < 1e-30) return 0.0;
        return ((b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)) / len;
      });
    } else if (k == "point_on_circle") {
      refs(c, 2);
      need(c.refs[0]);
      const SketchEntity& e = ent(c.refs[1], "circle arc");
      std::string p = c.refs[0];
      add(id, [this, p, e](const V& X) { return dist(X, e.pts[0], p) - radius(X, e); });
    } else if (k == "midpoint") {
      refs(c, 2);
      need(c.refs[0]);
      const SketchEntity& l = ent(c.refs[1], "line");
      std::string p = c.refs[0];
      add(id, [this, p, l](const V& X) { return pt(X, p).x - 0.5 * (pt(X, l.pts[0]).x + pt(X, l.pts[1]).x); });
      add(id, [this, p, l](const V& X) { return pt(X, p).y - 0.5 * (pt(X, l.pts[0]).y + pt(X, l.pts[1]).y); });
    } else if (k == "tangent") {
      refs(c, 2);
      const SketchEntity& l = ent(c.refs[0], "line");
      const SketchEntity& e = ent(c.refs[1], "circle arc");
      add(id, [this, l, e](const V& X) {
        P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]), q = pt(X, e.pts[0]);
        double len = std::hypot(b.x - a.x, b.y - a.y);
        if (len < 1e-30) return 0.0;
        double d = std::abs((b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)) / len;
        return d - radius(X, e);
      });
    } else if (k == "fix") {
      refs(c, 1);
      need(c.refs[0]);
      const SketchPoint* p0 = cs().point(c.refs[0]);
      std::string p = c.refs[0];
      double x0 = p0->x, y0 = p0->y;
      add(id, [this, p, x0](const V& X) { return pt(X, p).x - x0; });
      add(id, [this, p, y0](const V& X) { return pt(X, p).y - y0; });
    } else if (k == "distance") {
      double d = val(Quantity::Length);
      if (c.refs.size() == 1) {
        const SketchEntity& l = ent(c.refs[0], "line");
        add(id, [this, l, d](const V& X) { return dist(X, l.pts[0], l.pts[1]) - d; });
      } else {
        refs(c, 2);
        need(c.refs[0]);
        need(c.refs[1]);
        std::string p = c.refs[0], q = c.refs[1];
        add(id, [this, p, q, d](const V& X) { return dist(X, p, q) - d; });
      }
    } else if (k == "hdistance" || k == "vdistance") {
      refs(c, 2);
      need(c.refs[0]);
      need(c.refs[1]);
      double d = val(Quantity::Length);
      std::string p = c.refs[0], q = c.refs[1];
      bool h = k == "hdistance";
      add(id, [this, p, q, d, h](const V& X) {
        return (h ? pt(X, q).x - pt(X, p).x : pt(X, q).y - pt(X, p).y) - d;
      });
    } else if (k == "radius" || k == "diameter") {
      refs(c, 1);
      const SketchEntity& e = ent(c.refs[0], "circle arc");
      double d = val(Quantity::Length) * (k == "diameter" ? 0.5 : 1.0);
      add(id, [this, e, d](const V& X) { return radius(X, e) - d; });
    } else if (k == "angle") {
      refs(c, 2);
      const SketchEntity& l1 = ent(c.refs[0], "line");
      const SketchEntity& l2 = ent(c.refs[1], "line");
      double a = val(Quantity::Angle);
      add(id, [this, l1, l2, a](const V& X) {
        auto d1 = dir(X, l1), d2 = dir(X, l2);
        double ang = std::atan2(d1[0] * d2[1] - d1[1] * d2[0], d1[0] * d2[0] + d1[1] * d2[1]);
        return wrapAngle(ang - a);
      });
    } else {
      throw std::invalid_argument("unknown sketch relation '" + k + "'");
    }
  }

  V eval(const V& X) const {
    V r(fns_.size());
    for (size_t i = 0; i < fns_.size(); ++i) r[i] = fns_[i](X);
    return r;
  }

  V jacobian(const V& X) const {
    const int n = static_cast<int>(X.size()), m = static_cast<int>(fns_.size());
    V J(static_cast<size_t>(m) * n, 0.0);
    V Y = X;
    for (int j = 0; j < n; ++j) {
      double h = 1e-7 * std::max(1.0, std::abs(X[j]));
      Y[j] = X[j] + h;
      V rp = eval(Y);
      Y[j] = X[j] - h;
      V rm = eval(Y);
      Y[j] = X[j];
      for (int i = 0; i < m; ++i) J[i * n + j] = (rp[i] - rm[i]) / (2 * h);
    }
    return J;
  }

  static double norm2(const V& r) {
    double s = 0;
    for (double v : r) s += v * v;
    return s;
  }

  void write(const V& X) {
    for (auto& p : s_.points) {
      auto it = pidx_.find(p.id);
      if (it == pidx_.end()) continue;
      p.x = X[it->second];
      p.y = X[it->second + 1];
    }
    for (auto& e : s_.entities) {
      auto it = ridx_.find(e.id);
      if (it != ridx_.end()) e.r = std::abs(X[it->second]);
    }
  }

  Sketch& s_;
  const SketchValueFn& value_;
  std::map<std::string, int> pidx_, ridx_;
  V X_;
  std::vector<std::function<double(const V&)>> fns_;
  std::vector<std::string> owner_;
};

}  // namespace

Vec3d SketchPlane::ydir() const { return cross(unit(normal), unit(xdir)); }

Vec3d SketchPlane::toWorld(double u, double v) const {
  Vec3d x = unit(xdir), y = ydir();
  return {origin[0] + u * x[0] + v * y[0], origin[1] + u * x[1] + v * y[1], origin[2] + u * x[2] + v * y[2]};
}

std::array<double, 2> SketchPlane::toPlane(const Vec3d& p) const {
  Vec3d d{p[0] - origin[0], p[1] - origin[1], p[2] - origin[2]};
  return {dot(d, unit(xdir)), dot(d, ydir())};
}

Json SketchPlane::toJson() const { return {{"origin", origin}, {"normal", normal}, {"xdir", xdir}}; }

SketchPlane SketchPlane::fromJson(const Json& j) {
  SketchPlane p;
  p.origin = vec3(j.at("origin"), "plane origin");
  p.normal = unit(vec3(j.at("normal"), "plane normal"));
  Vec3d x = vec3(j.at("xdir"), "plane xdir");
  // Keep xdir exactly in the plane.
  double d = dot(x, p.normal);
  x = {x[0] - d * p.normal[0], x[1] - d * p.normal[1], x[2] - d * p.normal[2]};
  p.xdir = unit(x);
  return p;
}

SketchPlane standardPlane(const std::string& name) {
  SketchPlane p;
  if (name == "top" || name == "Top") {
    p.normal = {0, 0, 1};
    p.xdir = {1, 0, 0};
  } else if (name == "front" || name == "Front") {
    p.normal = {0, -1, 0};
    p.xdir = {1, 0, 0};
  } else if (name == "right" || name == "Right") {
    p.normal = {1, 0, 0};
    p.xdir = {0, 1, 0};
  } else {
    throw std::invalid_argument("unknown standard plane '" + name + "' (use top, front or right)");
  }
  return p;
}

Sketch Sketch::fromJson(const Json& j) {
  Sketch s;
  s.plane = SketchPlane::fromJson(j.at("plane"));
  s.planeName = j.value("planeName", std::string("Plane"));
  for (auto& p : j.value("points", Json::array()))
    s.points.push_back({p.at("id").get<std::string>(), p.value("x", 0.0), p.value("y", 0.0), p.value("fixed", false)});
  for (auto& e : j.value("entities", Json::array())) {
    SketchEntity se;
    se.id = e.at("id").get<std::string>();
    se.kind = e.at("kind").get<std::string>();
    se.pts = e.value("pts", std::vector<std::string>{});
    se.r = e.value("r", 0.0);
    se.construction = e.value("construction", false);
    s.entities.push_back(se);
  }
  for (auto& c : j.value("constraints", Json::array())) {
    SketchConstraint sc;
    sc.id = c.value("id", std::string());
    sc.kind = c.at("kind").get<std::string>();
    sc.refs = c.value("refs", std::vector<std::string>{});
    sc.value = c.value("value", Json());
    s.constraints.push_back(sc);
  }
  return s;
}

Json Sketch::toJson() const {
  Json pts = Json::array(), ents = Json::array(), cons = Json::array();
  for (auto& p : points) {
    Json o = {{"id", p.id}, {"x", p.x}, {"y", p.y}};
    if (p.fixed) o["fixed"] = true;
    pts.push_back(o);
  }
  for (auto& e : entities) {
    Json o = {{"id", e.id}, {"kind", e.kind}, {"pts", e.pts}};
    if (e.kind == "circle") o["r"] = e.r;
    if (e.construction) o["construction"] = true;
    ents.push_back(o);
  }
  for (auto& c : constraints) {
    Json o = {{"id", c.id}, {"kind", c.kind}, {"refs", c.refs}};
    if (!c.value.is_null()) o["value"] = c.value;
    cons.push_back(o);
  }
  return {{"plane", plane.toJson()}, {"planeName", planeName}, {"points", pts}, {"entities", ents},
          {"constraints", cons}};
}

const SketchPoint* Sketch::point(const std::string& id) const {
  if (id == "o") return &kOrigin;
  for (auto& p : points) if (p.id == id) return &p;
  return nullptr;
}

SketchPoint* Sketch::point(const std::string& id) {
  for (auto& p : points) if (p.id == id) return &p;
  return nullptr;
}

const SketchEntity* Sketch::entity(const std::string& id) const {
  for (auto& e : entities) if (e.id == id) return &e;
  return nullptr;
}

SolveResult solveSketch(Sketch& s, const SketchValueFn& value) {
  try {
    System sys(s, value);
    return sys.solve();
  } catch (const std::exception& e) {
    SolveResult r;
    r.ok = false;
    r.message = e.what();
    return r;
  }
}

}  // namespace fpcad
