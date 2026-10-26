#pragma once
// Rebuilding a part's history into exact B-rep solids, and everything the game needs from them:
// display meshes, exact picking, push/pull edits and mass properties.
//
// OCCT types stay behind the pimpl so the game binding only sees plain data.

#include <array>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "fpcad/Document.h"

class TopoDS_Shape;

namespace fpcad {

using Vec3 = std::array<double, 3>;

struct FeatureStatus {
  std::string featureId;
  bool ok = true;
  std::string message;
};

struct RebuildReport {
  bool ok = true;  // false when any feature failed
  std::vector<FeatureStatus> features;
  double milliseconds = 0;
};

// Face metadata, indexed by the per-body face index used in meshes and picks.
struct FaceInfo {
  std::string featureId;  // the feature that created this face
  std::string kind;       // plane, cylinder, cone, sphere, torus, other
  Vec3 normal{};          // outward normal at the face centre
};

struct BodyMesh {
  std::vector<float> positions;     // xyz per vertex, metres
  std::vector<float> normals;       // xyz per vertex
  std::vector<uint32_t> indices;    // three per triangle, counter-clockwise seen from outside
  std::vector<int32_t> triangleFace;  // face index for each triangle
  std::vector<FaceInfo> faces;
  std::vector<float> edgeLines;     // feature edges as line segments, xyz pairs
};

struct PickHit {
  int body = -1;
  int face = -1;
  std::string featureId;
  Vec3 point{};
  Vec3 normal{};  // outward
  double distance = 0;
};

struct MassProperties {
  double volume = 0;  // m^3
  double area = 0;    // m^2
  double mass = 0;    // kg
  Vec3 centreOfMass{};
  int bodies = 0;
};

// What a push/pull on a face would change, for HUD labels and for applying the edit.
struct FaceDrive {
  std::string featureId;
  std::string param;  // e.g. "h", "w", "r", "depth", "profile.w"
  std::string label;  // e.g. "top face · height"
  double value = 0;   // current value in metres
};

class PartModel {
public:
  explicit PartModel(PartDocument doc = {});
  ~PartModel();
  PartModel(PartModel&&) noexcept;
  PartModel& operator=(PartModel&&) noexcept;

  const PartDocument& document() const;
  PartDocument& document();  // edit, then call rebuild()

  RebuildReport rebuild();
  const RebuildReport& lastReport() const;

  int bodyCount() const;
  const TopoDS_Shape& body(int index) const;

  // Display mesh for one body. linearDeflection in metres; scale it with the player's size.
  BodyMesh mesh(int body, double linearDeflection, double angularDeflectionRad = 0.35) const;

  // Exact ray pick against every body.
  std::optional<PickHit> pick(const Vec3& origin, const Vec3& direction, double maxDistance = 1e9) const;

  // Which parameter a push/pull on this face drives, if any.
  std::optional<FaceDrive> faceDrive(const PickHit& hit) const;

  // Moves the face along its normal by delta metres by editing the driving parameter, then
  // rebuilds. Returns false (and changes nothing) when the face has no driving parameter or the
  // result would be invalid.
  bool pushPull(const PickHit& hit, double delta, std::string* message = nullptr);

  MassProperties massProperties() const;

  // Corner points of one face (for measure snapping), metres.
  std::vector<Vec3> faceVertices(int body, int face) const;

  // Evaluated variables (SI) after the last rebuild.
  const std::map<std::string, double>& variables() const;

  // Reads a parameter of a feature as SI, evaluating expressions.
  double param(const Feature& f, const std::string& key, double fallback = 0) const;

private:
  struct Impl;
  std::unique_ptr<Impl> d_;
};

}  // namespace fpcad
