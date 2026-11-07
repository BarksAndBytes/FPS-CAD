#include "cad_assembly.h"

#include <filesystem>
#include <map>

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
    baseDir_ = dir.empty() ? "." : dir;
    model_ = std::make_unique<fpcad::AssemblyModel>(fpcad::loadAssembly(p), baseDir_);
    undo_.clear();
    redo_.clear();
    explode_ = 0;
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
  d["transform"] = toGodot(shown(size_t(index)));
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
    const fpcad::Placement place = shown(size_t(i));
    fpcad::Placement inv = inverse(place);
    fpcad::Vec3 lo = fpcad::transformPoint(inv, o);
    fpcad::Placement rot = inv;
    rot.t = {0, 0, 0};
    fpcad::Vec3 ld = fpcad::transformPoint(rot, dir);
    auto hit = model_->parts()[size_t(c.part)].model->pick(lo, ld, bestDist);
    if (!hit || hit->distance >= bestDist) continue;
    bestDist = hit->distance;
    fpcad::Placement r = place;
    r.t = {0, 0, 0};
    best = hitToDict(*hit);
    best["local_point"] = Array::make(hit->point[0], hit->point[1], hit->point[2]);
    best["local_normal"] = Array::make(hit->normal[0], hit->normal[1], hit->normal[2]);
    best["point"] = toGodot(fpcad::transformPoint(place, hit->point));
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

fpcad::Placement CadAssembly::shown(size_t index) const {
  const auto& comps = model_->components();
  fpcad::Placement p = comps[index].placement;
  if (explode_ <= 0) return p;
  // Each component moves away from the assembly's centre along the line through its own centre.
  auto centreOf = [&](size_t i) -> fpcad::Vec3 {
    const auto& c = comps[i];
    if (c.part < 0) return c.placement.t;
    fpcad::MassProperties m = model_->parts()[size_t(c.part)].model->massProperties();
    return fpcad::transformPoint(c.placement, m.centreOfMass);
  };
  fpcad::Vec3 all{0, 0, 0};
  int n = 0;
  for (size_t i = 0; i < comps.size(); ++i) {
    if (comps[i].part < 0) continue;
    fpcad::Vec3 c = centreOf(i);
    for (int k = 0; k < 3; ++k) all[size_t(k)] += c[size_t(k)];
    ++n;
  }
  if (n == 0) return p;
  for (auto& v : all) v /= n;
  fpcad::Vec3 mine = centreOf(index);
  for (int k = 0; k < 3; ++k) p.t[size_t(k)] += (mine[size_t(k)] - all[size_t(k)]) * explode_;
  return p;
}

void CadAssembly::reload(fpcad::AssemblyDocument doc) {
  model_ = std::make_unique<fpcad::AssemblyModel>(std::move(doc), baseDir_.empty() ? "." : baseDir_);
  model_->rebuild();
}

void CadAssembly::new_blank(const String& name, const String& base_dir) {
  fpcad::AssemblyDocument d;
  d.name = str(name).empty() ? "Assembly" : str(name);
  baseDir_ = str(base_dir);
  undo_.clear();
  redo_.clear();
  explode_ = 0;
  reload(d);
}

void CadAssembly::set_assembly_name(const String& name) {
  if (!str(name).empty()) model_->document().name = str(name);
}

void CadAssembly::checkpoint() {
  undo_.push_back(model_->document());
  if (undo_.size() > 100) undo_.erase(undo_.begin());
  redo_.clear();
}

bool CadAssembly::undo() {
  if (undo_.empty()) return false;
  redo_.push_back(model_->document());
  fpcad::AssemblyDocument d = undo_.back();
  undo_.pop_back();
  reload(d);
  return true;
}

bool CadAssembly::redo() {
  if (redo_.empty()) return false;
  undo_.push_back(model_->document());
  fpcad::AssemblyDocument d = redo_.back();
  redo_.pop_back();
  reload(d);
  return true;
}

Dictionary CadAssembly::insert_part(const String& path, const Transform3D& t) {
  namespace fs = std::filesystem;
  std::string p = str(path);
  std::string base = baseDir_.empty() ? "." : baseDir_;
  fs::path file(p);
  std::string rel = file.is_absolute() && file.parent_path() == fs::path(base) ? file.filename().string() : p;
  fpcad::Component c;
  try {
    fpcad::FileKind kind = fpcad::fileKind((fs::path(base) / rel).string());
    if (kind != fpcad::FileKind::Part && kind != fpcad::FileKind::Assembly) return result(false, "that is not a part");
    if (kind == fpcad::FileKind::Part) {
      fpcad::PartDocument pd = fpcad::loadPart((fs::path(base) / rel).string());
      c.name = pd.name;
      c.fileId = pd.fileId;
    } else {
      c.name = file.stem().string();
    }
  } catch (const std::exception& e) {
    return result(false, e.what());
  }
  checkpoint();
  // Instances are numbered: Bracket, Bracket <2>, ...
  int same = 0;
  for (auto& k : model_->document().components)
    if (k.name == c.name || k.name.rfind(c.name + " <", 0) == 0) ++same;
  if (same > 0) c.name += " <" + std::to_string(same + 1) + ">";
  c.path = rel;
  c.placement = toCad(t);
  c.grounded = model_->document().components.empty();
  std::string id = c.id;
  model_->document().components.push_back(c);
  model_->rebuild();
  Dictionary d = result(true, c.name + (c.grounded ? " placed and grounded" : " placed"));
  d["id"] = str(id);
  for (auto& pc : model_->components())
    if (pc.componentId == id && !pc.ok) {
      d["ok"] = false;
      d["message"] = str(pc.message);
    }
  return d;
}

Dictionary CadAssembly::remove_component(const String& id) {
  auto& comps = model_->document().components;
  for (size_t i = 0; i < comps.size(); ++i) {
    if (comps[i].id != str(id)) continue;
    checkpoint();
    std::string name = comps[i].name;
    comps.erase(comps.begin() + long(i));
    auto& mates = model_->document().mates;
    size_t before = mates.size();
    mates.erase(std::remove_if(mates.begin(), mates.end(), [&](const fpcad::Mate& m) {
                  for (auto& r : m.refs)
                    if (r.value("component", std::string()) == str(id)) return true;
                  return false;
                }),
                mates.end());
    model_->rebuild();
    size_t gone = before - mates.size();
    return result(true, name + " removed" + (gone ? " with " + std::to_string(gone) + (gone == 1 ? " mate" : " mates") : ""));
  }
  return result(false, "that component belongs to a sub-assembly");
}

Dictionary CadAssembly::set_grounded(const String& id, bool grounded) {
  for (auto& c : model_->document().components) {
    if (c.id != str(id)) continue;
    checkpoint();
    c.grounded = grounded;
    model_->solveMates();
    return result(true, c.name + (grounded ? " grounded: it stays put" : " floats: mates and dragging move it"));
  }
  return result(false, "that component belongs to a sub-assembly");
}

Dictionary CadAssembly::face_ref(const Dictionary& hit) const {
  Dictionary d;
  int i = int(hit.get("component", -1));
  if (i < 0 || i >= component_count() || !hit.has("local_point")) return d;
  const auto& c = model_->components()[size_t(i)];
  if (c.part < 0) return d;
  d["component"] = str(c.componentId);
  d["probe"] = hit["local_point"];
  d["normal"] = hit["local_normal"];
  d["feature"] = hit.get("feature_id", "");
  std::string role = model_->parts()[size_t(c.part)].model->faceRole(int(hit.get("body", -1)), int(hit.get("face", -1)));
  if (!role.empty()) d["role"] = str(role);
  return d;
}

Dictionary CadAssembly::face_measure(const Dictionary& hit) const {
  Dictionary d;
  d["ok"] = false;
  int i = int(hit.get("component", -1));
  if (i < 0 || i >= component_count()) return d;
  const auto& c = model_->components()[size_t(i)];
  if (c.part < 0) return d;
  auto m = model_->parts()[size_t(c.part)].model->faceMeasure(int(hit.get("body", -1)), int(hit.get("face", -1)));
  if (!m.ok) return d;
  fpcad::Placement place = shown(size_t(i));
  fpcad::Placement rot = place;
  rot.t = {0, 0, 0};
  d["ok"] = true;
  d["kind"] = str(m.kind);
  d["area"] = m.area;
  d["radius"] = m.radius;
  d["radius2"] = m.radius2;
  d["normal"] = toGodot(fpcad::transformPoint(rot, m.normal));
  d["axis"] = toGodot(fpcad::transformPoint(rot, m.axis));
  d["centre"] = toGodot(fpcad::transformPoint(place, m.centre));
  return d;
}

Dictionary CadAssembly::add_mate(const String& type, const Dictionary& a, const Dictionary& b, const Dictionary& params) {
  try {
    if (a.is_empty() || b.is_empty()) return result(false, "pick a face on each of two components");
    if (a.get("component", "") == b.get("component", "")) return result(false, "a mate joins two different components");
    checkpoint();
    fpcad::Mate m;
    m.type = str(type);
    m.refs = fpcad::Json::array({variantToJson(a), variantToJson(b)});
    m.params = variantToJson(params);
    if (!m.params.is_object()) m.params = fpcad::Json::object();
    if (m.type == "lock") {
      // Keep B where it is now relative to A.
      fpcad::Placement pa, pb;
      for (auto& c : model_->document().components) {
        if (c.id == str(String(a["component"]))) pa = c.placement;
        if (c.id == str(String(b["component"]))) pb = c.placement;
      }
      fpcad::Placement inv;
      inv.q = {-pa.q[0], -pa.q[1], -pa.q[2], pa.q[3]};
      fpcad::Vec3 it = fpcad::transformPoint(inv, pa.t);
      inv.t = {-it[0], -it[1], -it[2]};
      fpcad::Placement rel = fpcad::compose(inv, pb);
      m.params["t"] = {rel.t[0], rel.t[1], rel.t[2]};
      m.params["q"] = {rel.q[0], rel.q[1], rel.q[2], rel.q[3]};
    }
    std::string id = m.id;
    model_->document().mates.push_back(m);
    auto rep = model_->solveMates();
    bool failed = std::find(rep.failing.begin(), rep.failing.end(), id) != rep.failing.end();
    if (failed) {
      fpcad::AssemblyDocument before = undo_.back();
      undo_.pop_back();
      reload(before);
      return result(false, "that " + m.type + " mate cannot be met with the others (or those faces cannot take it)");
    }
    Dictionary d = result(true, m.type + " mate added · " + rep.message);
    d["id"] = str(id);
    return d;
  } catch (const std::exception& e) {
    return result(false, std::string("could not do that: ") + e.what());
  } catch (...) {
    return result(false, "could not do that: the geometry kernel failed");
  }
}

Dictionary CadAssembly::delete_mate(const String& id) {
  auto& mates = model_->document().mates;
  for (size_t i = 0; i < mates.size(); ++i) {
    if (mates[i].id != str(id)) continue;
    checkpoint();
    std::string type = mates[i].type;
    mates.erase(mates.begin() + long(i));
    model_->solveMates();
    return result(true, type + " mate deleted");
  }
  return result(false, "that mate no longer exists");
}

Array CadAssembly::mates() const {
  try {
    Array out;
    const auto& rep = model_->mateReport();
    std::map<std::string, std::string> names;
    for (auto& c : model_->document().components) names[c.id] = c.name;
    for (auto& m : model_->document().mates) {
      Dictionary d;
      d["id"] = str(m.id);
      d["type"] = str(m.type);
      std::string a = m.refs.size() > 0 ? m.refs[0].value("component", std::string()) : "";
      std::string b = m.refs.size() > 1 ? m.refs[1].value("component", std::string()) : "";
      d["a"] = str(names.count(a) ? names[a] : "?");
      d["b"] = str(names.count(b) ? names[b] : "?");
      d["ok"] = std::find(rep.failing.begin(), rep.failing.end(), m.id) == rep.failing.end();
      d["suppressed"] = m.suppressed;
      if (m.params.contains("distance")) d["value"] = m.params["distance"].get<double>();
      if (m.params.contains("angle")) d["value"] = m.params["angle"].get<double>();
      out.push_back(d);
    }
    return out;
  } catch (const std::exception& e) {
    (void)e;
    return Array();
  } catch (...) {
    return Array();
  }
}

Dictionary CadAssembly::mate_status() const {
  const auto& rep = model_->mateReport();
  return result(rep.ok, rep.message);
}

Dictionary CadAssembly::drag_component(const String& id, const Vector3& delta) {
  fpcad::Placement rot;
  fpcad::Vec3 d = toCad(delta);
  auto rep = model_->drag(str(id), d);
  return result(rep.ok, rep.message);
}

Array CadAssembly::interference() const {
  Array out;
  for (auto& x : model_->interference()) {
    Dictionary d;
    d["a"] = str(model_->components()[size_t(x.a)].name);
    d["b"] = str(model_->components()[size_t(x.b)].name);
    d["volume"] = x.volume;
    d["centre"] = toGodot(x.centre);
    out.push_back(d);
  }
  return out;
}

Array CadAssembly::bom() const {
  Array out;
  std::vector<int> count(model_->parts().size(), 0);
  for (auto& c : model_->components())
    if (c.part >= 0) ++count[size_t(c.part)];
  for (size_t p = 0; p < model_->parts().size(); ++p) {
    if (count[p] == 0) continue;
    const auto& part = model_->parts()[p];
    Dictionary d;
    d["name"] = str(part.name);
    d["quantity"] = count[p];
    d["material"] = str(part.model->document().material);
    d["mass"] = part.model->massProperties().mass;
    out.push_back(d);
  }
  return out;
}

void CadAssembly::set_explode(double factor) { explode_ = std::max(0.0, factor); }

Array CadAssembly::components() const {
  Array out;
  for (auto& c : model_->document().components) {
    Dictionary d;
    d["id"] = str(c.id);
    d["name"] = str(c.name);
    d["grounded"] = c.grounded;
    d["ok"] = true;
    for (auto& pc : model_->components())
      if (pc.componentId == c.id && !pc.ok) d["ok"] = false;
    out.push_back(d);
  }
  return out;
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
  ClassDB::bind_method(D_METHOD("new_blank", "name", "base_dir"), &CadAssembly::new_blank);
  ClassDB::bind_method(D_METHOD("set_assembly_name", "name"), &CadAssembly::set_assembly_name);
  ClassDB::bind_method(D_METHOD("insert_part", "path", "transform"), &CadAssembly::insert_part);
  ClassDB::bind_method(D_METHOD("remove_component", "id"), &CadAssembly::remove_component);
  ClassDB::bind_method(D_METHOD("set_grounded", "id", "grounded"), &CadAssembly::set_grounded);
  ClassDB::bind_method(D_METHOD("face_ref", "hit"), &CadAssembly::face_ref);
  ClassDB::bind_method(D_METHOD("face_measure", "hit"), &CadAssembly::face_measure);
  ClassDB::bind_method(D_METHOD("add_mate", "type", "a", "b", "params"), &CadAssembly::add_mate);
  ClassDB::bind_method(D_METHOD("delete_mate", "id"), &CadAssembly::delete_mate);
  ClassDB::bind_method(D_METHOD("mates"), &CadAssembly::mates);
  ClassDB::bind_method(D_METHOD("mate_status"), &CadAssembly::mate_status);
  ClassDB::bind_method(D_METHOD("drag_component", "id", "delta"), &CadAssembly::drag_component);
  ClassDB::bind_method(D_METHOD("interference"), &CadAssembly::interference);
  ClassDB::bind_method(D_METHOD("bom"), &CadAssembly::bom);
  ClassDB::bind_method(D_METHOD("set_explode", "factor"), &CadAssembly::set_explode);
  ClassDB::bind_method(D_METHOD("get_explode"), &CadAssembly::get_explode);
  ClassDB::bind_method(D_METHOD("components"), &CadAssembly::components);
  ClassDB::bind_method(D_METHOD("checkpoint"), &CadAssembly::checkpoint);
  ClassDB::bind_method(D_METHOD("undo"), &CadAssembly::undo);
  ClassDB::bind_method(D_METHOD("redo"), &CadAssembly::redo);
}

}  // namespace fpcad_gd
