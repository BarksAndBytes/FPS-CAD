#pragma once
// Editable documents: the parametric history of a part, and the structure of an assembly.
//
// Coordinates follow CAD convention: right-handed, Z up, metres. The game layer converts to its
// own axes. Feature parameters are JSON values: a number (SI units) or an expression string.

#include <array>
#include <optional>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace fpcad {

using Json = nlohmann::json;

constexpr int kFormatVersion = 1;

std::string newId();  // random 128-bit id as 32 hex characters

// Boolean role of a feature's tool body against the part's bodies.
enum class BodyOp { Add, Cut, Intersect, NewBody };
std::string toString(BodyOp op);
BodyOp bodyOpFromString(const std::string& s);

// Feature types in this build:
//   box       x y z (centre of the base), w (X), d (Y), h (Z)
//   cylinder  x y z (centre of the base), r, h
//   sphere    x y z (centre), r
//   cone      x y z (centre of the base), r1 (base), r2 (top), h
//   extrude   plane {origin[3], normal[3], xdir[3]}, profile, depth, symmetric
//             profile = {"kind":"rect","cx","cy","w","h"} | {"kind":"circle","cx","cy","r"}
//                     | {"kind":"polyline","points":[[x,y],...]}
//   fillet    target (feature id), edges ("all"|"vertical"|"top"|"bottom"), r
//   chamfer   target (feature id), edges, d
struct Feature {
  std::string id;
  std::string type;
  std::string name;
  BodyOp op = BodyOp::Add;
  int body = 0;  // which body an Add/Intersect applies to (Cut applies to every body)
  bool suppressed = false;
  Json params = Json::object();
};

struct Variable {
  std::string name;
  std::string expr;
};

struct Viewpoint {
  std::string name;
  std::array<double, 3> position{};
  double yaw = 0, pitch = 0, size = 1;
};

struct PartDocument {
  std::string fileId = newId();
  std::string name = "Part";
  std::string units = "mm";  // display and bare-number unit
  std::string material = "Aluminium 6061";
  double density = 2700;  // kg/m^3
  std::vector<Variable> variables;
  std::vector<Feature> features;
  std::vector<Viewpoint> viewpoints;

  Feature* find(const std::string& id);
  const Feature* find(const std::string& id) const;
  std::string uniqueName(const std::string& base) const;
  Feature& add(Feature f);  // fills id and name when empty

  Json featuresJson() const;
  Json variablesJson() const;
  void loadFeatures(const Json& j);
  void loadVariables(const Json& j);

  static PartDocument sample();  // the pavilion from the v1 prototype, plus a cut and a fillet
};

// A rigid placement: translation in metres and a unit quaternion (x, y, z, w).
struct Placement {
  std::array<double, 3> t{0, 0, 0};
  std::array<double, 4> q{0, 0, 0, 1};
};

struct Component {
  std::string id = newId();
  std::string name;
  std::string path;                    // relative path to a .fpprt / .fpasm, or empty if virtual
  std::string fileId;                  // id of the referenced file, for finding moved files
  std::optional<PartDocument> virtualPart;  // part stored inside the assembly
  Placement placement;
  bool grounded = false;
  bool suppressed = false;
};

// Mates are stored with their references now; the solver arrives in Phase 3.
struct Mate {
  std::string id = newId();
  std::string type;  // coincident, concentric, distance, angle, parallel, hinge, slider, ...
  Json refs = Json::array();
  Json params = Json::object();
  bool suppressed = false;
};

struct AssemblyDocument {
  std::string fileId = newId();
  std::string name = "Assembly";
  std::string units = "mm";
  std::vector<Component> components;
  std::vector<Mate> mates;

  Json componentsJson() const;
  Json matesJson() const;
  void loadComponents(const Json& j);
  void loadMates(const Json& j);

  // A plate with four pins: one pin part placed four times (instances share geometry).
  static AssemblyDocument sample();
};

}  // namespace fpcad
