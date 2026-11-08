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
#include "fpcad/Sketch.h"

class TopoDS_Shape;

namespace fpcad {

using Vec3 = std::array<double, 3>;

struct FeatureStatus {
  std::string featureId;
  bool ok = true;
  std::string message;
  bool rolledBack = false;  // below the rollback bar: not built
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

// Reference geometry as the game draws it. Planes and coordinate systems: a frame (origin, x, y,
// normal) and a half-size for drawing; axes: origin and direction (xdir) with a half-length;
// points: origin. kind is plane, axis, point or csys.
struct ReferenceView {
  std::string featureId;
  std::string name;
  std::string kind;
  bool ok = true;
  std::string message;
  Vec3 origin{};
  Vec3 xdir{1, 0, 0};
  Vec3 ydir{0, 1, 0};
  Vec3 normal{0, 0, 1};
  double size = 0.5;
};

struct BoundingBox {
  Vec3 min{};
  Vec3 max{};
};

// A sketch as the game draws it: world-space line segments (pairs of points).
struct SketchView {
  std::string featureId;
  std::string name;
  std::string planeName;
  bool consumed = false;  // used by a later feature (hidden by default, like most CAD tools)
  bool ok = true;
  int dof = 0;
  int regions = 0;        // closed profiles
  std::string message;
  std::vector<Vec3> segments;
  std::vector<Vec3> constructionSegments;
  std::vector<Vec3> fill;  // closed regions as triangles (three points each)
};

struct SketchHit {
  std::string featureId;
  int region = -1;        // closed profile under the point, or -1 when near a line only
  Vec3 point{};
  double distance = 0;
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
  // Section view: {point, normal} cuts every body for display, walking and picking (the side
  // the normal points to is taken away); nullopt shows the whole part. The model is unchanged.
  void setSection(const std::optional<std::pair<Vec3, Vec3>>& plane);
  bool hasSection() const;

  // Measuring a face: its area, surface kind, and for round faces the radius and axis.
  struct FaceMeasure {
    bool ok = false;
    double area = 0;
    std::string kind;
    double radius = 0;   // cylinders, spheres, tori (minor radius: see radius2), cones at mid
    double radius2 = 0;  // torus major radius
    Vec3 normal{};       // flat faces: outward normal
    Vec3 axis{};         // round faces: axis direction
    Vec3 centre{};       // round faces: a point on the axis; flat faces: the face's centre
  };
  FaceMeasure faceMeasure(int body, int face) const;
  // A face reference {probe, normal, feature, role} found in this part and measured; the found
  // point is in centre when the face is flat. ok is false when the face is not there.
  FaceMeasure resolveFace(const Json& ref) const;

  // Overlapping bodies: each pair whose solids share volume, with that volume and its centre.
  struct Interference {
    int a = -1, b = -1;
    double volume = 0;
    Vec3 centre{};
  };
  std::vector<Interference> interference() const;
  // The role of face (index in body) within the feature that made it ("end", "side2", "p+z"),
  // stored in face references so they find the same face after upstream edits. Empty if none.
  std::string faceRole(int body, int face) const;
  const TopoDS_Shape& body(int index) const;

  // Display mesh for one body. linearDeflection in metres; scale it with the player's size.
  BodyMesh mesh(int body, double linearDeflection, double angularDeflectionRad = 0.35) const;

  // Exact ray pick against every body.
  std::optional<PickHit> pick(const Vec3& origin, const Vec3& direction, double maxDistance = 1e9) const;

  // Which parameter a push/pull on this face drives, if any.
  std::optional<FaceDrive> faceDrive(const PickHit& hit) const;

  // Moves the face along its normal by delta metres, then rebuilds. A face with a driving
  // parameter has that parameter edited; any other face gets stock added or removed through
  // offsetFace. Returns false (and changes nothing) when the result would be invalid.
  bool pushPull(const PickHit& hit, double delta, std::string* message = nullptr);

  // Adds (delta > 0) or removes stock on the hit face, as a "face_offset" feature (Push/Pull N)
  // whose distance then drives that face; pushing the same spot again edits it. Works on flat
  // faces (a prism) and curved ones (thickened along the surface).
  bool offsetFace(const PickHit& hit, double delta, std::string* message = nullptr);

  MassProperties massProperties() const;

  // The edge nearest a point (within maxDistance): its middle (how fillet / chamfer picks refer to
  // it), points along it for drawing, its length and, for a circle or arc, its radius.
  struct EdgeInfo {
    int body = -1;
    Vec3 mid{};
    std::vector<Vec3> points;
    double length = 0;
    double radius = 0;
  };
  std::optional<EdgeInfo> edgeNear(const Vec3& point, double maxDistance) const;

  // Corner points of one face (for measure snapping), metres.
  std::vector<Vec3> faceVertices(int body, int face) const;

  // A face's edges flattened onto a sketch plane (Convert Entities / Project Geometry), in plane
  // coordinates. Lines stay lines; circles and arcs square to the plane stay circles and arcs
  // (arcs counter-clockwise: centre, start, end); any other curve becomes a fit-point spline.
  // Edges that flatten to a point are left out.
  struct ProjectedCurve {
    std::string kind;  // line, circle, arc, spline
    std::vector<std::array<double, 2>> pts;  // line: a, b · circle: centre · arc: centre, start, end · spline: fit points
    double r = 0;      // circles
    bool closed = false;  // closed splines (the first point is not repeated)
  };
  std::vector<ProjectedCurve> projectFace(int body, int face, const SketchPlane& plane) const;

  // Converts a face's edges into the sketch as fixed geometry linked to the face: on every rebuild
  // the face (found again near probe, a point on it) is projected afresh and the geometry follows,
  // keeping its ids so dimensions and relations to it survive.
  bool convertFace(Sketch& sketch, int body, int face, const Vec3& probe, std::string* message = nullptr);

  // ----- Sketches -----

  // Solves a sketch against the part's variables (for live editing before it is committed).
  SolveResult solve(Sketch& s) const;

  // Every sketch feature after the last rebuild.
  std::vector<SketchView> sketchViews() const;

  // ----- Reference geometry -----
  //
  // Features of type "plane", "axis", "point" and "csys" make no solid; they are worked out on
  // every rebuild from what they refer to, so they follow the model. References in their params:
  //   plane ref: "top" | "front" | "right" | {"feature": id} (a plane or csys) |
  //              {"face": {probe[3], normal[3], feature}} (a flat face, found again like
  //              push/pull faces)
  //   axis ref:  "x" | "y" | "z" | {"feature": id} | {"edge": {probe[3]}} (the straight edge
  //              nearest probe) | {"cylinder": {probe[3], normal[3], feature}}
  //   point ref: "o" | {"feature": id} | {"vertex": {probe[3]}} (the vertex nearest probe)
  // Feature params:
  //   plane  kind offset {base, distance} · angle {base, axis, angle} · points {points: [3]} ·
  //          midplane {base, other}
  //   axis   kind ref {ref} · points {points: [2]} · planes {base, other}
  //   point  kind xyz {x, y, z} · ref {ref} · centre {face}
  //   csys   {origin: point ref, z[3], x[3]}
  // A sketch with params.planeRef = a plane (or csys) feature id sits on that plane and moves
  // with it; a revolve's axis may be an axis feature id.

  std::vector<ReferenceView> referenceViews() const;

  // The plane of a plane feature, or the XY plane of a csys, for sketching on.
  std::optional<SketchPlane> referencePlane(const std::string& featureId) const;

  // The straight edge of the hit face nearest the hit point: its two ends. Nothing when the face
  // has no straight edge within tolerance (metres) of the point.
  std::optional<std::array<Vec3, 2>> straightEdgeNear(const PickHit& hit, double tolerance) const;

  // Whether the hit face is a cylinder (its axis can be an axis reference).
  bool isCylinder(const PickHit& hit) const;

  // The parts' extent, axis-aligned; nothing for an empty part.
  std::optional<BoundingBox> boundingBox() const;

  // A plane on the picked face when it is flat; origin is the part origin projected onto it.
  std::optional<SketchPlane> planeFromHit(const PickHit& hit, std::string* name = nullptr) const;

  // Ray against sketches: inside a closed profile, or within tolerance·distance of a line.
  std::optional<SketchHit> pickSketch(const Vec3& origin, const Vec3& direction, double maxDistance,
                                      double tolerance, bool includeConsumed = false) const;

  bool isConsumed(const std::string& featureId) const;

  // The newest sketch no feature uses yet, or "".
  std::string latestUnusedSketch() const;

  // Evaluated variables (SI) after the last rebuild.
  const std::map<std::string, double>& variables() const;

  // Reads a parameter of a feature as SI, evaluating expressions.
  double param(const Feature& f, const std::string& key, double fallback = 0) const;

private:
  struct Impl;
  std::unique_ptr<Impl> d_;
};

}  // namespace fpcad
