#include "fpcad/Sketch.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <set>
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
      if (e.kind != "circle" && e.kind != "ellipse" && e.kind != "text") continue;
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
      } else if (e.kind == "ellipse") {
        if (e.pts.size() != 2) throw std::invalid_argument("ellipse " + e.id + " needs a centre and an axis end");
      } else if (e.kind == "spline") {
        if (e.pts.size() < 2) throw std::invalid_argument("spline " + e.id + " needs at least two points");
      } else if (e.kind == "text") {
        if (e.pts.size() != 1) throw std::invalid_argument("text " + e.id + " needs an anchor point");
      } else {
        throw std::invalid_argument("unknown sketch entity kind '" + e.kind + "'");
      }
      for (auto& id : e.pts) need(id);
    }
    for (auto& c : s_.constraints) addConstraint(c);
    for (auto& p : s_.patterns) addPattern(p);
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

  // Radius of a circle (unknown) or an arc (centre to start); an ellipse's free semi-axis.
  double radius(const V& X, const SketchEntity& e) const {
    if (e.kind == "circle" || e.kind == "ellipse" || e.kind == "text") return X[ridx_.at(e.id)];
    return dist(X, e.pts[0], e.pts[1]);
  }

  // Length of a line, or radius of a circle/arc, for "equal".
  double size(const V& X, const SketchEntity& e) const {
    return e.kind == "line" ? dist(X, e.pts[0], e.pts[1]) : radius(X, e);
  }

  // End points of lines and arcs (an arc's centre is not an end).
  static std::vector<std::string> endsOf(const SketchEntity& e) {
    if (e.kind == "line") return e.pts;
    if (e.kind == "arc") return {e.pts[1], e.pts[2]};
    return {};
  }

  // A point id that ends both entities, or "".
  static std::string sharedEnd(const SketchEntity& a, const SketchEntity& b) {
    for (auto& p : endsOf(a))
      for (auto& q : endsOf(b))
        if (p == q) return p;
    return "";
  }

  // Signed distance of point p from the infinite line through l.
  double offLine(const V& X, const std::string& p, const SketchEntity& l) const {
    P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]), q = pt(X, p);
    double len = std::hypot(b.x - a.x, b.y - a.y);
    if (len < 1e-30) return 0.0;
    return ((b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)) / len;
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
      bool h = k == "horizontal";
      if (c.refs.size() == 2) {  // two points level with each other, or one above the other
        need(c.refs[0]);
        need(c.refs[1]);
        std::string p = c.refs[0], q = c.refs[1];
        add(id, [this, p, q, h](const V& X) { return h ? pt(X, q).y - pt(X, p).y : pt(X, q).x - pt(X, p).x; });
        return;
      }
      refs(c, 1);
      const SketchEntity& l = ent(c.refs[0], "line");
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
    } else if (k == "collinear") {
      refs(c, 2);
      const SketchEntity& l1 = ent(c.refs[0], "line");
      const SketchEntity& l2 = ent(c.refs[1], "line");
      for (int end = 0; end < 2; ++end) {
        std::string p = l2.pts[end];
        add(id, [this, p, l1](const V& X) { return offLine(X, p, l1); });
      }
    } else if (k == "concentric") {
      refs(c, 2);
      std::string p = ent(c.refs[0], "circle arc ellipse").pts[0];
      std::string q = ent(c.refs[1], "circle arc ellipse").pts[0];
      add(id, [this, p, q](const V& X) { return pt(X, q).x - pt(X, p).x; });
      add(id, [this, p, q](const V& X) { return pt(X, q).y - pt(X, p).y; });
    } else if (k == "symmetric") {
      refs(c, 3);
      need(c.refs[0]);
      need(c.refs[1]);
      const SketchEntity& l = ent(c.refs[2], "line");
      std::string p = c.refs[0], q = c.refs[1];
      // The midpoint lies on the line, and the two points are square across it.
      add(id, [this, p, q, l](const V& X) {
        P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]), u = pt(X, p), w = pt(X, q);
        double len = std::hypot(b.x - a.x, b.y - a.y);
        if (len < 1e-30) return 0.0;
        double mx = 0.5 * (u.x + w.x), my = 0.5 * (u.y + w.y);
        return ((b.x - a.x) * (my - a.y) - (b.y - a.y) * (mx - a.x)) / len;
      });
      add(id, [this, p, q, l](const V& X) {
        P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]), u = pt(X, p), w = pt(X, q);
        double len = std::hypot(b.x - a.x, b.y - a.y);
        if (len < 1e-30) return 0.0;
        return ((b.x - a.x) * (w.x - u.x) + (b.y - a.y) * (w.y - u.y)) / len;
      });
    } else if (k == "equal") {
      refs(c, 2);
      const SketchEntity& a = ent(c.refs[0], "line circle arc ellipse");
      const SketchEntity& b = ent(c.refs[1], "line circle arc ellipse");
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
    } else if (k == "tangent" && c.refs.size() == 2 && s_.entity(c.refs[0]) && s_.entity(c.refs[1]) &&
               (s_.entity(c.refs[0])->kind == "spline" || s_.entity(c.refs[1])->kind == "spline")) {
      // Shapes the spline (its end leaves along the other's direction) rather than moving points.
      const SketchEntity& a = *s_.entity(c.refs[0]);
      const SketchEntity& b = *s_.entity(c.refs[1]);
      const SketchEntity& sp = a.kind == "spline" ? a : b;
      const SketchEntity& other = a.kind == "spline" ? b : a;
      if (other.kind != "line" && other.kind != "arc")
        throw std::invalid_argument("a spline can be tangent to a line or an arc");
      bool joined = false;
      for (auto& q : endsOf(other))
        if (q == sp.pts.front() || q == sp.pts.back()) joined = true;
      if (!joined) throw std::invalid_argument("a spline is tangent where it shares an end with the line or arc");
    } else if (k == "tangent" && s_.entity(c.refs.empty() ? "" : c.refs[0]) &&
               s_.entity(c.refs[0])->kind != "line") {
      // Two circles or arcs touching: centres r1 + r2 apart (outside) or |r1 − r2| (inside),
      // whichever the geometry is nearer to now, so the relation never flips a curve over.
      refs(c, 2);
      const SketchEntity& e1 = ent(c.refs[0], "circle arc");
      const SketchEntity& e2 = ent(c.refs[1], "circle arc");
      std::string joint = sharedEnd(e1, e2);
      if (!joint.empty()) {
        // Joined end to end: both centres in line with the joint. (Distances between centres
        // would only touch their target, giving the solver no slope to follow.)
        add(id, [this, e1, e2, joint](const V& X) {
          P j = pt(X, joint), a = pt(X, e1.pts[0]), b = pt(X, e2.pts[0]);
          double ax = a.x - j.x, ay = a.y - j.y, bx = b.x - j.x, by = b.y - j.y;
          double n = std::hypot(ax, ay) * std::hypot(bx, by);
          return n < 1e-30 ? 0.0 : (ax * by - ay * bx) / n;
        });
        return;
      }
      double d0 = dist(X_, e1.pts[0], e2.pts[0]), r1 = radius(X_, e1), r2 = radius(X_, e2);
      bool outside = std::abs(d0 - (r1 + r2)) <= std::abs(d0 - std::abs(r1 - r2));
      add(id, [this, e1, e2, outside](const V& X) {
        double d = dist(X, e1.pts[0], e2.pts[0]), a = radius(X, e1), b = radius(X, e2);
        return outside ? d - (a + b) : d - std::abs(a - b);
      });
    } else if (k == "tangent") {
      refs(c, 2);
      const SketchEntity& l = ent(c.refs[0], "line");
      const SketchEntity& e = ent(c.refs[1], "circle arc");
      std::string joint = sharedEnd(l, e);
      if (!joint.empty()) {
        // Line and arc joined at an end: the radius there is square to the line.
        add(id, [this, l, e, joint](const V& X) {
          P a = pt(X, l.pts[0]), b = pt(X, l.pts[1]), j = pt(X, joint), q = pt(X, e.pts[0]);
          double dx = b.x - a.x, dy = b.y - a.y, rx = j.x - q.x, ry = j.y - q.y;
          double n = std::hypot(dx, dy) * std::hypot(rx, ry);
          return n < 1e-30 ? 0.0 : (dx * rx + dy * ry) / n;
        });
        return;
      }
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
      const SketchEntity* e0 = c.refs.empty() ? nullptr : s_.entity(c.refs[0]);
      const SketchEntity* e1 = c.refs.size() < 2 ? nullptr : s_.entity(c.refs[1]);
      if (c.refs.size() == 1 && e0 && e0->kind == "text") {
        const SketchEntity& t = *e0;
        add(id, [this, t, d](const V& X) { return radius(X, t) - d; });
      } else if (c.refs.size() == 1) {
        const SketchEntity& l = ent(c.refs[0], "line");
        add(id, [this, l, d](const V& X) { return dist(X, l.pts[0], l.pts[1]) - d; });
      } else if (e0 || e1) {
        // Square to a line: from a point, or between two parallel lines (from the second line's
        // first point to the first line).
        refs(c, 2);
        const SketchEntity& l = e1 ? ent(c.refs[1], "line") : ent(c.refs[0], "line");
        std::string p;
        if (e0 && e1) p = ent(c.refs[0], "line").pts[0];
        else p = e1 ? c.refs[0] : c.refs[1];
        need(p);
        add(id, [this, p, l, d](const V& X) { return std::abs(offLine(X, p, l)) - d; });
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
      const SketchEntity& e = ent(c.refs[0], "circle arc ellipse");
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

  // Every copy point follows its source point through the pattern's move; copied circles,
  // ellipses and text keep their source's size.
  void addPattern(const SketchPattern& p) {
    if (p.count < 2) return;
    const bool circular = p.kind == "circular";
    double dx = 0, dy = 0, step = 0;
    if (circular) {
      if (!cs().point(p.centre)) return;  // its centre was deleted: the copies are gone too
      double total = p.total.is_null() ? 2 * kPi : value_(p.total, Quantity::Angle);
      step = std::abs(total - 2 * kPi) < 1e-9 ? total / p.count : total / (p.count - 1);
    } else {
      double sp = value_(p.spacing, Quantity::Length);
      double an = p.angle.is_null() ? 0.0 : value_(p.angle, Quantity::Angle);
      dx = sp * std::cos(an);
      dy = sp * std::sin(an);
    }
    std::set<std::string> srcPts;
    for (auto& eid : p.entities)
      if (const SketchEntity* e = s_.entity(eid))
        for (auto& q : e->pts) srcPts.insert(q);
    for (int k = 1; k < p.count; ++k) {
      std::string pre = p.id + "." + std::to_string(k) + ".";
      for (auto& sp : srcPts) {
        std::string cp = pre + sp;
        if (!cs().point(cp)) continue;
        if (circular) {
          std::string ctr = p.centre;
          double ca = std::cos(step * k), sa = std::sin(step * k);
          add(p.id, [this, sp, cp, ctr, ca, sa](const V& X) {
            P c = pt(X, ctr), a = pt(X, sp);
            return pt(X, cp).x - (c.x + ca * (a.x - c.x) - sa * (a.y - c.y));
          });
          add(p.id, [this, sp, cp, ctr, ca, sa](const V& X) {
            P c = pt(X, ctr), a = pt(X, sp);
            return pt(X, cp).y - (c.y + sa * (a.x - c.x) + ca * (a.y - c.y));
          });
        } else {
          double ox = dx * k, oy = dy * k;
          add(p.id, [this, sp, cp, ox](const V& X) { return pt(X, cp).x - pt(X, sp).x - ox; });
          add(p.id, [this, sp, cp, oy](const V& X) { return pt(X, cp).y - pt(X, sp).y - oy; });
        }
      }
      for (auto& eid : p.entities) {
        const SketchEntity* src = s_.entity(eid);
        const SketchEntity* cpy = s_.entity(pre + eid);
        if (!src || !cpy || !ridx_.count(src->id) || !ridx_.count(cpy->id)) continue;
        int a = ridx_.at(src->id), b = ridx_.at(cpy->id);
        add(p.id, [a, b](const V& X) { return X[b] - X[a]; });
      }
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
    se.pattern = e.value("pattern", std::string());
    se.text = e.value("text", std::string());
    for (auto& c : e.value("contours", Json::array())) {
      std::vector<std::array<double, 2>> poly;
      for (auto& q : c) poly.push_back({q.at(0).get<double>(), q.at(1).get<double>()});
      se.contours.push_back(poly);
    }
    s.entities.push_back(se);
  }
  for (auto& p : j.value("patterns", Json::array())) {
    SketchPattern sp;
    sp.id = p.at("id").get<std::string>();
    sp.kind = p.value("kind", std::string("linear"));
    sp.entities = p.value("entities", std::vector<std::string>{});
    sp.count = p.value("count", 2);
    sp.spacing = p.value("spacing", Json());
    sp.angle = p.value("angle", Json());
    sp.centre = p.value("centre", std::string());
    sp.total = p.value("total", Json());
    s.patterns.push_back(sp);
  }
  for (auto& l : j.value("links", Json::array())) {
    SketchLink sl;
    sl.id = l.at("id").get<std::string>();
    auto v3 = [&](const char* k, std::array<double, 3> d) {
      if (!l.contains(k)) return d;
      const Json& a = l.at(k);
      return std::array<double, 3>{a.at(0).get<double>(), a.at(1).get<double>(), a.at(2).get<double>()};
    };
    sl.probe = v3("probe", sl.probe);
    sl.normal = v3("normal", sl.normal);
    sl.feature = l.value("feature", std::string());
    sl.entities = l.value("entities", std::vector<std::string>{});
    sl.points = l.value("points", std::vector<std::string>{});
    s.links.push_back(sl);
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
    if (e.kind == "circle" || e.kind == "ellipse" || e.kind == "text") o["r"] = e.r;
    if (e.construction) o["construction"] = true;
    if (!e.pattern.empty()) o["pattern"] = e.pattern;
    if (e.kind == "text") {
      o["text"] = e.text;
      Json cs = Json::array();
      for (auto& c : e.contours) {
        Json poly = Json::array();
        for (auto& q : c) poly.push_back({q[0], q[1]});
        cs.push_back(poly);
      }
      o["contours"] = cs;
    }
    ents.push_back(o);
  }
  Json pats = Json::array(), links = Json::array();
  for (auto& p : patterns) {
    Json o = {{"id", p.id}, {"kind", p.kind}, {"entities", p.entities}, {"count", p.count}};
    if (!p.spacing.is_null()) o["spacing"] = p.spacing;
    if (!p.angle.is_null()) o["angle"] = p.angle;
    if (!p.centre.empty()) o["centre"] = p.centre;
    if (!p.total.is_null()) o["total"] = p.total;
    pats.push_back(o);
  }
  for (auto& l : this->links) {
    Json o = {{"id", l.id}, {"probe", l.probe}, {"normal", l.normal}, {"entities", l.entities}, {"points", l.points}};
    if (!l.feature.empty()) o["feature"] = l.feature;
    links.push_back(o);
  }
  for (auto& c : constraints) {
    Json o = {{"id", c.id}, {"kind", c.kind}, {"refs", c.refs}};
    if (!c.value.is_null()) o["value"] = c.value;
    cons.push_back(o);
  }
  Json out = {{"plane", plane.toJson()}, {"planeName", planeName}, {"points", pts}, {"entities", ents},
              {"constraints", cons}};
  if (!patterns.empty()) out["patterns"] = pats;
  if (!this->links.empty()) out["links"] = links;
  return out;
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

std::string freshSketchId(const Sketch& s, const std::string& prefix) {
  std::set<std::string> used{"o"};
  for (auto& p : s.points) used.insert(p.id);
  for (auto& e : s.entities) used.insert(e.id);
  for (auto& c : s.constraints) used.insert(c.id);
  for (auto& p : s.patterns) used.insert(p.id);
  for (auto& l : s.links) used.insert(l.id);
  for (int i = 1;; ++i) {
    std::string id = prefix + std::to_string(i);
    if (!used.count(id)) return id;
  }
}

void expandPatterns(Sketch& s, const SketchValueFn& value) {
  const Sketch& cs = s;  // lookups that see the origin "o"
  // What every pattern should have: copy entities and copy points, with fresh positions.
  std::map<std::string, SketchEntity> want;
  std::map<std::string, std::array<double, 2>> wantPts;
  std::set<std::string> srcIds;
  for (auto& p : s.patterns) {
    if (p.count < 2) continue;
    bool circular = p.kind == "circular";
    double dx = 0, dy = 0, step = 0, cx = 0, cy = 0;
    try {
      if (circular) {
        const SketchPoint* c = cs.point(p.centre);
        if (!c) continue;
        cx = c->x;
        cy = c->y;
        double total = p.total.is_null() ? 2 * kPi : value(p.total, Quantity::Angle);
        step = std::abs(total - 2 * kPi) < 1e-9 ? total / p.count : total / (p.count - 1);
      } else {
        double sp = value(p.spacing, Quantity::Length);
        double an = p.angle.is_null() ? 0.0 : value(p.angle, Quantity::Angle);
        dx = sp * std::cos(an);
        dy = sp * std::sin(an);
      }
    } catch (const std::exception&) {
      continue;  // the solve reports the bad value
    }
    for (int k = 1; k < p.count; ++k) {
      std::string pre = p.id + "." + std::to_string(k) + ".";
      double ca = std::cos(step * k), sa = std::sin(step * k);
      for (auto& eid : p.entities) {
        const SketchEntity* src = s.entity(eid);
        if (!src || !src->pattern.empty()) continue;
        SketchEntity e = *src;
        e.id = pre + eid;
        e.pattern = p.id;
        for (auto& q : e.pts) {
          const SketchPoint* sp = cs.point(q);
          if (!sp) continue;
          std::array<double, 2> to = circular
              ? std::array<double, 2>{cx + ca * (sp->x - cx) - sa * (sp->y - cy), cy + sa * (sp->x - cx) + ca * (sp->y - cy)}
              : std::array<double, 2>{sp->x + dx * k, sp->y + dy * k};
          wantPts[pre + q] = to;
          q = pre + q;
        }
        want[e.id] = e;
      }
    }
  }
  // Remove stale copies and their points, add or refresh the rest.
  std::set<std::string> gone;
  std::vector<SketchEntity> ents;
  for (auto& e : s.entities) {
    if (!e.pattern.empty() && !want.count(e.id)) { gone.insert(e.id); continue; }
    if (want.count(e.id)) {
      SketchEntity w = want[e.id];
      w.construction = e.construction;  // a copy can be switched to construction on its own
      if (e.r > 0 && e.kind == w.kind) w.r = e.r;
      ents.push_back(w);
      want.erase(e.id);
    } else {
      ents.push_back(e);
    }
  }
  for (auto& [id, e] : want) ents.push_back(e);
  s.entities = ents;
  std::vector<SketchPoint> pts;
  for (auto& p : s.points) {
    bool copy = p.id.find('.') != std::string::npos;
    if (copy && !wantPts.count(p.id)) { gone.insert(p.id); continue; }
    if (copy) {
      p.x = wantPts[p.id][0];
      p.y = wantPts[p.id][1];
      p.fixed = false;
      wantPts.erase(p.id);
    }
    pts.push_back(p);
  }
  for (auto& [id, at] : wantPts) pts.push_back({id, at[0], at[1], false});
  s.points = pts;
  if (!gone.empty()) {
    std::vector<SketchConstraint> keep;
    for (auto& c : s.constraints) {
      bool drop = false;
      for (auto& r : c.refs) drop = drop || gone.count(r);
      if (!drop) keep.push_back(c);
    }
    s.constraints = keep;
  }
}

SolveResult solveSketch(Sketch& s, const SketchValueFn& value) {
  try {
    expandPatterns(s, value);
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
