#include "fpcad/Challenges.h"

#include <cmath>

#include "fpcad/Sketch.h"

namespace fpcad {

namespace {

constexpr double mm = 0.001;

// Builds one target part in millimetres.
class Builder {
public:
  explicit Builder(const std::string& name) {
    c_.target.name = name;
    c_.target.units = "mm";
  }

  Builder& box(double x, double y, double z, double w, double d, double h, BodyOp op = BodyOp::Add) {
    Feature f;
    f.type = "box";
    f.op = op;
    f.params = {{"x", x * mm}, {"y", y * mm}, {"z", z * mm}, {"w", w * mm}, {"d", d * mm}, {"h", h * mm}};
    c_.target.add(f);
    return *this;
  }

  Builder& cylinder(double x, double y, double z, double r, double h, BodyOp op = BodyOp::Add) {
    Feature f;
    f.type = "cylinder";
    f.op = op;
    f.params = {{"x", x * mm}, {"y", y * mm}, {"z", z * mm}, {"r", r * mm}, {"h", h * mm}};
    c_.target.add(f);
    return *this;
  }

  // A round hole along X through the plane x = x0, centred at (y, z).
  Builder& holeAlongX(double x0, double y, double z, double r, double depth) {
    Feature f;
    f.type = "extrude";
    f.op = BodyOp::Cut;
    f.params = {{"plane", {{"origin", {x0 * mm, 0, 0}}, {"normal", {1, 0, 0}}, {"xdir", {0, 1, 0}}}},
                {"profile", {{"kind", "circle"}, {"cx", y * mm}, {"cy", z * mm}, {"r", r * mm}}},
                {"depth", depth * mm},
                {"symmetric", true}};
    c_.target.add(f);
    return *this;
  }

  std::string sketch(const SketchPlane& plane, Json points, Json entities) {
    Feature f;
    f.type = "sketch";
    f.params = {{"plane", plane.toJson()}, {"planeName", "Plane"}, {"points", std::move(points)},
                {"entities", std::move(entities)}, {"constraints", Json::array()}};
    return c_.target.add(f).id;
  }

  Builder& feature(const char* type, Json params) {
    Feature f;
    f.type = type;
    f.params = std::move(params);
    c_.target.add(f);
    return *this;
  }

  Builder& dim(Vec3 a, Vec3 b, const std::string& text) {
    c_.callouts.push_back({{a[0] * mm, a[1] * mm, a[2] * mm}, {b[0] * mm, b[1] * mm, b[2] * mm}, text});
    return *this;
  }

  Challenge done(const char* id, const char* brief, const char* hint) {
    c_.id = id;
    c_.name = c_.target.name;
    c_.brief = brief;
    c_.hint = hint;
    return c_;
  }

private:
  Challenge c_;
};

}  // namespace

std::vector<Challenge> challenges() {
  std::vector<Challenge> out;

  // 1. One extrude.
  out.push_back(Builder("Block")
                    .box(0, 0, 0, 100, 75, 50)
                    .dim({-50, -37.5, 0}, {50, -37.5, 0}, "100")
                    .dim({50, -37.5, 0}, {50, 37.5, 0}, "75")
                    .dim({50, -37.5, 0}, {50, -37.5, 50}, "50")
                    .done("block", "A plain block, 100 × 75 × 50 mm.",
                          "Sketch a rectangle, dimension it, and extrude it. All three sizes are on the 25 mm snap."));

  // 2. A circle.
  out.push_back(Builder("Puck")
                    .cylinder(0, 0, 0, 50, 25)
                    .dim({-50, 0, 25}, {50, 0, 25}, "⌀100")
                    .dim({50, 0, 0}, {50, 0, 25}, "25")
                    .done("puck", "A disc 100 mm across and 25 mm thick.",
                          "Use the Circle sketch tool, then Extrude."));

  // 3. A cut.
  out.push_back(Builder("Plate with a hole")
                    .box(0, 0, 0, 150, 100, 25)
                    .cylinder(0, 0, -1, 25, 27, BodyOp::Cut)
                    .dim({-75, -50, 0}, {75, -50, 0}, "150")
                    .dim({75, -50, 0}, {75, 50, 0}, "100")
                    .dim({75, -50, 0}, {75, -50, 25}, "25")
                    .dim({-25, 0, 25}, {25, 0, 25}, "⌀50 through")
                    .done("plate-hole", "A 150 × 100 × 25 mm plate with a 50 mm hole through its centre.",
                          "Make the plate, then sketch a circle on its top face and extrude it as a cut "
                          "(LT, or Result: Cut away) through all."));

  // 4. Two features meeting.
  out.push_back(Builder("L-bracket")
                    .box(0, 0, 0, 120, 60, 20)
                    .box(50, 0, 0, 20, 60, 80)
                    .dim({-60, -30, 0}, {60, -30, 0}, "120")
                    .dim({60, -30, 0}, {60, 30, 0}, "60")
                    .dim({-60, -30, 0}, {-60, -30, 20}, "20")
                    .dim({60, -30, 0}, {60, -30, 80}, "80")
                    .dim({40, -30, 80}, {60, -30, 80}, "20")
                    .done("l-bracket", "An L-shaped bracket: a 120 mm base and an 80 mm upright, both 20 mm thick, 60 mm deep.",
                          "Either sketch the L profile on the side and extrude it once, or build a base and add the "
                          "upright on top. Both count."));

  // 5. A pocket with exact walls.
  out.push_back(Builder("Channel")
                    .box(0, 0, 0, 120, 80, 50)
                    .box(0, 0, 15, 130, 50, 40, BodyOp::Cut)
                    .dim({-60, -40, 0}, {60, -40, 0}, "120")
                    .dim({60, -40, 0}, {60, 40, 0}, "80")
                    .dim({60, -40, 0}, {60, -40, 50}, "50")
                    .dim({60, -40, 50}, {60, -25, 50}, "15")
                    .dim({60, 0, 0}, {60, 0, 15}, "floor 15")
                    .done("channel", "A U-channel 120 mm long: 80 × 50 mm outside, 15 mm walls and floor.",
                          "Type the dimensions: 15 mm is off the snap. A cut extrude through all makes the slot."));

  // 6. Turned part.
  out.push_back(Builder("Spool")
                    .cylinder(0, 0, 0, 40, 10)
                    .cylinder(0, 0, 0, 20, 60)
                    .cylinder(0, 0, 50, 40, 10)
                    .cylinder(0, 0, -1, 8, 62, BodyOp::Cut)
                    .dim({-40, 0, 60}, {40, 0, 60}, "⌀80")
                    .dim({-20, 0, 30}, {20, 0, 30}, "⌀40")
                    .dim({-8, 0, 60}, {8, 0, 60}, "⌀16 bore")
                    .dim({45, 0, 0}, {45, 0, 60}, "60")
                    .dim({45, 0, 0}, {45, 0, 10}, "10")
                    .done("spool", "A spool: two ⌀80 flanges 10 mm thick on a ⌀40 core, 60 mm tall, with a ⌀16 bore.",
                          "Sketch half the cross-section on the Front plane and Revolve it about the sketch's Y axis, "
                          "or stack extruded circles."));

  // 7. Sweep.
  {
    Builder b("Bent rod");
    std::string prof = b.sketch(standardPlane("front"), Json::array(),
                                Json::array({{{"id", "k"}, {"kind", "circle"}, {"pts", {"o"}}, {"r", 10 * mm}}}));
    std::string path = b.sketch(standardPlane("top"),
                                Json::array({{{"id", "c"}, {"x", 60 * mm}, {"y", 0}}, {{"id", "e"}, {"x", 60 * mm}, {"y", 60 * mm}}}),
                                Json::array({{{"id", "a"}, {"kind", "arc"}, {"pts", {"c", "e", "o"}}}}));
    b.feature("sweep", {{"sketch", prof}, {"path", path}});
    b.dim({60, 0, 0}, {0, 0, 0}, "R60 bend").dim({50, 60, 0}, {70, 60, 0}, "⌀20");
    out.push_back(b.done("bent-rod", "A ⌀20 rod bent through a quarter turn on a 60 mm radius.",
                         "Sketch the path (an arc) on one plane and the ⌀20 circle on a plane square to the path's "
                         "end, then Sweep the circle along the arc."));
  }

  // 8. Loft.
  {
    Builder b("Transition");
    std::string sq = b.sketch(standardPlane("top"),
                              Json::array({{{"id", "a"}, {"x", -30 * mm}, {"y", -30 * mm}}, {{"id", "b"}, {"x", 30 * mm}, {"y", -30 * mm}},
                                           {{"id", "c"}, {"x", 30 * mm}, {"y", 30 * mm}}, {{"id", "d"}, {"x", -30 * mm}, {"y", 30 * mm}}}),
                              Json::array({{{"id", "l1"}, {"kind", "line"}, {"pts", {"a", "b"}}},
                                           {{"id", "l2"}, {"kind", "line"}, {"pts", {"b", "c"}}},
                                           {{"id", "l3"}, {"kind", "line"}, {"pts", {"c", "d"}}},
                                           {{"id", "l4"}, {"kind", "line"}, {"pts", {"d", "a"}}}}));
    SketchPlane up = standardPlane("top");
    up.origin = {0, 0, 60 * mm};
    std::string ci = b.sketch(up, Json::array(),
                              Json::array({{{"id", "k"}, {"kind", "circle"}, {"pts", {"o"}}, {"r", 20 * mm}}}));
    b.feature("loft", {{"sketches", {sq, ci}}});
    b.dim({-30, -30, 0}, {30, -30, 0}, "60 square").dim({35, 0, 0}, {35, 0, 60}, "60").dim({-20, 0, 60}, {20, 0, 60}, "⌀40");
    out.push_back(b.done("transition", "A square-to-round transition: 60 mm square at the bottom, ⌀40 at the top, 60 mm tall.",
                         "Sketch the square on the Top plane and the circle on a face or plane 60 mm above it, then Loft "
                         "from one to the other."));
  }

  // 9. Turned part with a hole pattern.
  out.push_back(Builder("Flanged bushing")
                    .cylinder(0, 0, 0, 50, 10)
                    .cylinder(0, 0, 0, 25, 50)
                    .cylinder(0, 0, -1, 15, 52, BodyOp::Cut)
                    .cylinder(37.5, 0, -1, 5, 12, BodyOp::Cut)
                    .cylinder(-37.5, 0, -1, 5, 12, BodyOp::Cut)
                    .cylinder(0, 37.5, -1, 5, 12, BodyOp::Cut)
                    .cylinder(0, -37.5, -1, 5, 12, BodyOp::Cut)
                    .dim({-50, 0, 10}, {50, 0, 10}, "⌀100")
                    .dim({-25, 0, 50}, {25, 0, 50}, "⌀50")
                    .dim({-15, 0, 50}, {15, 0, 50}, "⌀30 bore")
                    .dim({0, 0, 10}, {37.5, 0, 10}, "4× ⌀10 on ⌀75")
                    .dim({55, 0, 0}, {55, 0, 50}, "50")
                    .dim({55, 0, 0}, {55, 0, 10}, "10")
                    .done("bushing", "A flanged bushing: ⌀100 × 10 flange, ⌀50 body 50 mm tall, ⌀30 bore, and four ⌀10 holes "
                                     "evenly spaced on a ⌀75 circle.",
                          "Build the turned shape first, then sketch the four circles on the flange and cut them."));

  // 10. Everything together.
  out.push_back(Builder("Mounting bracket")
                    .box(0, 0, 0, 120, 80, 15)
                    .box(52.5, 0, 0, 15, 80, 90)
                    .cylinder(-30, 20, -1, 6, 17, BodyOp::Cut)
                    .cylinder(-30, -20, -1, 6, 17, BodyOp::Cut)
                    .holeAlongX(52.5, 0, 55, 10, 30)
                    .dim({-60, -40, 0}, {60, -40, 0}, "120")
                    .dim({60, -40, 0}, {60, 40, 0}, "80")
                    .dim({-60, -40, 0}, {-60, -40, 15}, "15")
                    .dim({60, -40, 0}, {60, -40, 90}, "90")
                    .dim({45, -40, 90}, {60, -40, 90}, "15")
                    .dim({-30, -20, 15}, {-30, 20, 15}, "2× ⌀12, 40 apart, 30 from the end")
                    .dim({60, -10, 55}, {60, 10, 55}, "⌀20 at 55 high")
                    .done("mounting-bracket", "A mounting bracket: a 120 × 80 × 15 base with a 90 mm upright at one end, two ⌀12 "
                                              "holes in the base and a ⌀20 hole through the upright.",
                          "Sketch on faces: the base's top face for the two holes, the upright's outer face for the big "
                          "one. Cut through all."));
  return out;
}

}  // namespace fpcad
