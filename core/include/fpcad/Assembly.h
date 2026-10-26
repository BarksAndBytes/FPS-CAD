#pragma once
// A loaded assembly: every component's part rebuilt and placed in assembly space.
//
// Mates are stored in the document but not solved yet (Phase 3); component placements are used
// as saved.

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

private:
  void addComponents(const AssemblyDocument& doc, const std::string& dir, const Placement& parent, int depth);
  int partFor(const PartDocument& p);

  AssemblyDocument doc_;
  std::string baseDir_;
  std::vector<AssemblyPart> parts_;
  std::vector<PlacedComponent> placed_;
};

// Composes two placements: apply child, then parent.
Placement compose(const Placement& parent, const Placement& child);
Vec3 transformPoint(const Placement& p, const Vec3& v);

}  // namespace fpcad
