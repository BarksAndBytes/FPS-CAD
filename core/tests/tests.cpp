// Headless tests for the CAD core: expressions, rebuild, picking, push/pull, native files and
// every export format with read-back validation.

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

#include <miniz.h>

#include "fpcad/Assembly.h"
#include "fpcad/Export.h"
#include "fpcad/Expression.h"
#include "fpcad/FileIO.h"
#include <chrono>

#include "fpcad/Model.h"
#include "fpcad/Sketch.h"
#include "fpcad/Challenges.h"
#include "fpcad/Compare.h"
#include "../src/CompareShapes.h"

#include <BRepBuilderAPI_Transform.hxx>
#include <gp_Ax1.hxx>
#include <gp_Trsf.hxx>

using namespace fpcad;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(cond)                                                                  \
  do {                                                                               \
    ++checks;                                                                        \
    if (!(cond)) {                                                                   \
      ++failures;                                                                    \
      std::fprintf(stderr, "  FAILED %s:%d  %s\n", __FILE__, __LINE__, #cond);       \
    }                                                                                \
  } while (0)

#define CHECK_NEAR(a, b, tol) CHECK(std::abs((a) - (b)) <= (tol))

template <class F>
bool throws(F f) {
  try {
    f();
  } catch (...) {
    return true;
  }
  return false;
}

void run(const char* name, const std::function<void()>& t) {
  int before = failures;
  try {
    t();
  } catch (const std::exception& e) {
    ++failures;
    std::fprintf(stderr, "  FAILED %s threw: %s\n", name, e.what());
  }
  std::printf("%s %s\n", failures == before ? "PASS" : "FAIL", name);
}

const Feature& named(const PartModel& m, const std::string& name) {
  for (auto& f : m.document().features) if (f.name == name) return f;
  throw std::runtime_error("no feature " + name);
}

std::string zipEntry(const std::string& path, const std::string& name) {
  mz_zip_archive z;
  mz_zip_zero_struct(&z);
  if (!mz_zip_reader_init_file(&z, path.c_str(), 0)) return {};
  size_t n = 0;
  void* p = mz_zip_reader_extract_file_to_heap(&z, name.c_str(), &n, 0);
  std::string s = p ? std::string(static_cast<char*>(p), n) : std::string();
  if (p) mz_free(p);
  mz_zip_reader_end(&z);
  return s;
}

size_t count(const std::string& hay, const std::string& needle) {
  size_t n = 0;
  for (size_t p = hay.find(needle); p != std::string::npos; p = hay.find(needle, p + 1)) ++n;
  return n;
}

constexpr double kSampleVolume = 84.474;  // m^3, from the sample's dimensions (see tests notes)

// A w×h rectangle with its lower-left corner at (x, y), held by horizontal/vertical relations and
// two length dimensions. When x = y = 0 the corner is the sketch origin, so it is fully defined.
Json rectSketch(const SketchPlane& plane, double x, double y, double w, double h, const std::string& tag = "r") {
  bool atOrigin = x == 0 && y == 0;
  std::string a = atOrigin ? "o" : tag + "a";
  Json pts = Json::array();
  if (!atOrigin) pts.push_back({{"id", a}, {"x", x}, {"y", y}});
  pts.push_back({{"id", tag + "b"}, {"x", x + w}, {"y", y}});
  pts.push_back({{"id", tag + "c"}, {"x", x + w}, {"y", y + h}});
  pts.push_back({{"id", tag + "d"}, {"x", x}, {"y", y + h}});
  std::string b = tag + "b", c = tag + "c", d = tag + "d";
  Json ents = Json::array({
      {{"id", tag + "1"}, {"kind", "line"}, {"pts", {a, b}}},
      {{"id", tag + "2"}, {"kind", "line"}, {"pts", {b, c}}},
      {{"id", tag + "3"}, {"kind", "line"}, {"pts", {c, d}}},
      {{"id", tag + "4"}, {"kind", "line"}, {"pts", {d, a}}}});
  Json cons = Json::array({
      {{"id", tag + "h1"}, {"kind", "horizontal"}, {"refs", {tag + "1"}}},
      {{"id", tag + "v2"}, {"kind", "vertical"}, {"refs", {tag + "2"}}},
      {{"id", tag + "h3"}, {"kind", "horizontal"}, {"refs", {tag + "3"}}},
      {{"id", tag + "v4"}, {"kind", "vertical"}, {"refs", {tag + "4"}}},
      {{"id", tag + "w"}, {"kind", "distance"}, {"refs", {tag + "1"}}, {"value", w}},
      {{"id", tag + "hh"}, {"kind", "distance"}, {"refs", {tag + "2"}}, {"value", h}}});
  return {{"plane", plane.toJson()}, {"planeName", "Top"}, {"points", pts}, {"entities", ents}, {"constraints", cons}};
}

Json circleSketch(const SketchPlane& plane, double cx, double cy, double r) {
  return {{"plane", plane.toJson()},
          {"planeName", "Plane"},
          {"points", Json::array({{{"id", "c"}, {"x", cx}, {"y", cy}}})},
          {"entities", Json::array({{{"id", "k"}, {"kind", "circle"}, {"pts", {"c"}}, {"r", r}}})},
          {"constraints", Json::array({{{"id", "kd"}, {"kind", "diameter"}, {"refs", {"k"}}, {"value", 2 * r}}})}};
}

Feature feature(const char* type, Json params, BodyOp op = BodyOp::Add) {
  Feature f;
  f.type = type;
  f.op = op;
  f.params = std::move(params);
  return f;
}

constexpr double kPiT = 3.14159265358979323846;

}  // namespace

namespace fs = std::filesystem;

int main() {
  fs::path out = fs::temp_directory_path() / "fpcad-tests";
  fs::remove_all(out);
  fs::create_directories(out);

  run("expressions", [] {
    VariableTable v{{"w", 0.1}};
    CHECK_NEAR(evaluate("12", v, Quantity::Length, 1e-3), 0.012, 1e-12);
    CHECK_NEAR(evaluate("12 mm", v, Quantity::Length, 1.0), 0.012, 1e-12);
    CHECK_NEAR(evaluate("2in", v, Quantity::Length, 1e-3), 0.0508, 1e-12);
    CHECK_NEAR(evaluate("w / 2 + 3 mm", v, Quantity::Length, 1e-3), 0.053, 1e-12);
    CHECK_NEAR(evaluate("w / 2 + 3", v, Quantity::Length, 1e-3), 0.053, 1e-12);
    CHECK_NEAR(evaluate("2 * (w + 10 mm)", v, Quantity::Length, 1e-3), 0.22, 1e-12);
    CHECK_NEAR(evaluate("-(5) cm", v, Quantity::Length, 1e-3), -0.05, 1e-12);
    CHECK_NEAR(evaluate("30 deg", v, Quantity::Angle, 1e-3), std::acos(-1.0) / 6, 1e-12);
    CHECK_NEAR(evaluate("4", v, Quantity::Count, 1e-3), 4.0, 1e-12);
    CHECK(throws([&] { evaluate("foo + 1", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("1 / 0", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("(1 + 2", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("5 mm mm", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("", v, Quantity::Length, 1e-3); }));
  });

  run("sample part rebuilds into one valid solid", [] {
    PartModel m(PartDocument::sample());
    auto r = m.rebuild();
    for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s: %s\n", st.featureId.c_str(), st.message.c_str());
    CHECK(r.ok);
    CHECK(m.bodyCount() == 1);
    auto mp = m.massProperties();
    CHECK_NEAR(mp.volume, kSampleVolume, 0.05);
    CHECK_NEAR(mp.mass, mp.volume * 2700, 1e-6);
  });

  run("training course builds with an open crawl tunnel", [] {
    PartModel m(PartDocument::trainingCourse());
    auto r = m.rebuild();
    CHECK(r.ok);
    CHECK(m.bodyCount() == 5);
    // At 15 cm off the ground the tunnel is open all the way through the wall...
    CHECK(!m.pick({0, -3, 0.15}, {0, 1, 0}, 6));
    // ...but at 1 m, or 40 cm to the side, the wall stops you.
    auto wall = m.pick({0, -3, 1.0}, {0, 1, 0}, 6);
    CHECK(wall && std::abs(wall->point[1] - (-0.5)) < 1e-6);
    CHECK(m.pick({0.4, -3, 0.15}, {0, 1, 0}, 6));
    // The step is 80 cm high and the lift block's top face drives its height.
    auto step = m.pick({0, -6, 5}, {0, 0, -1});
    CHECK(step && std::abs(step->point[2] - 0.8) < 1e-6);
    auto lift = m.pick({3, 5, 5}, {0, 0, -1});
    auto drive = lift ? m.faceDrive(*lift) : std::nullopt;
    CHECK(drive && drive->param == "+h" && std::abs(drive->value - 1.0) < 1e-9);
  });


  run("sketch solver: dimensions drive a rectangle and count freedom", [] {
    auto noVars = [](const Json& v, Quantity) { return v.get<double>(); };
    Sketch s = Sketch::fromJson(rectSketch(standardPlane("top"), 0, 0, 1.0, 0.5));
    // Start from a sloppy drawing: the solver should square it up to the dimensions.
    s.point("rb")->x = 0.9;  s.point("rb")->y = 0.07;
    s.point("rc")->x = 1.2;  s.point("rc")->y = 0.4;
    s.point("rd")->x = -0.1; s.point("rd")->y = 0.6;
    SolveResult r = solveSketch(s, noVars);
    CHECK(r.ok);
    CHECK(r.dof == 0);
    CHECK_NEAR(s.point("rc")->x, 1.0, 1e-9);
    CHECK_NEAR(s.point("rc")->y, 0.5, 1e-9);
    CHECK_NEAR(s.point("rd")->x, 0.0, 1e-9);

    Sketch loose = Sketch::fromJson(rectSketch(standardPlane("top"), 0.2, 0.2, 1.0, 0.5));
    CHECK(solveSketch(loose, noVars).dof == 2);  // the rectangle can still slide
    loose.constraints.pop_back();
    CHECK(solveSketch(loose, noVars).dof == 3);  // ...and change height

    Sketch conflict = Sketch::fromJson(rectSketch(standardPlane("top"), 0, 0, 1.0, 0.5));
    conflict.constraints.push_back({"bad", "distance", {"r3"}, 2.0});  // opposite side 2 m long
    SolveResult c = solveSketch(conflict, noVars);
    CHECK(!c.ok);
    CHECK(!c.conflicts.empty());

    Sketch circ = Sketch::fromJson(circleSketch(standardPlane("top"), 0.3, 0.1, 0.2));
    circ.entities[0].r = 0.5;
    SolveResult cr = solveSketch(circ, noVars);
    CHECK(cr.ok && cr.dof == 2);
    CHECK_NEAR(circ.entities[0].r, 0.2, 1e-9);
  });

  run("sketch relations: symmetric, collinear, concentric, tangent curves, distances", [] {
    auto noVars = [](const Json& v, Quantity) { return v.get<double>(); };
    auto P = [](const char* id, double x, double y, bool fixed = false) {
      Json p = {{"id", id}, {"x", x}, {"y", y}};
      if (fixed) p["fixed"] = true;
      return p;
    };
    auto E = [](const char* id, const char* kind, std::vector<std::string> pts, double r = 0) {
      Json e = {{"id", id}, {"kind", kind}, {"pts", pts}};
      if (r > 0) e["r"] = r;
      return e;
    };
    auto C = [](const char* kind, std::vector<std::string> refs, Json value = Json()) {
      Json c = {{"id", std::string("c_") + kind}, {"kind", kind}, {"refs", refs}};
      if (!value.is_null()) c["value"] = value;
      return c;
    };
    Json base = {{"plane", standardPlane("top").toJson()}, {"planeName", "Top"}};

    // Symmetric about a vertical axis through the origin.
    Json j = base;
    j["points"] = Json::array({P("a0", 0, 0, true), P("a1", 0, 1, true), P("p", -0.3, 0.2, true), P("q", 0.25, 0.3)});
    j["entities"] = Json::array({E("ax", "line", {"a0", "a1"})});
    j["constraints"] = Json::array({C("symmetric", {"p", "q", "ax"})});
    Sketch s = Sketch::fromJson(j);
    CHECK(solveSketch(s, noVars).ok);
    CHECK_NEAR(s.point("q")->x, 0.3, 1e-9);
    CHECK_NEAR(s.point("q")->y, 0.2, 1e-9);

    // Collinear lines, a point square-distance from a line, and two points level.
    j = base;
    j["points"] = Json::array({P("a", 0, 0, true), P("b", 1, 0, true), P("c", 2, 0.1), P("d", 3, -0.2), P("e", 0.5, 0.9),
                   P("f", 4, 1.1)});
    j["entities"] = Json::array({E("l1", "line", {"a", "b"}), E("l2", "line", {"c", "d"})});
    j["constraints"] = Json::array({C("collinear", {"l1", "l2"}), C("distance", {"e", "l1"}, 0.75),
                        C("horizontal", {"e", "f"})});
    s = Sketch::fromJson(j);
    CHECK(solveSketch(s, noVars).ok);
    CHECK_NEAR(s.point("c")->y, 0.0, 1e-9);
    CHECK_NEAR(s.point("d")->y, 0.0, 1e-9);
    CHECK_NEAR(s.point("e")->y, 0.75, 1e-9);
    CHECK_NEAR(s.point("f")->y, 0.75, 1e-9);

    // Distance between two parallel lines.
    j = base;
    j["points"] = Json::array({P("a", 0, 0, true), P("b", 1, 0, true), P("c", 0, 0.4), P("d", 1, 0.45)});
    j["entities"] = Json::array({E("l1", "line", {"a", "b"}), E("l2", "line", {"c", "d"})});
    j["constraints"] = Json::array({C("parallel", {"l1", "l2"}), C("distance", {"l1", "l2"}, 0.5)});
    s = Sketch::fromJson(j);
    CHECK(solveSketch(s, noVars).ok);
    CHECK_NEAR(s.point("c")->y, 0.5, 1e-9);
    CHECK_NEAR(s.point("d")->y, 0.5, 1e-9);

    // Concentric circles, and circles tangent outside and inside.
    j = base;
    j["points"] = Json::array({P("o1", 0, 0, true), P("o2", 0.05, 0.02), P("o3", 1.1, 0), P("o4", 0.2, 0.1)});
    j["entities"] = Json::array({E("k1", "circle", {"o1"}, 0.5), E("k2", "circle", {"o2"}, 0.2), E("k3", "circle", {"o3"}, 0.4),
                     E("k4", "circle", {"o4"}, 0.2)});
    j["constraints"] = Json::array({C("concentric", {"k1", "k2"}), C("tangent", {"k1", "k3"}), C("tangent", {"k1", "k4"}),
                        C("radius", {"k1"}, 0.5), C("radius", {"k3"}, 0.4), C("radius", {"k4"}, 0.2)});
    j["constraints"][1]["id"] = "t1";
    j["constraints"][2]["id"] = "t2";
    j["constraints"][3]["id"] = "r1";
    j["constraints"][4]["id"] = "r3";
    j["constraints"][5]["id"] = "r4";
    s = Sketch::fromJson(j);
    CHECK(solveSketch(s, noVars).ok);
    CHECK_NEAR(std::hypot(s.point("o2")->x, s.point("o2")->y), 0.0, 1e-9);
    CHECK_NEAR(std::hypot(s.point("o3")->x, s.point("o3")->y), 0.9, 1e-9);  // outside: 0.5 + 0.4
    CHECK_NEAR(std::hypot(s.point("o4")->x, s.point("o4")->y), 0.3, 1e-9);  // inside: 0.5 − 0.2

    // Tangent where a line and an arc share an end: one freedom taken, no more, no less.
    j = base;
    j["points"] = Json::array({P("a", 0, 0, true), P("jn", 1, 0), P("c", 1, 0.5), P("e", 1.5, 0.5)});
    j["entities"] = Json::array({E("l", "line", {"a", "jn"}), E("arc", "arc", {"c", "jn", "e"})});
    j["constraints"] = Json::array({C("tangent", {"l", "arc"})});
    s = Sketch::fromJson(j);
    SolveResult tr = solveSketch(s, noVars);
    CHECK(tr.ok && tr.dof == 4);
    // Two arcs joined end to end and tangent: their centres stay in line with the joint.
    j["points"].push_back(P("c2", 1.5, 1.0));
    j["points"].push_back(P("f", 2.0, 0.5));
    j["entities"].push_back(E("arc2", "arc", {"c2", "f", "e"}));
    j["constraints"].push_back({{"id", "t2"}, {"kind", "tangent"}, {"refs", {"arc", "arc2"}}});
    s = Sketch::fromJson(j);
    tr = solveSketch(s, noVars);
    CHECK(tr.ok && tr.dof == 6);
  });

  run("ellipses and splines make profiles; faces project onto sketches", [] {
    auto noVars = [](const Json& v, Quantity) { return v.get<double>(); };
    PartDocument d;
    Json el = {{"plane", standardPlane("top").toJson()}, {"planeName", "Top"}};
    el["points"] = Json::array({{{"id", "c"}, {"x", 0}, {"y", 0}}, {{"id", "m"}, {"x", 0.0}, {"y", 0.3}}});
    el["entities"] = Json::array({{{"id", "e"}, {"kind", "ellipse"}, {"pts", {"c", "m"}}, {"r", 0.5}}});
    std::string sid = d.add(feature("sketch", el)).id;
    d.add(feature("extrude", {{"sketch", sid}, {"depth", 0.1}}));
    PartModel m(d);
    CHECK(m.rebuild().ok && m.bodyCount() == 1);
    CHECK_NEAR(m.massProperties().volume, kPiT * 0.5 * 0.3 * 0.1, 1e-6);

    // An open spline closed by a line is a profile; a closed spline is one on its own.
    Json sp = {{"plane", standardPlane("top").toJson()}, {"planeName", "Top"}};
    sp["points"] = Json::array({{{"id", "a"}, {"x", 0}, {"y", 0}}, {{"id", "b"}, {"x", 0.5}, {"y", 0.4}},
                    {{"id", "c"}, {"x", 1.0}, {"y", 0.0}}});
    sp["entities"] = Json::array({{{"id", "s"}, {"kind", "spline"}, {"pts", {"a", "b", "c"}}},
                      {{"id", "l"}, {"kind", "line"}, {"pts", {"c", "a"}}}});
    Sketch open = Sketch::fromJson(sp);
    CHECK(solveSketch(open, noVars).ok);
    CHECK(!sketchFill(open).empty());
    auto curves = sketchCurves(open);
    CHECK(curves.size() == 2 && curves[0].points.size() > 10);
    Json ring = sp;
    ring["points"].push_back({{"id", "d"}, {"x", 0.5}, {"y", -0.4}});
    ring["entities"] = Json::array({{{"id", "s"}, {"kind", "spline"}, {"pts", {"a", "b", "c", "d", "a"}}}});
    Sketch closed = Sketch::fromJson(ring);
    CHECK(!sketchFill(closed).empty());
    PartDocument d2;
    std::string rid = d2.add(feature("sketch", ring)).id;
    d2.add(feature("extrude", {{"sketch", rid}, {"depth", 0.1}}));
    PartModel m2(d2);
    CHECK(m2.rebuild().ok && m2.bodyCount() == 1);
    CHECK(m2.massProperties().volume > 0.02 && m2.massProperties().volume < 0.1);

    // Project: a box's top face gives four lines; the ellipse's top face one spline.
    PartModel box(PartDocument::sample());
    CHECK(box.rebuild().ok);
    auto hit = box.pick({0, 0, 50}, {0, 0, -1});
    CHECK(hit.has_value());
    if (hit) {
      SketchPlane top = standardPlane("top");
      auto pc = box.projectFace(hit->body, hit->face, top);
      CHECK(!pc.empty());
    }
    auto ehit = m.pick({0, 0, 5}, {0, 0, -1});
    CHECK(ehit.has_value());
    if (ehit) {
      auto pc = m.projectFace(ehit->body, ehit->face, standardPlane("top"));
      CHECK(pc.size() == 1 && pc[0].kind == "spline" && pc[0].closed);
    }
    // A cylinder's flat end projects to a true circle.
    PartDocument cyl;
    Json ck = circleSketch(standardPlane("top"), 0.2, 0.1, 0.25);
    std::string kid = cyl.add(feature("sketch", ck)).id;
    cyl.add(feature("extrude", {{"sketch", kid}, {"depth", 0.3}}));
    PartModel cm(cyl);
    CHECK(cm.rebuild().ok);
    auto chit = cm.pick({0.2, 0.1, 5}, {0, 0, -1});
    if (chit) {
      auto pc = cm.projectFace(chit->body, chit->face, standardPlane("front"));
      // Seen edge-on from the front the circle flattens into a line.
      CHECK(pc.size() == 1 && pc[0].kind == "line");
      pc = cm.projectFace(chit->body, chit->face, standardPlane("top"));
      CHECK(pc.size() == 1 && pc[0].kind == "circle");
      CHECK(pc.size() == 1 && std::abs(pc[0].r - 0.25) < 1e-9 && std::abs(pc[0].pts[0][0] - 0.2) < 1e-9);
    }
  });

  run("sketch patterns regenerate and follow their sources; spline end tangency; text", [] {
    auto noVars = [](const Json& v, Quantity) { return v.get<double>(); };
    Json j = {{"plane", standardPlane("top").toJson()}, {"planeName", "Top"}};
    j["points"] = Json::array({{{"id", "c"}, {"x", 1.0}, {"y", 0.0}}});
    j["entities"] = Json::array({{{"id", "k"}, {"kind", "circle"}, {"pts", {"c"}}, {"r", 0.1}}});
    j["constraints"] = Json::array({{{"id", "r"}, {"kind", "radius"}, {"refs", {"k"}}, {"value", 0.1}}});
    j["patterns"] = Json::array({{{"id", "pt1"}, {"kind", "circular"}, {"entities", {"k"}}, {"count", 4}, {"centre", "o"}}});
    Sketch s = Sketch::fromJson(j);
    SolveResult r = solveSketch(s, noVars);
    CHECK(r.ok && s.entities.size() == 4);
    const SketchPoint* q = static_cast<const Sketch&>(s).point("pt1.1.c");
    CHECK(q && std::abs(q->x) < 1e-9 && std::abs(q->y - 1.0) < 1e-9);
    CHECK(r.dof == 2);  // only the source circle's centre is free; the copies follow
    // Moving the source moves the copies; a bigger radius grows them; fewer copies are removed.
    s.point("c")->x = 2.0;
    s.constraints[0].value = 0.2;
    s.patterns[0].count = 3;
    r = solveSketch(s, noVars);
    CHECK(r.ok && s.entities.size() == 3);
    const SketchPoint* q2 = static_cast<const Sketch&>(s).point("pt1.1.c");
    CHECK(q2 && std::abs(std::hypot(q2->x, q2->y) - 2.0) < 1e-9);
    CHECK(std::abs(s.entities.back().r - 0.2) < 1e-9);
    // A linear pattern of a square, three across: the profiles extrude as three blocks.
    Json sq = rectSketch(standardPlane("top"), 0, 0, 0.1, 0.1);
    std::vector<std::string> sides;
    for (auto& e : sq["entities"]) sides.push_back(e["id"].get<std::string>());
    sq["patterns"] = Json::array({{{"id", "pl"}, {"kind", "linear"}, {"entities", sides}, {"count", 3}, {"spacing", 0.25}, {"angle", 0.0}}});
    PartDocument d;
    std::string sid = d.add(feature("sketch", sq)).id;
    d.add(feature("extrude", {{"sketch", sid}, {"depth", 0.1}}));
    PartModel m(d);
    CHECK(m.rebuild().ok);
    CHECK_NEAR(m.massProperties().volume, 3 * 0.001, 1e-9);

    // A spline leaving a line's end carries on in the line's direction.
    Json sp = {{"plane", standardPlane("top").toJson()}, {"planeName", "Top"}};
    sp["points"] = Json::array({{{"id", "a"}, {"x", 0}, {"y", 0}}, {{"id", "b"}, {"x", 1}, {"y", 0}},
                                {{"id", "m"}, {"x", 1.5}, {"y", 0.8}}, {{"id", "e"}, {"x", 2}, {"y", 0}}});
    sp["entities"] = Json::array({{{"id", "l"}, {"kind", "line"}, {"pts", {"a", "b"}}},
                                  {{"id", "s"}, {"kind", "spline"}, {"pts", {"b", "m", "e"}}}});
    sp["constraints"] = Json::array({{{"id", "t"}, {"kind", "tangent"}, {"refs", {"s", "l"}}}});
    Sketch ts = Sketch::fromJson(sp);
    CHECK(solveSketch(ts, noVars).ok);
    auto curves = sketchCurves(ts);
    CHECK(curves.size() == 2 && curves[1].points.size() > 2);
    if (curves.size() == 2 && curves[1].points.size() > 2) {
      auto p0 = curves[1].points[0], p1 = curves[1].points[1];
      CHECK(std::abs(p1[1] - p0[1]) < 0.15 * std::abs(p1[0] - p0[0]));  // leaves heading along +x (untangent: ~3)
    }

    // Text: a square letter with a square hole, 20 mm cap height, as a profile with a hole.
    Json tx = {{"plane", standardPlane("top").toJson()}, {"planeName", "Top"}};
    tx["points"] = Json::array({{{"id", "t0"}, {"x", 0}, {"y", 0}}});
    Json outer = Json::array({{0, 0}, {1, 0}, {1, 1}, {0, 1}}), inner = Json::array({{0.25, 0.25}, {0.25, 0.75}, {0.75, 0.75}, {0.75, 0.25}});
    tx["entities"] = Json::array({{{"id", "x"}, {"kind", "text"}, {"pts", {"t0"}}, {"r", 0.02}, {"text", "O"},
                                   {"contours", Json::array({outer, inner})}}});
    tx["constraints"] = Json::array({{{"id", "h"}, {"kind", "distance"}, {"refs", {"x"}}, {"value", 0.02}}});
    PartDocument d3;
    std::string tid = d3.add(feature("sketch", tx)).id;
    d3.add(feature("extrude", {{"sketch", tid}, {"depth", 0.01}}));
    PartModel m3(d3);
    CHECK(m3.rebuild().ok);
    CHECK_NEAR(m3.massProperties().volume, (0.02 * 0.02 - 0.01 * 0.01) * 0.01, 1e-12);
  });

  run("converted edges follow the model when it changes", [] {
    // A plate from a sketch, then a sketch on its top face with the face's edges converted.
    PartDocument d;
    d.variables = {{"w", "200 mm"}};
    Json plate = rectSketch(standardPlane("top"), 0, 0, 0.2, 0.1);
    plate["constraints"][4]["value"] = "w";
    std::string pid = d.add(feature("sketch", plate)).id;
    d.add(feature("extrude", {{"sketch", pid}, {"depth", 0.02}}));
    PartModel m(d);
    CHECK(m.rebuild().ok);
    auto top = m.pick({0.05, 0.05, 5}, {0, 0, -1});
    CHECK(top.has_value());
    if (!top) return;
    SketchPlane pl = standardPlane("top");
    pl.origin = {0, 0, 0.02};
    Sketch s;
    s.plane = pl;
    CHECK(m.convertFace(s, top->body, top->face, top->point));
    CHECK(s.entities.size() == 4 && s.links.size() == 1 && s.links[0].entities.size() == 4);
    Json sj = s.toJson();
    std::string ids0 = s.links[0].entities[0];
    m.document().add(feature("sketch", sj));
    CHECK(m.rebuild().ok);
    // Widen the plate: the converted outline widens with it, keeping its entity ids.
    for (auto& v : m.document().variables) v.expr = "300 mm";
    CHECK(m.rebuild().ok);
    Sketch after = Sketch::fromJson(m.document().features.back().params);
    double maxX = 0;
    for (auto& p : after.points) maxX = std::max(maxX, p.x);
    CHECK_NEAR(maxX, 0.3, 1e-9);
    CHECK(after.entities.size() == 4 && after.entity(ids0) != nullptr);
  });

  run("push/pull adds or removes stock on faces with no driving dimension", [] {
    PartDocument d;
    d.variables = {{"w", "1000 mm"}};
    Json sk = rectSketch(standardPlane("top"), 0, 0, 1.0, 0.5);
    sk["constraints"][4]["value"] = "w";
    std::string sid = d.add(feature("sketch", sk)).id;
    d.add(feature("extrude", {{"sketch", sid}, {"depth", 0.5}}));
    PartModel m(d);
    CHECK(m.rebuild().ok);
    // The side face at x = 1 is the sketch's, not the extrude's: nothing drives it.
    auto side = m.pick({5, 0.25, 0.25}, {-1, 0, 0});
    CHECK(side && !m.faceDrive(*side));
    if (!side) return;
    CHECK(m.pushPull(*side, 0.1));
    CHECK_NEAR(m.massProperties().volume, 0.25 + 0.1 * 0.25, 1e-9);
    CHECK(m.document().features.size() == 3 && m.document().features.back().type == "face_offset");
    CHECK(m.document().features.back().name == "Push/Pull 1");
    // Holding on the same spot grows the same push.
    CHECK(m.pushPull(*side, 0.1));
    CHECK(m.document().features.size() == 3);
    CHECK_NEAR(m.massProperties().volume, 0.25 + 0.2 * 0.25, 1e-9);
    // The pushed face now drives its distance; pushing it back past the start removes stock.
    auto moved = m.pick({5, 0.25, 0.25}, {-1, 0, 0});
    auto drv = moved ? m.faceDrive(*moved) : std::nullopt;
    CHECK(drv && drv->param == "distance" && std::abs(drv->value - 0.2) < 1e-9);
    if (moved) CHECK(m.pushPull(*moved, -0.3));
    CHECK_NEAR(m.massProperties().volume, 0.25 - 0.1 * 0.25, 1e-9);
    // Widening the sketch moves the face; the push follows it.
    for (auto& v : m.document().variables) v.expr = "1500 mm";
    CHECK(m.rebuild().ok);
    CHECK_NEAR(m.massProperties().volume, 1.5 * 0.25 - 0.1 * 0.25, 1e-9);
    // A curved face grows round: a cylinder from a circle sketch, its side pushed out 50 mm.
    PartDocument c;
    std::string kid = c.add(feature("sketch", circleSketch(standardPlane("top"), 0, 0, 0.25))).id;
    c.add(feature("extrude", {{"sketch", kid}, {"depth", 0.3}}));
    PartModel cm(c);
    CHECK(cm.rebuild().ok);
    auto round = cm.pick({5, 0, 0.15}, {-1, 0, 0});
    CHECK(round && !cm.faceDrive(*round));
    if (round) CHECK(cm.pushPull(*round, 0.05));
    CHECK_NEAR(cm.massProperties().volume, kPiT * 0.3 * 0.3 * 0.3, 1e-6);
  });

  run("sketch extrude follows its dimensions and variables", [] {
    PartDocument d;
    d.variables = {{"width", "1000 mm"}};
    Json sk = rectSketch(standardPlane("top"), 0, 0, 1.0, 0.5);
    sk["constraints"][4]["value"] = "width";
    Feature& sketch = d.add(feature("sketch", sk));
    std::string sid = sketch.id;
    d.add(feature("extrude", {{"sketch", sid}, {"depth", 0.5}}));
    PartModel m(d);
    auto r = m.rebuild();
    for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s\n", st.message.c_str());
    CHECK(r.ok && m.bodyCount() == 1);
    CHECK_NEAR(m.massProperties().volume, 0.25, 1e-9);
    for (auto& v : m.document().variables) v.expr = "2000 mm";
    CHECK(m.rebuild().ok);
    CHECK_NEAR(m.massProperties().volume, 0.5, 1e-9);
    // Solved positions are written back into the history.
    CHECK_NEAR(m.document().features[0].params["points"][1]["x"].get<double>(), 2.0, 1e-9);
    auto views = m.sketchViews();
    CHECK(views.size() == 1 && views[0].consumed && views[0].dof == 0 && views[0].regions == 1);
    CHECK(views[0].fill.size() >= 6 && views[0].fill.size() % 3 == 0);  // the rectangle, shaded
    CHECK(views[0].segments.size() == 8);
    CHECK(m.latestUnusedSketch().empty());

    // The top face drives depth; pushing it grows the extrude.
    auto top = m.pick({0.5, 0.25, 5}, {0, 0, -1});
    auto drive = top ? m.faceDrive(*top) : std::nullopt;
    CHECK(drive && drive->param == "+depth" && std::abs(drive->value - 0.5) < 1e-9);
    CHECK(top && m.pushPull(*top, 0.25));
    CHECK_NEAR(m.massProperties().volume, 0.75, 1e-9);
    // The bottom face moves the start: pulling it down 0.1 m adds 0.1 m of height.
    auto bottom = m.pick({0.5, 0.25, -5}, {0, 0, 1});
    CHECK(bottom && m.pushPull(*bottom, 0.1));
    CHECK_NEAR(m.massProperties().volume, 0.85 * 2 * 0.5 / 1.0 * 1.0, 1e-9);
    auto low = m.pick({0.5, 0.25, -5}, {0, 0, 1});
    CHECK(low && std::abs(low->point[2] - (-0.1)) < 1e-9);
  });

  run("profiles with holes, cut extrudes through all, sketches on faces", [] {
    PartDocument d;
    Json plate = rectSketch(standardPlane("top"), 0, 0, 2.0, 1.0);
    plate["points"].push_back({{"id", "hc"}, {"x", 1.0}, {"y", 0.5}});
    plate["entities"].push_back({{"id", "hole"}, {"kind", "circle"}, {"pts", {"hc"}}, {"r", 0.2}});
    std::string sid = d.add(feature("sketch", plate)).id;
    d.add(feature("extrude", {{"sketch", sid}, {"depth", 0.1}}));
    PartModel m(d);
    CHECK(m.rebuild().ok);
    CHECK_NEAR(m.massProperties().volume, (2.0 - kPiT * 0.04) * 0.1, 1e-6);
    {
      // Shading covers the plate minus the hole; construction geometry does not close a loop.
      Sketch sk = Sketch::fromJson(plate);
      solveSketch(sk, [](const Json& v, Quantity) { return v.get<double>(); });
      auto tris = sketchFill(sk);
      double area = 0;
      for (size_t i = 0; i + 2 < tris.size(); i += 3) {
        auto& a = tris[i];
        auto& b = tris[i + 1];
        auto& c = tris[i + 2];
        area += std::abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) / 2;
      }
      CHECK_NEAR(area, 2.0 - kPiT * 0.04, 2e-3);
      for (auto& e : sk.entities) e.construction = true;
      CHECK(sketchFill(sk).empty());
    }

    // Sketch on the plate's top face and cut a slot through everything.
    auto top = m.pick({0.3, 0.3, 5}, {0, 0, -1});
    std::string planeName;
    auto plane = top ? m.planeFromHit(*top, &planeName) : std::nullopt;
    CHECK(plane && std::abs(plane->normal[2] - 1) < 1e-12 && std::abs(plane->origin[2] - 0.1) < 1e-12);
    CHECK(planeName.rfind("Face of", 0) == 0);
    Json slot = circleSketch(*plane, 0.4, 0.5, 0.1);
    std::string cid = m.document().add(feature("sketch", slot)).id;
    m.document().add(feature("extrude", {{"sketch", cid}, {"end", "through_all"}, {"direction", "reverse"}}, BodyOp::Cut));
    auto r = m.rebuild();
    CHECK(r.ok);
    CHECK_NEAR(m.massProperties().volume, (2.0 - kPiT * 0.04 - kPiT * 0.01) * 0.1, 1e-6);
    // A curved face gives no sketch plane.
    auto side = m.pick({1.0, 0.5, 0.05}, {1, 0, 0});
    CHECK(side && !m.planeFromHit(*side));
  });

  run("revolve, sweep and loft from sketches", [] {
    // Revolve: a 0.5 × 1 rectangle 0.5 m from the axis makes a tube.
    {
      PartDocument d;
      std::string sid = d.add(feature("sketch", rectSketch(standardPlane("front"), 0.5, 0, 0.5, 1.0))).id;
      d.add(feature("revolve", {{"sketch", sid}, {"axis", "y"}}));
      PartModel m(d);
      CHECK(m.rebuild().ok);
      CHECK_NEAR(m.massProperties().volume, kPiT * (1.0 - 0.25) * 1.0, 1e-6);
      m.document().features[1].params["angle"] = "90 deg";
      CHECK(m.rebuild().ok);
      CHECK_NEAR(m.massProperties().volume, kPiT * 0.75 / 4, 1e-6);
    }
    // Sweep: a 0.1 m circle along a straight 1 m path, then along a quarter arc.
    {
      PartDocument d;
      std::string prof = d.add(feature("sketch", circleSketch(standardPlane("front"), 0, 0, 0.1))).id;
      Json path = {{"plane", standardPlane("top").toJson()},
                   {"points", Json::array({{{"id", "e"}, {"x", 0}, {"y", 1}}})},
                   {"entities", Json::array({{{"id", "l"}, {"kind", "line"}, {"pts", {"o", "e"}}}})},
                   {"constraints", Json::array()}};
      std::string pid = d.add(feature("sketch", path)).id;
      d.add(feature("sweep", {{"sketch", prof}, {"path", pid}}));
      PartModel m(d);
      auto r = m.rebuild();
      for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s\n", st.message.c_str());
      CHECK(r.ok);
      CHECK_NEAR(m.massProperties().volume, kPiT * 0.01 * 1.0, 1e-6);
      // Quarter arc of radius 0.5 centred at (0.5, 0): from the origin round to (0.5, 0.5).
      Json arc = {{"plane", standardPlane("top").toJson()},
                  {"points", Json::array({{{"id", "ac"}, {"x", 0.5}, {"y", 0}}, {{"id", "ae"}, {"x", 0.5}, {"y", 0.5}}})},
                  {"entities", Json::array({{{"id", "a"}, {"kind", "arc"}, {"pts", {"ac", "ae", "o"}}}})},
                  {"constraints", Json::array()}};
      m.document().features[1].params = arc;
      r = m.rebuild();
      for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s\n", st.message.c_str());
      CHECK(r.ok);
      CHECK_NEAR(m.massProperties().volume, kPiT * 0.01 * (kPiT / 2 * 0.5), 1e-4);
    }
    // Loft: a 1 m square at the bottom to a 0.4 m circle 1 m above.
    {
      PartDocument d;
      std::string a = d.add(feature("sketch", rectSketch(standardPlane("top"), -0.5, -0.5, 1, 1))).id;
      SketchPlane up = standardPlane("top");
      up.origin = {0, 0, 1};
      std::string b = d.add(feature("sketch", circleSketch(up, 0, 0, 0.2))).id;
      d.add(feature("loft", {{"sketches", {a, b}}}));
      PartModel m(d);
      auto r = m.rebuild();
      for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s\n", st.message.c_str());
      CHECK(r.ok && m.bodyCount() == 1);
      double v = m.massProperties().volume;
      CHECK(v > kPiT * 0.04 && v < 1.0);
    }
  });

  run("sketch picking, problems and file round-trip", [&] {
    PartDocument d;
    std::string sid = d.add(feature("sketch", rectSketch(standardPlane("top"), 0, 0, 1, 1))).id;
    Json open = {{"plane", standardPlane("top").toJson()},
                 {"points", Json::array({{{"id", "q"}, {"x", 3}, {"y", 0}}})},
                 {"entities", Json::array({{{"id", "l"}, {"kind", "line"}, {"pts", {"o", "q"}}}})},
                 {"constraints", Json::array()}};
    std::string oid = d.add(feature("sketch", open)).id;
    d.add(feature("extrude", {{"sketch", oid}, {"depth", 1}}));
    PartModel m(d);
    auto r = m.rebuild();
    CHECK(!r.ok);
    CHECK(r.features[2].message.find("no closed profile") != std::string::npos);
    auto hit = m.pickSketch({0.5, 0.5, 2}, {0, 0, -1}, 10, 0.01);
    CHECK(hit && hit->featureId == sid && hit->region == 0);
    auto nearLine = m.pickSketch({2.0, 0.005, 1}, {0, 0, -1}, 10, 0.02, true);
    CHECK(nearLine && nearLine->featureId == oid && nearLine->region == -1);
    CHECK(!m.pickSketch({5, 5, 1}, {0, 0, -1}, 10, 0.01));
    CHECK(m.latestUnusedSketch() == sid);

    std::string path = (fs::temp_directory_path() / "fpcad-tests" / "sketch.fpprt").string();
    savePart(path, m.document(), &m);
    PartModel back(loadPart(path));
    back.rebuild();
    CHECK(back.document().features[0].type == "sketch");
    CHECK(back.sketchViews().size() == 2);
  });


  run("challenge targets build, and copies match however they are made or turned", [] {
    auto list = challenges();
    CHECK(list.size() == 10);
    for (auto& c : list) {
      PartModel m(c.target);
      auto r = m.rebuild();
      for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s: %s\n", c.id.c_str(), st.message.c_str());
      CHECK(r.ok && m.bodyCount() == 1);
      CHECK(!c.callouts.empty() && !c.brief.empty());
      // The same solid, turned about a skew axis and moved, is a match; built from itself.
      gp_Trsf t;
      t.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(1, 2, 3)), 0.65);
      gp_Trsf mv;
      mv.SetTranslation(gp_Vec(0.4, -0.3, 0.2));
      TopoDS_Shape turned = BRepBuilderAPI_Transform(m.body(0), mv * t, true).Shape();
      auto t0 = std::chrono::steady_clock::now();
      ShapeMatch sm = compareShapes(turned, m.body(0));
      double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
      std::printf("    %-18s compared in %.0f ms%s\n", c.id.c_str(), ms, sm.match ? "" : ("  " + sm.message).c_str());
      CHECK(sm.match);
    }

    PartModel block(list[0].target);
    block.rebuild();
    auto box = [](double w, double d, double h, double x = 0, double y = 0, double z = 0) {
      Feature f;
      f.type = "box";
      f.params = {{"x", x}, {"y", y}, {"z", z}, {"w", w}, {"d", d}, {"h", h}};
      return f;
    };
    // Built another way: lying on its side somewhere else.
    PartDocument d1;
    d1.add(box(0.05, 0.1, 0.075, 0.3, 0.2, 0.01));
    PartModel m1(d1);
    m1.rebuild();
    CHECK(compareParts(m1, block).match);
    // Built from two halves that meet: still one block.
    PartDocument d2;
    d2.add(box(0.1, 0.075, 0.02));
    d2.add(box(0.1, 0.075, 0.03, 0, 0, 0.02));
    PartModel m2(d2);
    m2.rebuild();
    CHECK(compareParts(m2, block).match);
    // 5 mm short: not a match, and the hint says by how much.
    PartDocument d3;
    d3.add(box(0.1, 0.075, 0.045));
    PartModel m3(d3);
    m3.rebuild();
    ShapeMatch short3 = compareParts(m3, block);
    CHECK(!short3.match && std::abs(short3.volumeRatio - 0.9) < 1e-6);
    CHECK(short3.message.find("90%") != std::string::npos);
    PartModel nothing{PartDocument{}};
    nothing.rebuild();
    CHECK(compareParts(nothing, block).empty);

    // The hole has to be in the right place, not just the right size.
    PartModel plate(list[2].target);
    plate.rebuild();
    PartDocument d4;
    d4.add(box(0.15, 0.1, 0.025));
    Feature hole;
    hole.type = "cylinder";
    hole.op = BodyOp::Cut;
    hole.params = {{"x", 0.03}, {"y", 0}, {"z", -0.001}, {"r", 0.025}, {"h", 0.027}};
    d4.add(hole);
    PartModel m4(d4);
    m4.rebuild();
    ShapeMatch off = compareParts(m4, plate);
    CHECK(!off.match && !off.mirrored);

    // A mirror image is recognised but does not pass: a block with a blind hole off two axes.
    PartDocument d5;
    d5.add(box(0.1, 0.06, 0.04));
    Feature blind;
    blind.type = "cylinder";
    blind.op = BodyOp::Cut;
    blind.params = {{"x", 0.02}, {"y", 0.01}, {"z", 0.03}, {"r", 0.006}, {"h", 0.02}};
    d5.add(blind);
    PartModel m5(d5);
    m5.rebuild();
    gp_Trsf mirror;
    mirror.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0)));
    TopoDS_Shape flipped = BRepBuilderAPI_Transform(m5.body(0), mirror, true).Shape();
    ShapeMatch mm = compareShapes(flipped, m5.body(0));
    CHECK(!mm.match && mm.mirrored);
  });

  run("the desk organiser sample rebuilds from its variables", [] {
    PartModel m(PartDocument::deskSample());
    auto r = m.rebuild();
    for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s\n", st.message.c_str());
    CHECK(r.ok && m.bodyCount() == 1);
    double v = m.massProperties().volume;
    CHECK(v > 0.0003 && v < 0.0012);
    for (auto& var : m.document().variables)
      if (var.name == "width") var.expr = "300 mm";
    CHECK(m.rebuild().ok && m.massProperties().volume > v);
  });

  run("display mesh tags every face with its feature", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    BodyMesh mesh = m.mesh(0, 0.01);
    CHECK(mesh.indices.size() > 300);
    CHECK(mesh.indices.size() == mesh.triangleFace.size() * 3);
    CHECK(mesh.positions.size() == mesh.normals.size());
    CHECK(!mesh.edgeLines.empty());
    bool allTagged = !mesh.faces.empty();
    for (auto& f : mesh.faces) allTagged = allTagged && !f.featureId.empty();
    CHECK(allTagged);
  });

  run("picking finds the right feature and face drive", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    auto roof = m.pick({0.3, 0, 10}, {0, 0, -1});
    CHECK(roof && roof->featureId == named(m, "Roof").id);
    CHECK(roof && std::abs(roof->point[2] - 3.7) < 1e-6);
    CHECK(roof && roof->normal[2] > 0.99);
    auto drive = roof ? m.faceDrive(*roof) : std::nullopt;
    CHECK(drive && drive->param == "+h" && std::abs(drive->value - 0.3) < 1e-9);

    auto column = m.pick({2.6, -10, 2}, {0, 1, 0});
    CHECK(column && column->featureId == named(m, "Column 1").id);
    auto cd = column ? m.faceDrive(*column) : std::nullopt;
    CHECK(cd && cd->param == "r" && std::abs(cd->value - 0.3) < 1e-9);

    auto door = m.pick({-2.5, 1, 1.5}, {1, 0, 0});  // from inside the doorway toward its side
    CHECK(door && door->featureId == named(m, "Doorway").id);
    auto dd = door ? m.faceDrive(*door) : std::nullopt;
    CHECK(dd && dd->param == "p+w");
    CHECK(!m.pick({100, 100, 100}, {1, 0, 0}));
  });

  run("push/pull edits the driving parameter", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    double v0 = m.massProperties().volume;
    auto roof = m.pick({0.3, 0, 10}, {0, 0, -1});
    std::string msg;
    CHECK(roof && m.pushPull(*roof, 0.1, &msg));
    CHECK_NEAR(m.param(named(m, "Roof"), "h"), 0.4, 1e-9);
    CHECK_NEAR(m.massProperties().volume - v0, 9 * 6.2 * 0.1, 0.01);

    // Pushing a doorway wall out into the opening narrows the doorway; pulling widens it.
    auto door = m.pick({-2.5, 1, 1.5}, {1, 0, 0});
    double v1 = m.massProperties().volume;
    CHECK(door && m.pushPull(*door, 0.1, &msg));
    CHECK_NEAR(m.massProperties().volume - v1, 0.1 * 2.2 * 4, 1e-6);
    auto moved = m.pick({-2.5, 1, 1.5}, {1, 0, 0});
    CHECK(moved && std::abs(moved->point[0] - (-2.0)) < 1e-6);
    auto other = m.pick({-2.5, 1, 1.5}, {-1, 0, 0});  // the opposite wall stayed put
    CHECK(other && std::abs(other->point[0] - (-3.1)) < 1e-6);
    CHECK(moved && m.pushPull(*moved, -0.3, &msg));
    CHECK_NEAR(named(m, "Doorway").params["profile"]["w"].get<double>(), 1.4, 1e-9);

    auto bottom = m.pick({0, -2, -5}, {0, 0, 1});  // underside of the plinth
    CHECK(bottom && m.pushPull(*bottom, 0.05, &msg));
    CHECK_NEAR(m.param(named(m, "Plinth"), "z"), -0.05, 1e-9);
    CHECK_NEAR(m.param(named(m, "Plinth"), "h"), 0.45, 1e-9);
  });

  run("a broken edit is refused and rolled back", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    double v0 = m.massProperties().volume;
    auto roof = m.pick({-4.0, -2.9, 10}, {0, 0, -1});  // near a filleted corner of the roof
    (void)roof;
    // Grow the roof fillet far past what the slab can take.
    PickHit fake;
    fake.featureId = named(m, "Roof corners").id;
    fake.normal = {1, 0, 0};
    std::string msg;
    CHECK(!m.pushPull(fake, 50.0, &msg));
    CHECK(!msg.empty());
    CHECK(m.lastReport().ok);
    CHECK_NEAR(m.massProperties().volume, v0, 1e-9);
  });

  run("variables drive dependent features", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    double v0 = m.massProperties().volume;
    for (auto& v : m.document().variables) if (v.name == "storey") v.expr = "4000 mm";
    CHECK(m.rebuild().ok);
    // Core grows by 4x4x1 and the two columns by pi r^2 x 1; the roof rides up.
    double expected = 16 + 2 * std::acos(-1.0) * 0.09;
    CHECK_NEAR(m.massProperties().volume - v0, expected, 1e-6);
    CHECK_NEAR(m.variables().at("storey"), 4.0, 1e-12);
    for (auto& v : m.document().variables) if (v.name == "storey") v.expr = "nonsense +";
    CHECK(!m.rebuild().ok);
  });

  run("failed features are reported, not fatal", [] {
    PartModel m(PartDocument::sample());
    for (auto& f : m.document().features) if (f.type == "fillet") f.params["r"] = 5.0;
    auto r = m.rebuild();
    CHECK(!r.ok);
    CHECK(m.bodyCount() == 1);  // everything before and after the fillet still builds
    int failed = 0;
    for (auto& st : r.features) failed += st.ok ? 0 : 1;
    CHECK(failed == 1);
  });

  run("native part file round-trips with cached geometry", [&] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    std::string path = (out / "pavilion.fpprt").string();
    savePart(path, m.document(), &m);
    CHECK(fileKind(path) == FileKind::Part);
    CHECK(!fs::exists(path + ".tmp"));
    PartDocument back = loadPart(path);
    CHECK(back.featuresJson() == m.document().featuresJson());
    CHECK(back.variablesJson() == m.document().variablesJson());
    CHECK(back.fileId == m.document().fileId);
    CHECK(back.viewpoints.size() == 1);
    CHECK(cachedBodyCount(path) == 1);
    // Editing the history makes the cache stale.
    back.features[0].params["h"] = 0.5;
    savePart(path, back);
    CHECK(cachedBodyCount(path) == 0);
    CHECK(throws([&] { loadAssembly(path); }));
    CHECK(throws([&] { loadPart((out / "missing.fpprt").string()); }));
  });

  run("files from a newer format version are refused clearly", [&] {
    std::string path = (out / "future.fpprt").string();
    mz_zip_archive z;
    mz_zip_zero_struct(&z);
    mz_zip_writer_init_file(&z, path.c_str(), 0);
    std::string m = R"({"format":"fps-cad","formatVersion":99,"kind":"part"})";
    mz_zip_writer_add_mem(&z, "manifest.json", m.data(), m.size(), MZ_DEFAULT_COMPRESSION);
    mz_zip_writer_finalize_archive(&z);
    mz_zip_writer_end(&z);
    std::string msg;
    try {
      loadPart(path);
    } catch (const FileError& e) {
      msg = e.what();
    }
    CHECK(msg.find("newer version") != std::string::npos);
  });

  run("part exports to every format and reads back", [&] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    const double mm3 = kSampleVolume * 1e9;
    for (const char* name : {"pavilion.step", "pavilion.igs", "pavilion.stl", "pavilion.3mf"}) {
      std::string path = (out / name).string();
      ExportResult r = exportPart(m, path, {});
      std::printf("    %-14s ok=%d validated=%d bodies=%d tris=%ld  %s\n", name, r.ok, r.validated, r.bodies,
                  r.triangles, r.message.c_str());
      CHECK(r.ok && r.validated);
      CHECK(fs::file_size(path) > 1000);
      CHECK_NEAR(r.sourceVolume / mm3, 1.0, 1e-3);
    }
    ExportOptions inches;
    inches.units = "in";
    inches.stepSchema = "AP214";
    ExportResult r = exportPart(m, (out / "pavilion-in.step").string(), inches);
    CHECK(r.ok && r.validated);
    ExportResult bad = exportPart(m, (out / "pavilion.dwg").string(), {});
    CHECK(!bad.ok && bad.message.find("unsupported") != std::string::npos);
    std::string model = zipEntry((out / "pavilion.3mf").string(), "3D/3dmodel.model");
    CHECK(model.find("unit=\"millimeter\"") != std::string::npos);
    CHECK(count(model, "<item ") == 1);
  });

  run("assembly saves, loads, instances parts and exports", [&] {
    std::string path = (out / "pins.fpasm").string();
    saveAssembly(path, AssemblyDocument::sample());
    CHECK(fileKind(path) == FileKind::Assembly);
    AssemblyModel a(loadAssembly(path), out.string());
    bool ok = a.rebuild();
    for (auto& c : a.components()) if (!c.ok) std::fprintf(stderr, "    %s: %s\n", c.name.c_str(), c.message.c_str());
    CHECK(ok);
    CHECK(a.components().size() == 5);
    CHECK(a.parts().size() == 2);  // plate + one shared pin part
    CHECK(a.document().mates.size() == 4);
    auto mp = a.massProperties();
    CHECK(mp.bodies == 5);
    CHECK(mp.volume > 0.2 * 0.12 * 0.01 * 0.9);

    ExportResult step = exportAssembly(a, (out / "pins.step").string(), {});
    std::printf("    pins.step ok=%d %s\n", step.ok, step.message.c_str());
    CHECK(step.ok && step.validated && step.bodies == 5);
    ExportResult tmf = exportAssembly(a, (out / "pins.3mf").string(), {});
    CHECK(tmf.ok && tmf.validated);
    std::string model = zipEntry((out / "pins.3mf").string(), "3D/3dmodel.model");
    CHECK(count(model, "<object ") == 2);
    CHECK(count(model, "<item ") == 5);
    ExportResult stl = exportAssembly(a, (out / "pins.stl").string(), {});
    CHECK(stl.ok && stl.validated);

    // A component pointing at a part file on disk, nested inside another assembly.
    PartModel plate(*a.document().components[0].virtualPart);
    plate.rebuild();
    savePart((out / "plate.fpprt").string(), plate.document(), &plate);
    AssemblyDocument outer;
    outer.name = "Outer";
    Component c1;
    c1.name = "Plate on disk";
    c1.path = "plate.fpprt";
    Component c2;
    c2.name = "Pin plate";
    c2.path = "pins.fpasm";
    c2.placement.t = {0, 0, 0.5};
    outer.components = {c1, c2};
    std::string outerPath = (out / "outer.fpasm").string();
    saveAssembly(outerPath, outer);
    AssemblyModel o(loadAssembly(outerPath), out.string());
    CHECK(o.rebuild());
    CHECK(o.components().size() == 6);
    Component missing;
    missing.name = "Gone";
    missing.path = "nowhere.fpprt";
    o.document().components.push_back(missing);
    CHECK(!o.rebuild());
  });

  std::printf("\n%d checks, %d failed\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
