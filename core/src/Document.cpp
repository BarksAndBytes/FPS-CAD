#include "fpcad/Document.h"

#include <cmath>

#include "fpcad/Expression.h"

#include <cctype>
#include <random>
#include <stdexcept>

namespace fpcad {

std::string newId() {
  static thread_local std::mt19937_64 rng{std::random_device{}() ^
                                          (static_cast<uint64_t>(std::random_device{}()) << 32)};
  static const char* hex = "0123456789abcdef";
  std::string s(32, '0');
  for (int part = 0; part < 2; ++part) {
    uint64_t v = rng();
    for (int i = 0; i < 16; ++i) s[part * 16 + i] = hex[(v >> (i * 4)) & 0xF];
  }
  return s;
}

std::string toString(BodyOp op) {
  switch (op) {
    case BodyOp::Add: return "add";
    case BodyOp::Cut: return "cut";
    case BodyOp::Intersect: return "intersect";
    case BodyOp::NewBody: return "new-body";
  }
  return "add";
}

BodyOp bodyOpFromString(const std::string& s) {
  if (s == "add") return BodyOp::Add;
  if (s == "cut") return BodyOp::Cut;
  if (s == "intersect") return BodyOp::Intersect;
  if (s == "new-body") return BodyOp::NewBody;
  throw std::invalid_argument("unknown body operation '" + s + "'");
}

Feature* PartDocument::find(const std::string& id) {
  for (auto& f : features) if (f.id == id) return &f;
  return nullptr;
}
const Feature* PartDocument::find(const std::string& id) const {
  for (auto& f : features) if (f.id == id) return &f;
  return nullptr;
}

std::string PartDocument::uniqueName(const std::string& base) const {
  int n = 1;
  for (auto& f : features) if (f.name.rfind(base + " ", 0) == 0) ++n;
  for (;; ++n) {
    std::string candidate = base + " " + std::to_string(n);
    bool used = false;
    for (auto& f : features) used = used || f.name == candidate;
    if (!used) return candidate;
  }
}

Feature& PartDocument::add(Feature f) {
  if (f.id.empty()) f.id = newId();
  if (f.name.empty()) {
    std::string base = f.type.empty() ? "Feature" : f.type;
    base[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(base[0])));
    if (f.type == "csys") base = "Coordinate system";
    if (f.type == "face_offset") base = "Push/Pull";
    if (f.type == "pattern") base = f.params.value("kind", std::string("linear")) == "circular" ? "Circular pattern" : "Linear pattern";
    if (f.type == "body") {
      std::string k = f.params.value("kind", std::string());
      base = k == "subtract" ? "Subtract" : k == "intersect" ? "Intersect" : k == "split" ? "Split" : k == "delete" ? "Delete body" : "Combine";
    }
    f.name = uniqueName(base);
  }
  features.push_back(std::move(f));
  return features.back();
}

Json PartDocument::featuresJson() const {
  Json arr = Json::array();
  for (auto& f : features) {
    arr.push_back({{"id", f.id}, {"type", f.type}, {"name", f.name}, {"op", toString(f.op)},
                   {"body", f.body}, {"suppressed", f.suppressed}, {"params", f.params}});
  }
  return arr;
}

Json PartDocument::variablesJson() const {
  Json arr = Json::array();
  for (auto& v : variables) arr.push_back({{"name", v.name}, {"expr", v.expr}});
  return arr;
}

void PartDocument::loadFeatures(const Json& j) {
  features.clear();
  for (auto& e : j) {
    Feature f;
    f.id = e.at("id").get<std::string>();
    f.type = e.at("type").get<std::string>();
    f.name = e.value("name", f.type);
    f.op = bodyOpFromString(e.value("op", std::string("add")));
    f.body = e.value("body", 0);
    f.suppressed = e.value("suppressed", false);
    f.params = e.value("params", Json::object());
    features.push_back(std::move(f));
  }
}

void PartDocument::loadVariables(const Json& j) {
  variables.clear();
  for (auto& e : j) variables.push_back({e.at("name").get<std::string>(), e.at("expr").get<std::string>()});
}

PartDocument PartDocument::sample() {
  PartDocument d;
  d.name = "Pavilion";
  d.units = "mm";
  d.variables = {{"slab", "400 mm"}, {"storey", "3000 mm"}, {"column_r", "300 mm"}};
  auto feature = [](const char* type, const char* name, BodyOp op, Json params) {
    Feature f;
    f.type = type;
    f.name = name;
    f.op = op;
    f.params = std::move(params);
    return f;
  };
  d.add(feature("box", "Plinth", BodyOp::Add,
                {{"x", 0}, {"y", 0}, {"z", 0}, {"w", 10}, {"d", 7}, {"h", "slab"}}));
  d.add(feature("box", "Core", BodyOp::Add,
                {{"x", -2.5}, {"y", 1}, {"z", "slab"}, {"w", 4}, {"d", 4}, {"h", "storey"}}));
  d.add(feature("cylinder", "Column 1", BodyOp::Add,
                {{"x", 2.6}, {"y", -1.8}, {"z", "slab"}, {"r", "column_r"}, {"h", "storey"}}));
  d.add(feature("cylinder", "Column 2", BodyOp::Add,
                {{"x", 2.6}, {"y", 1.8}, {"z", "slab"}, {"r", "column_r"}, {"h", "storey"}}));
  d.add(feature("box", "Roof", BodyOp::Add,
                {{"x", 0.3}, {"y", 0}, {"z", "slab + storey"}, {"w", 9}, {"d", 6.2}, {"h", 0.3}}));
  d.add(feature("box", "Step", BodyOp::Add,
                {{"x", 0}, {"y", -4}, {"z", 0}, {"w", 3}, {"d", 1}, {"h", 0.2}}));
  // A doorway tunnelled through the core, tall enough to walk through at 1:1.
  d.add(feature("extrude", "Doorway", BodyOp::Cut,
                {{"plane", {{"origin", {-2.5, 1, 0}}, {"normal", {0, 1, 0}}, {"xdir", {1, 0, 0}}}},
                 {"profile", {{"kind", "rect"}, {"cx", 0}, {"cy", -1.5}, {"w", 1.2}, {"h", 2.2}}},
                 {"depth", 5},
                 {"symmetric", true}}));
  d.add(feature("fillet", "Roof corners", BodyOp::Add,
                {{"target", d.features[4].id}, {"edges", "vertical"}, {"r", "100 mm"}}));
  d.viewpoints.push_back({"Approach", {0, -14, 0}, 0, -0.12, 1});
  return d;
}

PartDocument PartDocument::deskSample() {
  PartDocument d;
  d.name = "Desk organiser";
  d.units = "mm";
  d.variables = {{"width", "240 mm"}, {"depth", "120 mm"}, {"height", "90 mm"}, {"wall", "8 mm"}};
  auto feature = [](const char* type, const char* name, BodyOp op, Json params) {
    Feature f;
    f.type = type;
    f.name = name;
    f.op = op;
    f.params = std::move(params);
    return f;
  };
  // The base stands a wall's thickness proud of the walls all round, so its corners are its own
  // edges and the fillet below finds them on every platform.
  d.add(feature("box", "Base", BodyOp::Add,
                {{"x", 0}, {"y", 0}, {"z", 0}, {"w", "width + 2 * wall"}, {"d", "depth + 2 * wall"}, {"h", "wall"}}));
  d.add(feature("box", "Back", BodyOp::Add,
                {{"x", 0}, {"y", "depth / 2 - wall / 2"}, {"z", 0}, {"w", "width"}, {"d", "wall"}, {"h", "height"}}));
  d.add(feature("box", "Left side", BodyOp::Add,
                {{"x", "-(width / 2 - wall / 2)"}, {"y", 0}, {"z", 0}, {"w", "wall"}, {"d", "depth"}, {"h", "height * 0.6"}}));
  d.add(feature("box", "Right side", BodyOp::Add,
                {{"x", "width / 2 - wall / 2"}, {"y", 0}, {"z", 0}, {"w", "wall"}, {"d", "depth"}, {"h", "height * 0.6"}}));
  d.add(feature("box", "Divider", BodyOp::Add,
                {{"x", "width / 6"}, {"y", 0}, {"z", 0}, {"w", "wall"}, {"d", "depth"}, {"h", "height * 0.6"}}));
  d.add(feature("cylinder", "Pen cup", BodyOp::Add,
                {{"x", "-width / 4"}, {"y", 0}, {"z", 0}, {"r", "depth / 4"}, {"h", "height"}}));
  d.add(feature("cylinder", "Pen cup hollow", BodyOp::Cut,
                {{"x", "-width / 4"}, {"y", 0}, {"z", "wall"}, {"r", "depth / 4 - wall"}, {"h", "height"}}));
  d.add(feature("fillet", "Base corners", BodyOp::Add,
                {{"target", d.features[0].id}, {"edges", "vertical"}, {"r", "6 mm"}}));
  d.viewpoints.push_back({"Approach", {0, -1.6, -0.75}, 0, -0.5, 1});
  return d;
}

PartDocument PartDocument::trainingCourse() {
  PartDocument d;
  d.name = "Training course";
  d.units = "mm";
  auto box = [&](const char* name, double x, double y, double w, double dd, double h, BodyOp op) {
    Feature f;
    f.type = "box";
    f.name = name;
    f.op = op;
    f.params = {{"x", x}, {"y", y}, {"z", 0}, {"w", w}, {"d", dd}, {"h", h}};
    d.add(f);
  };
  // Separate bodies keep each station independent, so editing one never merges it with another.
  box("Start pad", 0, -12, 4, 4, 0.05, BodyOp::NewBody);
  box("Step", 0, -6, 5, 2, 0.8, BodyOp::NewBody);  // too high to walk up, low enough to jump
  box("Wall", 0, 0, 24, 1, 3, BodyOp::NewBody);
  Feature tunnel;
  tunnel.type = "extrude";
  tunnel.name = "Crawl tunnel";
  tunnel.op = BodyOp::Cut;
  tunnel.params = {{"plane", {{"origin", {0, 0, 0}}, {"normal", {0, 1, 0}}, {"xdir", {1, 0, 0}}}},
                   {"profile", {{"kind", "rect"}, {"cx", 0}, {"cy", -0.15}, {"w", 0.3}, {"h", 0.3}}},
                   {"depth", 3},
                   {"symmetric", true}};
  d.add(tunnel);
  box("Lift block", 3, 5, 1.5, 1.5, 1, BodyOp::NewBody);
  box("Build pad", -3, 5, 3, 3, 0.05, BodyOp::NewBody);
  d.viewpoints.push_back({"Start", {0, -14, 0}, 0, -0.12, 1});
  return d;
}

Json AssemblyDocument::componentsJson() const {
  Json arr = Json::array();
  for (auto& c : components) {
    Json e = {{"id", c.id}, {"name", c.name}, {"path", c.path}, {"fileId", c.fileId},
              {"t", c.placement.t}, {"q", c.placement.q}, {"grounded", c.grounded},
              {"suppressed", c.suppressed}};
    if (c.virtualPart) {
      e["virtualPart"] = {{"fileId", c.virtualPart->fileId}, {"name", c.virtualPart->name},
                          {"units", c.virtualPart->units}, {"material", c.virtualPart->material},
                          {"density", c.virtualPart->density},
                          {"variables", c.virtualPart->variablesJson()},
                          {"features", c.virtualPart->featuresJson()}};
    }
    arr.push_back(std::move(e));
  }
  return arr;
}

Json AssemblyDocument::matesJson() const {
  Json arr = Json::array();
  for (auto& m : mates)
    arr.push_back({{"id", m.id}, {"type", m.type}, {"refs", m.refs}, {"params", m.params},
                   {"suppressed", m.suppressed}});
  return arr;
}

void AssemblyDocument::loadComponents(const Json& j) {
  components.clear();
  for (auto& e : j) {
    Component c;
    c.id = e.at("id").get<std::string>();
    c.name = e.value("name", std::string("Component"));
    c.path = e.value("path", std::string());
    c.fileId = e.value("fileId", std::string());
    c.placement.t = e.value("t", c.placement.t);
    c.placement.q = e.value("q", c.placement.q);
    c.grounded = e.value("grounded", false);
    c.suppressed = e.value("suppressed", false);
    if (e.contains("virtualPart")) {
      auto& v = e["virtualPart"];
      PartDocument p;
      p.fileId = v.value("fileId", newId());
      p.name = v.value("name", c.name);
      p.units = v.value("units", std::string("mm"));
      p.material = v.value("material", p.material);
      p.density = v.value("density", p.density);
      p.loadVariables(v.value("variables", Json::array()));
      p.loadFeatures(v.value("features", Json::array()));
      c.virtualPart = std::move(p);
    }
    components.push_back(std::move(c));
  }
}

AssemblyDocument AssemblyDocument::sample() {
  AssemblyDocument a;
  a.name = "Pin plate";
  PartDocument plate;
  plate.name = "Plate";
  plate.variables = {{"t", "10 mm"}};
  Feature base;
  base.type = "box";
  base.name = "Base";
  base.params = {{"x", 0}, {"y", 0}, {"z", 0}, {"w", "200 mm"}, {"d", "120 mm"}, {"h", "t"}};
  plate.add(base);
  for (int i = 0; i < 4; ++i) {
    Feature hole;
    hole.type = "cylinder";
    hole.op = BodyOp::Cut;
    hole.name = "Hole " + std::to_string(i + 1);
    hole.params = {{"x", (i % 2 ? 0.08 : -0.08)}, {"y", (i < 2 ? 0.04 : -0.04)}, {"z", -0.001},
                   {"r", "4 mm"}, {"h", "t + 2 mm"}};
    plate.add(hole);
  }
  PartDocument pin;
  pin.name = "Pin";
  Feature shaft;
  shaft.type = "cylinder";
  shaft.name = "Shaft";
  shaft.params = {{"x", 0}, {"y", 0}, {"z", 0}, {"r", "4 mm"}, {"h", "30 mm"}};
  pin.add(shaft);
  Feature head;
  head.type = "cylinder";
  head.name = "Head";
  head.params = {{"x", 0}, {"y", 0}, {"z", "30 mm"}, {"r", "7 mm"}, {"h", "4 mm"}};
  pin.add(head);
  Feature edge;
  edge.type = "chamfer";
  edge.name = "Head chamfer";
  edge.params = {{"target", pin.features[1].id}, {"edges", "top"}, {"d", "1 mm"}};
  pin.add(edge);

  Component pc;
  pc.name = "Plate";
  pc.virtualPart = plate;
  pc.grounded = true;
  a.components.push_back(pc);
  for (int i = 0; i < 4; ++i) {
    Component c;
    c.name = "Pin " + std::to_string(i + 1);
    c.virtualPart = pin;  // same fileId: four instances of one part
    c.placement.t = {(i % 2 ? 0.08 : -0.08), (i < 2 ? 0.04 : -0.04), -0.020};  // head rests on the plate
    a.components.push_back(c);
    Mate m;
    m.type = "concentric";
    m.refs = Json::array({{{"component", pc.id}, {"feature", plate.features[static_cast<size_t>(i + 1)].id}},
                          {{"component", c.id}, {"feature", pin.features[0].id}}});
    a.mates.push_back(m);
  }
  return a;
}

void AssemblyDocument::loadMates(const Json& j) {
  mates.clear();
  for (auto& e : j) {
    Mate m;
    m.id = e.at("id").get<std::string>();
    m.type = e.at("type").get<std::string>();
    m.refs = e.value("refs", Json::array());
    m.params = e.value("params", Json::object());
    m.suppressed = e.value("suppressed", false);
    mates.push_back(std::move(m));
  }
}

std::string PartDocument::massUnit() const {
  if (massUnits == "g" || massUnits == "kg" || massUnits == "lb") return massUnits;
  if (units == "in" || units == "ft") return "lb";
  if (units == "m") return "kg";
  return "g";
}

namespace {

bool same(double a, double b) { return std::abs(a - b) <= 1e-9 * std::max(1.0, std::max(std::abs(a), std::abs(b))); }

// Where each plain number literal sits in expr: [start, end) of numbers not glued to a name and
// not already followed by a unit or a name.
std::vector<std::pair<size_t, size_t>> plainNumbers(const std::string& s) {
  std::vector<std::pair<size_t, size_t>> out;
  size_t i = 0;
  auto ident = [](char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_'; };
  while (i < s.size()) {
    char c = s[i];
    bool startsNumber = (std::isdigit(static_cast<unsigned char>(c)) || c == '.') && (i == 0 || !ident(s[i - 1]));
    if (!startsNumber) {
      if (ident(c)) {
        while (i < s.size() && ident(s[i])) ++i;  // skip a whole name, digits and all
      } else {
        ++i;
      }
      continue;
    }
    size_t j = i;
    while (j < s.size() && (std::isdigit(static_cast<unsigned char>(s[j])) || s[j] == '.')) ++j;
    if (j < s.size() && (s[j] == 'e' || s[j] == 'E')) {
      size_t k = j + 1;
      if (k < s.size() && (s[k] == '+' || s[k] == '-')) ++k;
      if (k < s.size() && std::isdigit(static_cast<unsigned char>(s[k]))) {
        j = k;
        while (j < s.size() && std::isdigit(static_cast<unsigned char>(s[j]))) ++j;
      }
    }
    size_t k = j;
    while (k < s.size() && std::isspace(static_cast<unsigned char>(s[k]))) ++k;
    if (k >= s.size() || !std::isalpha(static_cast<unsigned char>(s[k]))) out.push_back({i, j});
    i = j;
  }
  return out;
}

// expr with the old unit written after each plain number read as a length in that unit, so it
// means the same in any unit. Strings that are not length expressions come back unchanged.
std::string pinLengths(const std::string& expr, const VariableTable& vars, double oldScale, double newScale,
                       const std::string& oldUnit) {
  double base;
  try {
    base = evaluate(expr, vars, Quantity::Length, oldScale);
    if (same(evaluate(expr, vars, Quantity::Length, newScale), base)) return expr;
  } catch (const std::exception&) {
    return expr;
  }
  std::string s = expr;
  auto nums = plainNumbers(s);
  for (auto it = nums.rbegin(); it != nums.rend(); ++it) {
    std::string candidate = s.substr(0, it->second) + " " + oldUnit + s.substr(it->second);
    try {
      if (same(evaluate(candidate, vars, Quantity::Length, oldScale), base)) s = candidate;
    } catch (const std::exception&) {
    }
  }
  return s;
}

// Keys whose strings are never lengths: angles, text and references.
bool notLength(const std::string& key) {
  static const char* skip[] = {"angle", "total", "text", "font", "name", "id", "kind", "type", "edges", "target",
                               "refs", "op", "plane", "ref", "centre", "entities"};
  for (const char* k : skip)
    if (key == k) return true;
  return false;
}

void pinJson(Json& j, const VariableTable& vars, double oldScale, double newScale, const std::string& oldUnit) {
  if (j.is_object()) {
    bool angleConstraint = j.value("kind", std::string()) == "angle";
    for (auto& [k, v] : j.items()) {
      if (notLength(k) || (angleConstraint && k == "value")) continue;
      if (v.is_string()) {
        v = pinLengths(v.get<std::string>(), vars, oldScale, newScale, oldUnit);
      } else {
        pinJson(v, vars, oldScale, newScale, oldUnit);
      }
    }
  } else if (j.is_array()) {
    for (auto& v : j) {
      if (v.is_string()) {
        v = pinLengths(v.get<std::string>(), vars, oldScale, newScale, oldUnit);
      } else {
        pinJson(v, vars, oldScale, newScale, oldUnit);
      }
    }
  }
}

}  // namespace

bool PartDocument::changeUnits(const std::string& to) {
  double oldScale, newScale;
  try {
    oldScale = unitScale(units);
    newScale = unitScale(to);
  } catch (const std::exception&) {
    return false;
  }
  if (to == units) return true;
  VariableTable vars;
  for (auto& v : variables) {
    v.expr = pinLengths(v.expr, vars, oldScale, newScale, units);
    try {
      vars[v.name] = evaluate(v.expr, vars, Quantity::Length, newScale);
    } catch (const std::exception&) {
    }
  }
  for (auto& f : features) pinJson(f.params, vars, oldScale, newScale, units);
  units = to;
  return true;
}

}  // namespace fpcad
