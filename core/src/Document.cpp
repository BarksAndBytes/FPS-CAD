#include "fpcad/Document.h"

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

}  // namespace fpcad
