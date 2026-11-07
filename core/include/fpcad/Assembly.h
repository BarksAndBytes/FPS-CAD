#pragma once
// A loaded assembly: every component's part rebuilt and placed in assembly space, with its mates
// solved (0.8): coincident, concentric, distance, angle and lock between faces of top-level
// components; grounded components stay put.

#include <memory>
#include <string>
#include <vector>

#include "fpcad/Document.h"
#include "fpcad/Model.h"

namespace fpcad {

struct PlacedComponent {
  std::string componentId;
  std::string name;
  int part = -1;  // index into AssemblyModel::parts(); instances of one file share a part
  Placement placement;
  bool ok = true;
  std::string message;
};

struct AssemblyPart {
  std::string key;  // fileId of the part
  std::string name;
  std::shared_ptr<PartModel> model;
};

class AssemblyModel {
public:
  // baseDir resolves components' relative paths. Sub-assemblies are flattened into placed parts.
  AssemblyModel(AssemblyDocument doc, std::string baseDir);

  const AssemblyDocument& document() const { return doc_; }
  AssemblyDocument& document() { return doc_; }

  // Loads and rebuilds every referenced part. Returns false when any component failed.
  bool rebuild();

  const std::vector<AssemblyPart>& parts() const { return parts_; }
  const std::vector<PlacedComponent>& components() const { return placed_; }

  MassProperties massProperties() const;

  // Solves the mates, moving top-level components that are not grounded as little as possible.
  struct MateReport {
    bool ok = true;
    std::string message;
    std::vector<std::string> failing;  // mate ids still not met
  };
  MateReport solveMates();
  const MateReport& mateReport() const { return mates_; }
  // Moves a top-level component by delta (assembly space) and solves the mates, so it only goes
  // where its mates allow. Refused (nothing moves) when it is grounded or unknown.
  MateReport drag(const std::string& componentId, const Vec3& delta);
  // Re-places the components from the document without reloading parts.
  void updatePlacements();

  // Pairs of placed components whose solids overlap, with the shared volume and its centre.
  struct Clash {
    int a = -1, b = -1;
    double volume = 0;
    Vec3 centre{};
  };
  std::vector<Clash> interference() const;

private:
  void addComponents(const AssemblyDocument& doc, const std::string& dir, const Placement& parent, int depth);
  int partFor(const PartDocument& p);

  AssemblyDocument doc_;
  std::string baseDir_;
  std::vector<AssemblyPart> parts_;
  std::vector<PlacedComponent> placed_;
  MateReport mates_;
  bool nested_ = false;  // a top-level component is a sub-assembly: placements need a full rebuild
};

// Composes two placements: apply child, then parent.
Placement compose(const Placement& parent, const Placement& child);
Vec3 transformPoint(const Placement& p, const Vec3& v);

}  // namespace fpcad
