#include "fpcad/Assembly.h"

#include <cmath>
#include <filesystem>

#include "fpcad/FileIO.h"

namespace fpcad {
namespace {

using Quat = std::array<double, 4>;  // x y z w

Quat mul(const Quat& a, const Quat& b) {
  return {a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
          a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
          a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
          a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]};
}

Vec3 rotate(const Quat& q, const Vec3& v) {
  Quat p{v[0], v[1], v[2], 0};
  Quat qc{-q[0], -q[1], -q[2], q[3]};
  Quat r = mul(mul(q, p), qc);
  return {r[0], r[1], r[2]};
}

Quat normalised(Quat q) {
  double n = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  if (n < 1e-12) return {0, 0, 0, 1};
  for (auto& c : q) c /= n;
  return q;
}

}  // namespace

Vec3 transformPoint(const Placement& p, const Vec3& v) {
  Vec3 r = rotate(normalised(p.q), v);
  return {r[0] + p.t[0], r[1] + p.t[1], r[2] + p.t[2]};
}

Placement compose(const Placement& parent, const Placement& child) {
  Placement out;
  out.q = normalised(mul(normalised(parent.q), normalised(child.q)));
  out.t = transformPoint(parent, child.t);
  return out;
}

AssemblyModel::AssemblyModel(AssemblyDocument doc, std::string baseDir)
    : doc_(std::move(doc)), baseDir_(std::move(baseDir)) {}

int AssemblyModel::partFor(const PartDocument& p) {
  for (size_t i = 0; i < parts_.size(); ++i) if (parts_[i].key == p.fileId) return static_cast<int>(i);
  AssemblyPart ap;
  ap.key = p.fileId;
  ap.name = p.name;
  ap.model = std::make_shared<PartModel>(p);
  ap.model->rebuild();
  parts_.push_back(std::move(ap));
  return static_cast<int>(parts_.size() - 1);
}

void AssemblyModel::addComponents(const AssemblyDocument& doc, const std::string& dir,
                                  const Placement& parent, int depth) {
  namespace fs = std::filesystem;
  for (auto& c : doc.components) {
    if (c.suppressed) continue;
    PlacedComponent pc;
    pc.componentId = c.id;
    pc.name = c.name;
    pc.placement = compose(parent, c.placement);
    try {
      if (c.virtualPart) {
        pc.part = partFor(*c.virtualPart);
      } else {
        fs::path file = fs::path(dir) / c.path;
        FileKind kind = fileKind(file.string());
        if (kind == FileKind::Part) {
          pc.part = partFor(loadPart(file.string()));
        } else if (kind == FileKind::Assembly) {
          if (depth > 32) throw FileError("assemblies are nested too deeply (is one including itself?)");
          addComponents(loadAssembly(file.string()), file.parent_path().string(), pc.placement, depth + 1);
          continue;
        } else {
          throw FileError("cannot open '" + c.path + "'");
        }
      }
      const auto& rep = parts_[static_cast<size_t>(pc.part)].model->lastReport();
      if (!rep.ok) {
        pc.ok = false;
        pc.message = "part has rebuild errors";
      }
    } catch (const std::exception& e) {
      pc.ok = false;
      pc.message = e.what();
    }
    placed_.push_back(pc);
  }
}

bool AssemblyModel::rebuild() {
  parts_.clear();
  placed_.clear();
  addComponents(doc_, baseDir_, Placement{}, 0);
  for (auto& p : placed_) if (!p.ok) return false;
  return true;
}

MassProperties AssemblyModel::massProperties() const {
  MassProperties m;
  double mx = 0, my = 0, mz = 0;
  for (auto& pc : placed_) {
    if (pc.part < 0) continue;
    MassProperties pm = parts_[static_cast<size_t>(pc.part)].model->massProperties();
    Vec3 c = transformPoint(pc.placement, pm.centreOfMass);
    m.volume += pm.volume;
    m.area += pm.area;
    m.mass += pm.mass;
    m.bodies += pm.bodies;
    mx += c[0] * pm.volume;
    my += c[1] * pm.volume;
    mz += c[2] * pm.volume;
  }
  if (m.volume > 0) m.centreOfMass = {mx / m.volume, my / m.volume, mz / m.volume};
  return m;
}

}  // namespace fpcad
