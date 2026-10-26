#include "cad_assembly.h"

#include <filesystem>

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "convert.h"
#include "fpcad/Export.h"
#include "fpcad/FileIO.h"

using namespace godot;

namespace fpcad_gd {

namespace {
Dictionary result(bool ok, const std::string& message) {
  Dictionary d;
  d["ok"] = ok;
  d["message"] = str(message);
  return d;
}

// Inverse of a placement, for turning an assembly-space ray into part space.
fpcad::Placement inverse(const fpcad::Placement& p) {
  fpcad::Placement inv;
  inv.q = {-p.q[0], -p.q[1], -p.q[2], p.q[3]};
  fpcad::Vec3 t = fpcad::transformPoint(inv, p.t);
  inv.t = {-t[0], -t[1], -t[2]};
  return inv;
}
}  // namespace

CadAssembly::CadAssembly() : model_(std::make_unique<fpcad::AssemblyModel>(fpcad::AssemblyDocument{}, ".")) {}

void CadAssembly::make_sample() {
  model_ = std::make_unique<fpcad::AssemblyModel>(fpcad::AssemblyDocument::sample(), ".");
}

String CadAssembly::load_file(const String& path) {
  try {
    std::string p = str(path);
    auto dir = std::filesystem::path(p).parent_path().string();
    model_ = std::make_unique<fpcad::AssemblyModel>(fpcad::loadAssembly(p), dir.empty() ? "." : dir);
    return "";
  } catch (const std::exception& e) {
    return str(e.what());
  }
}

String CadAssembly::save_file(const String& path) {
  try {
    fpcad::saveAssembly(str(path), model_->document());
    return "";
  } catch (const std::exception& e) {
    return str(e.what());
  }
}

String CadAssembly::get_assembly_name() const { return str(model_->document().name); }

Dictionary CadAssembly::rebuild() {
  bool ok = model_->rebuild();
  Dictionary d;
  d["ok"] = ok;
  Array failures;
  for (auto& c : model_->components()) {
    if (c.ok) continue;
    Dictionary f;
    f["name"] = str(c.name);
    f["message"] = str(c.message);
    failures.push_back(f);
  }
  d["failures"] = failures;
  return d;
}

int CadAssembly::part_count() const { return int(model_->parts().size()); }

String CadAssembly::part_name(int part) const {
  if (part < 0 || part >= part_count()) return "";
  return str(model_->parts()[size_t(part)].name);
}

Ref<ArrayMesh> CadAssembly::part_mesh(int part, double deflection) const {
  Ref<ArrayMesh> mesh;
  mesh.instantiate();
  if (part < 0 || part >= part_count()) return mesh;
  const auto& pm = *model_->parts()[size_t(part)].model;
  for (int b = 0; b < pm.bodyCount(); ++b) {
    fpcad::BodyMesh m = pm.mesh(b, deflection);
    if (m.indices.empty()) continue;
    PackedVector3Array verts, normals;
    PackedInt32Array idx;
    for (size_t i = 0; i < m.positions.size(); i += 3) {
      verts.push_back(toGodot(m.positions[i], m.positions[i + 1], m.positions[i + 2]));
      normals.push_back(toGodot(m.normals[i], m.normals[i + 1], m.normals[i + 2]));
    }
    for (size_t t = 0; t < m.indices.size(); t += 3) {
      idx.push_back(int32_t(m.indices[t]));
      idx.push_back(int32_t(m.indices[t + 2]));
      idx.push_back(int32_t(m.indices[t + 1]));
    }
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = verts;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_INDEX] = idx;
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
  }
  return mesh;
}

PackedVector3Array CadAssembly::part_edges(int part, double deflection) const {
  PackedVector3Array out;
  if (part < 0 || part >= part_count()) return out;
  const auto& pm = *model_->parts()[size_t(part)].model;
  for (int b = 0; b < pm.bodyCount(); ++b) {
    fpcad::BodyMesh m = pm.mesh(b, deflection);
    for (size_t i = 0; i < m.edgeLines.size(); i += 3)
      out.push_back(toGodot(m.edgeLines[i], m.edgeLines[i + 1], m.edgeLines[i + 2]));
  }
  return out;
}

int CadAssembly::component_count() const { return int(model_->components().size()); }

Dictionary CadAssembly::component(int index) const {
  Dictionary d;
  if (index < 0 || index >= component_count()) return d;
  const auto& c = model_->components()[size_t(index)];
  d["id"] = str(c.componentId);
  d["name"] = str(c.name);
  d["part"] = c.part;
  d["transform"] = toGodot(c.placement);
  d["ok"] = c.ok;
  d["message"] = str(c.message);
  return d;
}

Dictionary CadAssembly::set_component_transform(const String& id, const Transform3D& t) {
  // Only top-level components can be moved directly; nested ones move with their sub-assembly.
  for (auto& c : model_->document().components) {
    if (c.id == str(id)) {
      c.placement = toCad(t);
      model_->rebuild();
      return result(true, c.name + " moved");
    }
  }
  return result(false, "that component belongs to a sub-assembly; open it to move it");
}

Dictionary CadAssembly::pick(const Vector3& origin, const Vector3& direction, double max_distance) const {
  Dictionary best;
  double bestDist = max_distance;
  fpcad::Vec3 o = toCad(origin), dir = toCad(direction);
  for (int i = 0; i < component_count(); ++i) {
    const auto& c = model_->components()[size_t(i)];
    if (c.part < 0) continue;
    fpcad::Placement inv = inverse(c.placement);
    fpcad::Vec3 lo = fpcad::transformPoint(inv, o);
    fpcad::Placement rot = inv;
    rot.t = {0, 0, 0};
    fpcad::Vec3 ld = fpcad::transformPoint(rot, dir);
    auto hit = model_->parts()[size_t(c.part)].model->pick(lo, ld, bestDist);
    if (!hit || hit->distance >= bestDist) continue;
    bestDist = hit->distance;
    fpcad::Placement r = c.placement;
    r.t = {0, 0, 0};
    best = hitToDict(*hit);
    best["point"] = toGodot(fpcad::transformPoint(c.placement, hit->point));
    best["normal"] = toGodot(fpcad::transformPoint(r, hit->normal));
    best["component"] = i;
    best["component_id"] = str(c.componentId);
    best["component_name"] = str(c.name);
  }
  return best;
}

Dictionary CadAssembly::mass_properties() const {
  fpcad::MassProperties m = model_->massProperties();
  Dictionary d;
  d["volume"] = m.volume;
  d["area"] = m.area;
  d["mass"] = m.mass;
  d["bodies"] = m.bodies;
  d["centre_of_mass"] = toGodot(m.centreOfMass);
  return d;
}

Dictionary CadAssembly::export_file(const String& path, const String& units) {
  fpcad::ExportOptions o;
  if (!units.is_empty()) o.units = str(units);
  fpcad::ExportResult r = fpcad::exportAssembly(*model_, str(path), o);
  Dictionary d = result(r.ok, r.message);
  d["bodies"] = r.bodies;
  d["triangles"] = int64_t(r.triangles);
  d["validated"] = r.validated;
  return d;
}

void CadAssembly::_bind_methods() {
  ClassDB::bind_method(D_METHOD("make_sample"), &CadAssembly::make_sample);
  ClassDB::bind_method(D_METHOD("load_file", "path"), &CadAssembly::load_file);
  ClassDB::bind_method(D_METHOD("save_file", "path"), &CadAssembly::save_file);
  ClassDB::bind_method(D_METHOD("get_assembly_name"), &CadAssembly::get_assembly_name);
  ClassDB::bind_method(D_METHOD("rebuild"), &CadAssembly::rebuild);
  ClassDB::bind_method(D_METHOD("part_count"), &CadAssembly::part_count);
  ClassDB::bind_method(D_METHOD("part_name", "part"), &CadAssembly::part_name);
  ClassDB::bind_method(D_METHOD("part_mesh", "part", "deflection"), &CadAssembly::part_mesh);
  ClassDB::bind_method(D_METHOD("part_edges", "part", "deflection"), &CadAssembly::part_edges);
  ClassDB::bind_method(D_METHOD("component_count"), &CadAssembly::component_count);
  ClassDB::bind_method(D_METHOD("component", "index"), &CadAssembly::component);
  ClassDB::bind_method(D_METHOD("set_component_transform", "id", "transform"), &CadAssembly::set_component_transform);
  ClassDB::bind_method(D_METHOD("pick", "origin", "direction", "max_distance"), &CadAssembly::pick);
  ClassDB::bind_method(D_METHOD("mass_properties"), &CadAssembly::mass_properties);
  ClassDB::bind_method(D_METHOD("export_file", "path", "units"), &CadAssembly::export_file);
}

}  // namespace fpcad_gd
