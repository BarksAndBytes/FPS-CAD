#include "cad_part.h"

#include <algorithm>
#include <cmath>
#if defined(__unix__) || defined(__APPLE__)
#include <dlfcn.h>
#endif
#include <set>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include "convert.h"
#include "fpcad/Challenges.h"
#include "fpcad/Compare.h"
#include "fpcad/Expression.h"
#include "fpcad/Export.h"
#include "fpcad/FileIO.h"
#include "fpcad/Materials.h"

using namespace godot;

namespace fpcad_gd {

namespace {
constexpr size_t kUndoLimit = 200;

Dictionary result(bool ok, const std::string& message) {
  Dictionary d;
  d["ok"] = ok;
  d["message"] = str(message);
  return d;
}

Dictionary materialDict(const fpcad::Material& m) {
  Dictionary d;
  d["name"] = str(m.name);
  d["category"] = str(m.category);
  d["density"] = m.density;
  d["youngs_modulus"] = m.youngsModulus;
  d["poissons_ratio"] = m.poissonsRatio;
  d["yield_strength"] = m.yieldStrength ? Variant(*m.yieldStrength) : Variant();
  d["tensile_strength"] = m.tensileStrength ? Variant(*m.tensileStrength) : Variant();
  d["thermal_conductivity"] = m.thermalConductivity;
  d["specific_heat"] = m.specificHeat;
  d["thermal_expansion"] = m.thermalExpansion;
  d["color"] = str(m.color);
  d["metallic"] = m.metallic;
  d["roughness"] = m.roughness;
  d["opacity"] = m.opacity;
  return d;
}

// Size and position of everything, to check a unit change left the part as it was.
std::vector<double> signature(const fpcad::PartModel& m) {
  fpcad::MassProperties mp = m.massProperties();
  std::vector<double> s = {mp.volume, mp.area, mp.centreOfMass[0], mp.centreOfMass[1], mp.centreOfMass[2]};
  if (auto b = m.boundingBox())
    for (int i = 0; i < 3; ++i) s.insert(s.end(), {b->min[i], b->max[i]});
  return s;
}
}  // namespace

CadPart::CadPart() : model_(std::make_unique<fpcad::PartModel>()) {}

void CadPart::make_sample() {
  model_ = std::make_unique<fpcad::PartModel>(fpcad::PartDocument::sample());
  undo_.clear();
  redo_.clear();
}

void CadPart::make_training() {
  model_ = std::make_unique<fpcad::PartModel>(fpcad::PartDocument::trainingCourse());
  undo_.clear();
  redo_.clear();
}

void CadPart::make_desk_sample() {
  model_ = std::make_unique<fpcad::PartModel>(fpcad::PartDocument::deskSample());
  undo_.clear();
  redo_.clear();
}

void CadPart::new_blank(const String& name, const String& units) {
  fpcad::PartDocument d;
  d.name = str(name);
  d.units = str(units);
  model_ = std::make_unique<fpcad::PartModel>(d);
  undo_.clear();
  redo_.clear();
}

String CadPart::load_file(const String& path) {
  try {
    model_ = std::make_unique<fpcad::PartModel>(fpcad::loadPart(str(path)));
    undo_.clear();
    redo_.clear();
    return "";
  } catch (const std::exception& e) {
    return str(e.what());
  }
}

String CadPart::save_file(const String& path) {
  try {
    fpcad::savePart(str(path), model_->document(), model_.get());
    return "";
  } catch (const std::exception& e) {
    return str(e.what());
  }
}

String CadPart::get_part_name() const { return str(model_->document().name); }
void CadPart::set_part_name(const String& name) {
  std::string n = str(name.strip_edges());
  if (!n.empty()) model_->document().name = n;
}
String CadPart::get_units() const { return str(model_->document().units); }
String CadPart::get_file_id() const { return str(model_->document().fileId); }
String CadPart::get_material() const {
  const fpcad::Material* m = fpcad::findMaterial(model_->document().material);
  return str(m ? m->name : model_->document().material);
}

namespace {
void libraryMarker() {}
}  // namespace

// The folder this extension was loaded from. On Android that is the app's native library folder,
// the one place Android lets an app run a program it ships (the video board's FFmpeg).
String CadPart::native_library_dir() const {
#if defined(__unix__) || defined(__APPLE__)
  Dl_info info;
  if (dladdr(reinterpret_cast<void*>(&libraryMarker), &info) && info.dli_fname) {
    std::string p = info.dli_fname;
    auto slash = p.rfind('/');
    if (slash != std::string::npos) return str(p.substr(0, slash));
  }
#endif
  return String();
}

String CadPart::get_mass_units() const { return str(model_->document().massUnit()); }

Array CadPart::material_library() const {
  Array out;
  for (const auto& m : fpcad::materialLibrary()) out.push_back(materialDict(m));
  return out;
}

Dictionary CadPart::material_info() const {
  const auto& doc = model_->document();
  if (const fpcad::Material* m = fpcad::findMaterial(doc.material)) {
    Dictionary d = materialDict(*m);
    d["density"] = doc.density;
    return d;
  }
  fpcad::Material custom;  // a typed-in density: no other properties known
  custom.name = doc.material.empty() ? fpcad::kCustomMaterial : doc.material;
  custom.category = "Custom";
  custom.density = doc.density;
  Dictionary d = materialDict(custom);
  d["youngs_modulus"] = Variant();
  d["poissons_ratio"] = Variant();
  d["thermal_conductivity"] = Variant();
  d["specific_heat"] = Variant();
  d["thermal_expansion"] = Variant();
  return d;
}

Dictionary CadPart::set_material(const String& name, double density) {
  std::string n = str(name);
  const fpcad::Material* m = fpcad::findMaterial(n);
  if (!m && n != fpcad::kCustomMaterial) return result(false, "Unknown material '" + n + "'");
  if (!m && !(density > 0 && density < 1e6)) return result(false, "A density must be above zero");
  checkpoint();
  auto& doc = model_->document();
  doc.material = m ? m->name : n;
  doc.density = m ? m->density : density;
  return result(true, "");
}

// Brings in a STEP file as an import feature: a new body standing on the ground at the origin
// (or the part's first body when there is none yet).
Dictionary CadPart::import_step(const String& path) {
  fpcad::ImportResult im = fpcad::importStep(str(path));
  if (!im.ok) return result(false, im.message);
  checkpoint();
  auto& doc = model_->document();
  std::string id = fpcad::newId();
  doc.imports[id] = im.brep;
  fpcad::Feature f;
  f.type = "import";
  std::string file = str(path.get_file());
  f.name = doc.uniqueName("Import " + (file.empty() ? std::string("STEP") : file.substr(0, file.find_last_of('.'))));
  f.op = model_->bodyCount() == 0 ? fpcad::BodyOp::Add : fpcad::BodyOp::NewBody;
  f.params = {{"shape", id}, {"file", file},
              {"x", -(im.min[0] + im.max[0]) / 2}, {"y", -(im.min[1] + im.max[1]) / 2}, {"z", -im.min[2]}};
  std::string fid = doc.insert(f).id;
  fpcad::RebuildReport r = model_->rebuild();
  bool ok = true;
  for (auto& st : r.features)
    if (st.featureId == fid && !st.ok) ok = false;
  if (!ok) {
    undo();
    redo_.clear();
    return result(false, "the imported shape could not be added to the part");
  }
  Dictionary d = result(true, im.message);
  d["id"] = str(fid);
  d["volume"] = im.volume;
  d["solids"] = im.solids;
  return d;
}

Dictionary CadPart::set_units(const String& length, const String& mass) {
  std::string len = str(length), ms = str(mass);
  if (ms != "g" && ms != "kg" && ms != "lb") return result(false, "Unknown mass unit '" + ms + "'");
  fpcad::PartDocument backup = model_->document();
  bool wasOk = model_->lastReport().ok;
  std::vector<double> before = signature(*model_);
  checkpoint();
  if (!model_->document().changeUnits(len)) {
    drop_checkpoint();
    return result(false, "Unknown length unit '" + len + "'");
  }
  model_->document().massUnits = ms;
  fpcad::RebuildReport r = model_->rebuild();
  std::vector<double> after = signature(*model_);
  bool same = before.size() == after.size();
  for (size_t i = 0; same && i < before.size(); ++i)
    same = std::abs(before[i] - after[i]) <= 1e-7 * std::max(1.0, std::abs(before[i]));
  if ((wasOk && !r.ok) || !same) {
    model_->document() = backup;
    model_->rebuild();
    drop_checkpoint();
    return result(false, "The units were not changed: an expression would change size with them. Give its plain numbers a unit (\"5 mm\") and try again.");
  }
  return result(true, "");
}
double CadPart::get_density() const { return model_->document().density; }
Array CadPart::get_boards() const {
  Variant v = jsonToVariant(model_->document().boards);
  return v.get_type() == Variant::ARRAY ? Array(v) : Array();
}
void CadPart::set_boards(const Array& boards) { model_->document().boards = variantToJson(boards); }

Dictionary CadPart::rebuild() {
  fpcad::RebuildReport r = model_->rebuild();
  Dictionary d;
  d["ok"] = r.ok;
  d["ms"] = r.milliseconds;
  Array failures;
  for (auto& st : r.features) {
    if (st.ok) continue;
    Dictionary f;
    f["feature_id"] = str(st.featureId);
    const fpcad::Feature* feat = model_->document().find(st.featureId);
    f["name"] = str(feat ? feat->name : st.featureId);
    f["message"] = str(st.message);
    failures.push_back(f);
  }
  d["failures"] = failures;
  triFaces_.clear();
  faceFeatures_.clear();
  return d;
}

int CadPart::body_count() const { return model_->bodyCount(); }

Ref<ArrayMesh> CadPart::build_mesh(int body, double deflection) {
  Ref<ArrayMesh> mesh;
  mesh.instantiate();
  if (body < 0 || body >= model_->bodyCount()) return mesh;
  fpcad::BodyMesh m = model_->mesh(body, deflection);
  PackedVector3Array verts, normals;
  PackedInt32Array idx, faces;
  verts.resize(int64_t(m.positions.size() / 3));
  normals.resize(verts.size());
  for (int64_t i = 0; i < verts.size(); ++i) {
    const float* p = &m.positions[size_t(i) * 3];
    const float* n = &m.normals[size_t(i) * 3];
    verts.set(i, toGodot(p[0], p[1], p[2]));
    normals.set(i, toGodot(n[0], n[1], n[2]));
  }
  idx.resize(int64_t(m.indices.size()));
  for (size_t t = 0; t < m.indices.size(); t += 3) {
    // Godot treats clockwise triangles as front faces.
    idx.set(int64_t(t), int32_t(m.indices[t]));
    idx.set(int64_t(t + 1), int32_t(m.indices[t + 2]));
    idx.set(int64_t(t + 2), int32_t(m.indices[t + 1]));
  }
  faces.resize(int64_t(m.triangleFace.size()));
  for (size_t t = 0; t < m.triangleFace.size(); ++t) faces.set(int64_t(t), m.triangleFace[t]);
  if (triFaces_.size() < size_t(model_->bodyCount())) triFaces_.resize(size_t(model_->bodyCount()));
  triFaces_[size_t(body)] = faces;
  if (faceFeatures_.size() < size_t(model_->bodyCount())) faceFeatures_.resize(size_t(model_->bodyCount()));
  PackedStringArray ff;
  for (auto& fi : m.faces) ff.push_back(str(fi.featureId));
  faceFeatures_[size_t(body)] = ff;
  if (verts.is_empty()) return mesh;
  Array arrays;
  arrays.resize(Mesh::ARRAY_MAX);
  arrays[Mesh::ARRAY_VERTEX] = verts;
  arrays[Mesh::ARRAY_NORMAL] = normals;
  arrays[Mesh::ARRAY_INDEX] = idx;
  mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
  return mesh;
}

PackedInt32Array CadPart::triangle_faces(int body) const {
  if (body < 0 || size_t(body) >= triFaces_.size()) return {};
  return triFaces_[size_t(body)];
}

PackedStringArray CadPart::face_feature_ids(int body) const {
  if (body < 0 || size_t(body) >= faceFeatures_.size()) return {};
  return faceFeatures_[size_t(body)];
}

PackedVector3Array CadPart::build_edges(int body, double deflection) {
  PackedVector3Array out;
  if (body < 0 || body >= model_->bodyCount()) return out;
  fpcad::BodyMesh m = model_->mesh(body, deflection);
  out.resize(int64_t(m.edgeLines.size() / 3));
  for (int64_t i = 0; i < out.size(); ++i) {
    const float* p = &m.edgeLines[size_t(i) * 3];
    out.set(i, toGodot(p[0], p[1], p[2]));
  }
  return out;
}

PackedVector3Array CadPart::face_vertices(int body, int face) const {
  PackedVector3Array out;
  for (auto& v : model_->faceVertices(body, face)) out.push_back(toGodot(v));
  return out;
}

Dictionary CadPart::pick(const Vector3& origin, const Vector3& direction, double max_distance) {
  auto hit = model_->pick(toCad(origin), toCad(direction), max_distance);
  if (!hit) return Dictionary();
  Dictionary d = hitToDict(*hit);
  if (const fpcad::Feature* f = model_->document().find(hit->featureId)) {
    d["feature_name"] = str(f->name);
    d["feature_type"] = str(f->type);
  }
  if (auto drv = model_->faceDrive(*hit)) {
    d["drive_param"] = str(drv->param);
    d["drive_label"] = str(drv->label);
    d["drive_value"] = drv->value;
  }
  return d;
}

Dictionary CadPart::push_pull(const Dictionary& hit, double delta) {
  std::string msg;
  bool ok = model_->pushPull(dictToHit(hit), delta, &msg);
  Dictionary d = result(ok, msg);
  if (ok) {
    if (auto drv = model_->faceDrive(dictToHit(hit))) d["drive_value"] = drv->value;
  }
  return d;
}

void CadPart::checkpoint() {
  undo_.push_back(model_->document());
  if (undo_.size() > kUndoLimit) undo_.pop_front();
  redo_.clear();
}

void CadPart::drop_checkpoint() {
  if (!undo_.empty()) undo_.pop_back();
}

bool CadPart::undo() {
  if (undo_.empty()) return false;
  redo_.push_back(model_->document());
  fpcad::Json boards = model_->document().boards;  // the boards stay where they stand
  model_->document() = undo_.back();
  model_->document().boards = boards;
  undo_.pop_back();
  model_->rebuild();
  return true;
}

bool CadPart::redo() {
  if (redo_.empty()) return false;
  undo_.push_back(model_->document());
  fpcad::Json boards = model_->document().boards;
  model_->document() = redo_.back();
  model_->document().boards = boards;
  redo_.pop_back();
  model_->rebuild();
  return true;
}

Dictionary CadPart::commitOrRevert(const fpcad::PartDocument& backup, const std::string& what) {
  bool wasOk = model_->lastReport().ok;
  fpcad::RebuildReport r = model_->rebuild();
  if (wasOk && !r.ok) {
    std::string why;
    for (auto& st : r.features) if (!st.ok) { why = st.message; break; }
    model_->document() = backup;
    model_->rebuild();
    drop_checkpoint();
    return result(false, what + " would break the model: " + why);
  }
  return result(true, what);
}

String CadPart::add_primitive(const String& type, const Vector3& base, const Dictionary& dims, const String& op) {
  fpcad::Feature f;
  f.type = str(type);
  try {
    f.op = fpcad::bodyOpFromString(op.is_empty() ? "add" : str(op));
  } catch (...) {
    return "";
  }
  fpcad::Vec3 b = toCad(base);
  auto dim = [&](const char* k, double fallback) { return double(dims.get(k, fallback)); };
  if (f.type == "box") {
    f.params = {{"x", b[0]}, {"y", b[1]}, {"z", b[2]}, {"w", dim("w", 1)}, {"d", dim("d", 1)}, {"h", dim("h", 1)}};
  } else if (f.type == "cylinder") {
    f.params = {{"x", b[0]}, {"y", b[1]}, {"z", b[2]}, {"r", dim("r", 0.5)}, {"h", dim("h", 1)}};
  } else if (f.type == "sphere") {
    double r = dim("r", 0.5);
    f.params = {{"x", b[0]}, {"y", b[1]}, {"z", b[2] + r}, {"r", r}};
  } else if (f.type == "cone") {
    f.params = {{"x", b[0]}, {"y", b[1]}, {"z", b[2]}, {"r1", dim("r1", 0.5)}, {"r2", dim("r2", 0.0)}, {"h", dim("h", 1)}};
  } else {
    return "";
  }
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  std::string id = model_->document().insert(f).id;
  Dictionary r = commitOrRevert(backup, "placed");
  return bool(r["ok"]) ? str(id) : String();
}

Dictionary CadPart::move_feature(const String& id, const Vector3& delta) {
  fpcad::Feature* f = model_->document().find(str(id));
  if (!f) return result(false, "that feature no longer exists");
  fpcad::Vec3 d = toCad(delta);
  fpcad::PartDocument backup = model_->document();
  auto shift = [&](fpcad::Json& obj, const char* key, double by) {
    obj[key] = model_->param(*f, key) + by;
  };
  if (f->type == "box" || f->type == "cylinder" || f->type == "sphere" || f->type == "cone" || f->type == "import") {
    shift(f->params, "x", d[0]);
    shift(f->params, "y", d[1]);
    shift(f->params, "z", d[2]);
  } else if (f->type == "extrude") {
    auto& o = f->params["plane"]["origin"];
    o = {o[0].get<double>() + d[0], o[1].get<double>() + d[1], o[2].get<double>() + d[2]};
  } else {
    return result(false, f->name + " cannot be moved on its own");
  }
  fpcad::RebuildReport r = model_->rebuild();
  if (!r.ok) {
    model_->document() = backup;
    model_->rebuild();
    return result(false, "moving there would break the model");
  }
  return result(true, "moved");
}

Dictionary CadPart::delete_feature(const String& id) {
  std::string sid = str(id);
  auto& feats = model_->document().features;
  const fpcad::Feature* f = model_->document().find(sid);
  if (!f) return result(false, "that feature no longer exists");
  std::string name = f->name;
  checkpoint();
  // Features built from the deleted one go with it: edge features that target it, and extrudes,
  // revolves, sweeps and lofts that use a deleted sketch (repeated so chains are followed).
  std::set<std::string> gone{sid};
  auto uses = [&](const fpcad::Feature& x) {
    for (const char* k : {"target", "sketch", "path"})
      if (x.params.contains(k) && x.params[k].is_string() && gone.count(x.params[k].get<std::string>())) return true;
    if (x.params.contains("sketches") && x.params["sketches"].is_array())
      for (auto& e : x.params["sketches"])
        if (e.is_string() && gone.count(e.get<std::string>())) return true;
    return false;
  };
  for (bool grew = true; grew;) {
    grew = false;
    for (auto& x : feats)
      if (!gone.count(x.id) && uses(x)) { gone.insert(x.id); grew = true; }
  }
  size_t extra = gone.size() - 1;
  model_->document().erase(gone);
  model_->rebuild();
  return result(true, name + " deleted" + (extra ? " with " + std::to_string(extra) + " feature" + (extra > 1 ? "s" : "") + " built on it" : ""));
}

int CadPart::get_rollback() const { return model_->document().rollback; }

void CadPart::set_section(const Dictionary& plane) {
  if (plane.is_empty()) {
    model_->setSection(std::nullopt);
    return;
  }
  Vector3 o = plane.get("origin", Vector3());
  Vector3 n = plane.get("normal", Vector3(0, 0, -1));
  fpcad::Vec3 co = toCad(o), cn = toCad(n);
  model_->setSection(std::make_pair(co, cn));
}

bool CadPart::has_section() const { return model_->hasSection(); }

Dictionary CadPart::face_measure(const Dictionary& hit) const {
  fpcad::PickHit h = dictToHit(hit);
  auto m = model_->faceMeasure(h.body, h.face);
  Dictionary d;
  d["ok"] = m.ok;
  if (!m.ok) return d;
  d["area"] = m.area;
  d["kind"] = str(m.kind);
  d["radius"] = m.radius;
  d["radius2"] = m.radius2;
  d["normal"] = toGodot(m.normal);
  d["axis"] = toGodot(m.axis);
  d["centre"] = toGodot(m.centre);
  return d;
}

Array CadPart::interference() const {
  Array out;
  for (auto& x : model_->interference()) {
    Dictionary d;
    d["a"] = x.a;
    d["b"] = x.b;
    d["volume"] = x.volume;
    d["centre"] = toGodot(x.centre);
    out.push_back(d);
  }
  return out;
}

Dictionary CadPart::set_rollback(int index) {
  auto& doc = model_->document();
  int n = static_cast<int>(doc.features.size());
  int bar = index < 0 || index >= n ? -1 : index;
  if (bar == doc.rollback) return result(true, "");
  checkpoint();
  doc.rollback = bar;
  model_->rebuild();
  return result(true, bar < 0 ? "Rolled forward: every feature is built"
                              : "Rolled back to before " + doc.features[static_cast<size_t>(bar)].name + ": new features go here");
}

Dictionary CadPart::reorder_feature(const String& id, int index) {
  auto& doc = model_->document();
  std::string sid = str(id);
  int from = doc.indexOf(sid);
  if (from < 0) return result(false, "that feature no longer exists");
  if (index < 0 || index >= static_cast<int>(doc.features.size())) return result(false, "it cannot move further");
  if (index == from) return result(true, "");
  std::map<std::string, bool> before;
  for (auto& st : model_->lastReport().features) before[st.featureId] = st.ok;
  fpcad::PartDocument backup = doc;
  std::string name = doc.features[static_cast<size_t>(from)].name;
  doc.moveTo(sid, static_cast<size_t>(index));
  fpcad::RebuildReport r = model_->rebuild();
  for (auto& st : r.features) {
    if (st.ok || !before[st.featureId]) continue;
    const fpcad::Feature* broken = doc.find(st.featureId);
    std::string why = (broken ? broken->name : std::string("a feature")) + " would fail: " + st.message;
    doc = backup;
    model_->rebuild();
    return result(false, "Moving " + name + " there breaks the model. " + why);
  }
  undo_.push_back(backup);
  if (undo_.size() > kUndoLimit) undo_.pop_front();
  redo_.clear();
  return result(true, name + " moved");
}

Dictionary CadPart::set_suppressed(const String& id, bool suppressed) {
  fpcad::Feature* f = model_->document().find(str(id));
  if (!f) return result(false, "that feature no longer exists");
  if (f->suppressed == suppressed) return result(true, "");
  checkpoint();
  f->suppressed = suppressed;
  std::string name = f->name;
  fpcad::RebuildReport r = model_->rebuild();
  std::string later;
  for (auto& st : r.features)
    if (!st.ok) {
      const fpcad::Feature* g = model_->document().find(st.featureId);
      later = (g ? g->name : std::string("a feature")) + " fails: " + st.message;
      break;
    }
  Dictionary d = result(true, name + (suppressed ? " suppressed" : " back on") + (later.empty() ? "" : " · " + later));
  return d;
}

String CadPart::duplicate_feature(const String& id, const Vector3& offset) {
  const fpcad::Feature* f = model_->document().find(str(id));
  if (!f || f->type == "fillet" || f->type == "chamfer") return "";
  fpcad::Feature copy = *f;
  copy.id.clear();
  copy.name.clear();
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  std::string nid = model_->document().insert(copy).id;
  model_->rebuild();
  Dictionary moved = move_feature(str(nid), offset);
  if (!bool(moved["ok"])) {
    model_->document() = backup;
    model_->rebuild();
    drop_checkpoint();
    return "";
  }
  return str(nid);
}

Dictionary CadPart::feature_dims(const String& id) const {
  Dictionary d;
  const fpcad::Feature* f = model_->document().find(str(id));
  if (!f) return d;
  for (const char* k : {"w", "d", "h", "r", "r1", "r2", "depth"})
    if (f->params.contains(k)) d[k] = model_->param(*f, k);
  if (f->type == "extrude" && f->params.contains("profile")) {
    const auto& p = f->params["profile"];
    if (p.value("kind", std::string()) == "rect") {
      fpcad::Feature tmp;
      tmp.params = p;
      d["w"] = model_->param(tmp, "w");
      d["d"] = model_->param(tmp, "h");
      d["h"] = model_->param(*f, "depth");
    }
  }
  return d;
}

Dictionary CadPart::set_param(const String& id, const String& key, const Variant& value) {
  fpcad::Feature* f = model_->document().find(str(id));
  if (!f) return result(false, "that feature no longer exists");
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  std::string k = str(key);
  fpcad::Json* target = &f->params;
  auto dot = k.find('.');
  if (dot != std::string::npos) {
    target = &f->params[k.substr(0, dot)];
    k = k.substr(dot + 1);
  }
  if (value.get_type() == Variant::STRING) {
    std::string expr = str(String(value));
    try {
      fpcad::evaluate(expr, model_->variables(), fpcad::Quantity::Length, fpcad::unitScale(model_->document().units));
    } catch (const std::exception& e) {
      drop_checkpoint();
      return result(false, e.what());
    }
    (*target)[k] = expr;
  } else {
    (*target)[k] = double(value);
  }
  return commitOrRevert(backup, f->name + " updated");
}

Dictionary CadPart::set_variable(const String& name, const String& expr) {
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  bool found = false;
  for (auto& v : model_->document().variables)
    if (v.name == str(name)) { v.expr = str(expr); found = true; }
  if (!found) model_->document().variables.push_back({str(name), str(expr)});
  return commitOrRevert(backup, str(name) + " = " + str(expr));
}

Array CadPart::get_features() const {
  Array out;
  const auto& rep = model_->lastReport();
  for (auto& f : model_->document().features) {
    Dictionary d;
    d["id"] = str(f.id);
    d["name"] = str(f.name);
    d["type"] = str(f.type);
    d["op"] = str(fpcad::toString(f.op));
    d["suppressed"] = f.suppressed;
    d["params"] = jsonToVariant(f.params);
    d["ok"] = true;
    d["message"] = String();
    d["rolled_back"] = false;
    for (auto& st : rep.features)
      if (st.featureId == f.id) {
        d["ok"] = st.ok;
        d["message"] = str(st.message);
        d["rolled_back"] = st.rolledBack;
      }
    out.push_back(d);
  }
  return out;
}

Array CadPart::get_variables() const {
  Array out;
  for (auto& v : model_->document().variables) {
    Dictionary d;
    d["name"] = str(v.name);
    d["expr"] = str(v.expr);
    auto it = model_->variables().find(v.name);
    d["value"] = it == model_->variables().end() ? Variant() : Variant(it->second);
    out.push_back(d);
  }
  return out;
}

Dictionary CadPart::mass_properties() const {
  fpcad::MassProperties m = model_->massProperties();
  Dictionary d;
  d["volume"] = m.volume;
  d["area"] = m.area;
  d["mass"] = m.mass;
  d["bodies"] = m.bodies;
  d["centre_of_mass"] = toGodot(m.centreOfMass);
  return d;
}

Dictionary CadPart::export_file(const String& path, const String& units) {
  fpcad::ExportOptions o;
  if (!units.is_empty()) o.units = str(units);
  fpcad::ExportResult r = fpcad::exportPart(*model_, str(path), o);
  Dictionary d = result(r.ok, r.message);
  d["bodies"] = r.bodies;
  d["triangles"] = int64_t(r.triangles);
  d["validated"] = r.validated;
  return d;
}

// ----- Sketches -----

namespace {
fpcad::SketchPlane planeOf(const Dictionary& plane) { return fpcad::SketchPlane::fromJson(variantToJson(plane)); }

Dictionary namedPlane(const fpcad::SketchPlane& p, const std::string& name) {
  Dictionary d;
  d["plane"] = jsonToVariant(p.toJson());
  d["name"] = str(name);
  return d;
}

PackedVector3Array points(const std::vector<fpcad::Vec3>& pts) {
  PackedVector3Array out;
  out.resize(int64_t(pts.size()));
  for (size_t i = 0; i < pts.size(); ++i) out.set(int64_t(i), toGodot(pts[i]));
  return out;
}
}  // namespace

Dictionary CadPart::standard_plane(const String& name) const {
  std::string n = str(name).empty() ? "top" : str(name.to_lower());
  std::string label = n == "front" ? "Front" : n == "right" ? "Right" : "Top";
  return namedPlane(fpcad::standardPlane(n), label);
}

Dictionary CadPart::plane_from_hit(const Dictionary& hit) const {
  std::string name;
  auto p = model_->planeFromHit(dictToHit(hit), &name);
  return p ? namedPlane(*p, name) : Dictionary();
}

Dictionary CadPart::plane_basis(const Dictionary& plane) const {
  fpcad::SketchPlane p;
  try {
    p = planeOf(plane);
  } catch (const std::exception&) {
    return Dictionary();
  }
  Dictionary d;
  d["origin"] = toGodot(p.origin);
  d["normal"] = toGodot(p.normal);
  d["xdir"] = toGodot(p.xdir);
  d["ydir"] = toGodot(p.ydir());
  return d;
}

Vector3 CadPart::plane_point(const Dictionary& plane, const Vector2& uv) const {
  return toGodot(planeOf(plane).toWorld(uv.x, uv.y));
}

Vector2 CadPart::plane_uv(const Dictionary& plane, const Vector3& world) const {
  auto uv = planeOf(plane).toPlane(toCad(world));
  return Vector2(float(uv[0]), float(uv[1]));
}

Dictionary CadPart::solve_sketch(const Dictionary& sketch) const {
  Dictionary d;
  try {
    fpcad::Sketch s = fpcad::Sketch::fromJson(variantToJson(sketch));
    fpcad::SolveResult r = model_->solve(s);
    d["ok"] = r.ok;
    d["dof"] = r.dof;
    d["message"] = str(r.message);
    PackedStringArray conflicts;
    for (auto& c : r.conflicts) conflicts.push_back(str(c));
    d["conflicts"] = conflicts;
    PackedStringArray freePts, freeEnts;
    for (auto& id : r.freePoints) freePts.push_back(str(id));
    for (auto& id : r.freeEntities) freeEnts.push_back(str(id));
    d["free_points"] = freePts;
    d["free_entities"] = freeEnts;
    d["sketch"] = jsonToVariant(s.toJson());
  } catch (const std::exception& e) {
    d["ok"] = false;
    d["dof"] = 0;
    d["message"] = str(e.what());
    d["conflicts"] = PackedStringArray();
    d["sketch"] = sketch;
  }
  return d;
}

PackedVector2Array CadPart::sketch_fill(const Dictionary& sketch) const {
  PackedVector2Array out;
  try {
    fpcad::Sketch s = fpcad::Sketch::fromJson(variantToJson(sketch));
    for (auto& q : fpcad::sketchFill(s)) out.push_back(Vector2(float(q[0]), float(q[1])));
  } catch (const std::exception&) {
  }
  return out;
}

Array CadPart::sketch_curves(const Dictionary& sketch) const {
  Array out;
  try {
    fpcad::Sketch s = fpcad::Sketch::fromJson(variantToJson(sketch));
    for (auto& c : fpcad::sketchCurves(s)) {
      PackedVector2Array pts;
      for (auto& q : c.points) pts.push_back(Vector2(float(q[0]), float(q[1])));
      Dictionary d;
      d["id"] = str(c.entityId);
      d["construction"] = c.construction;
      d["points"] = pts;
      out.push_back(d);
    }
  } catch (const std::exception&) {
  }
  return out;
}

Array CadPart::project_face(int body, int face, const Dictionary& plane) const {
  Array out;
  try {
    fpcad::SketchPlane pl = fpcad::SketchPlane::fromJson(variantToJson(plane));
    for (auto& c : model_->projectFace(body, face, pl)) {
      PackedVector2Array pts;
      for (auto& q : c.pts) pts.push_back(Vector2(float(q[0]), float(q[1])));
      Dictionary d;
      d["kind"] = str(c.kind);
      d["pts"] = pts;
      d["r"] = c.r;
      d["closed"] = c.closed;
      out.push_back(d);
    }
  } catch (const std::exception&) {
  }
  return out;
}

Array CadPart::reference_views() const {
  Array out;
  for (auto& v : model_->referenceViews()) {
    Dictionary d;
    d["id"] = str(v.featureId);
    d["name"] = str(v.name);
    d["kind"] = str(v.kind);
    d["ok"] = v.ok;
    d["message"] = str(v.message);
    d["origin"] = toGodot(v.origin);
    d["xdir"] = toGodot(v.xdir);
    d["ydir"] = toGodot(v.ydir);
    d["normal"] = toGodot(v.normal);
    d["size"] = v.size;
    out.push_back(d);
  }
  return out;
}

Dictionary CadPart::reference_plane(const String& id) const {
  Dictionary d;
  auto p = model_->referencePlane(str(id));
  if (!p) return d;
  d["plane"] = jsonToVariant(p->toJson());
  const fpcad::Feature* f = model_->document().find(str(id));
  d["name"] = f ? str(f->name) : id;
  return d;
}

PackedVector3Array CadPart::straight_edge_near(const Dictionary& hit, double tolerance) const {
  PackedVector3Array out;
  if (auto e = model_->straightEdgeNear(dictToHit(hit), tolerance)) {
    out.push_back(toGodot((*e)[0]));
    out.push_back(toGodot((*e)[1]));
  }
  return out;
}

bool CadPart::is_cylinder(const Dictionary& hit) const { return model_->isCylinder(dictToHit(hit)); }

Dictionary CadPart::bounding_box() const {
  Dictionary d;
  auto b = model_->boundingBox();
  d["ok"] = b.has_value();
  if (!b) return d;
  Vector3 a = toGodot(b->min), c = toGodot(b->max);
  d["min"] = Vector3(std::min(a.x, c.x), std::min(a.y, c.y), std::min(a.z, c.z));
  d["max"] = Vector3(std::max(a.x, c.x), std::max(a.y, c.y), std::max(a.z, c.z));
  d["size"] = Vector3(float(b->max[0] - b->min[0]), float(b->max[1] - b->min[1]), float(b->max[2] - b->min[2]));
  return d;
}

Dictionary CadPart::face_ref(const Dictionary& hit) const {
  fpcad::PickHit h = dictToHit(hit);
  Dictionary d;
  d["probe"] = cad_point(toGodot(h.point));
  Array n;
  n.push_back(h.normal[0]);
  n.push_back(h.normal[1]);
  n.push_back(h.normal[2]);
  d["normal"] = n;
  d["feature"] = str(h.featureId);
  std::string role = model_->faceRole(h.body, h.face);
  if (!role.empty()) d["role"] = str(role);
  return d;
}

// The edge nearest a point (Godot space), for fillet / chamfer picking: its middle in CAD
// coordinates (what a pick stores), points along it (Godot space) for drawing, length, radius.
Dictionary CadPart::edge_near(const Vector3& point, double tolerance) const {
  Dictionary d;
  auto e = model_->edgeNear(toCad(point), tolerance);
  d["ok"] = e.has_value();
  if (!e) return d;
  Array mid;
  for (double v : e->mid) mid.push_back(v);
  d["probe"] = mid;
  PackedVector3Array pts;
  for (auto& q : e->points) pts.push_back(toGodot(q));
  d["points"] = pts;
  d["length"] = e->length;
  d["radius"] = e->radius;
  d["body"] = e->body;
  return d;
}

Array CadPart::cad_point(const Vector3& p) const {
  fpcad::Vec3 c = toCad(p);
  Array a;
  a.push_back(c[0]);
  a.push_back(c[1]);
  a.push_back(c[2]);
  return a;
}

Dictionary CadPart::convert_face(const Dictionary& sketch, int body, int face, const Vector3& probe) {
  Dictionary d;
  d["sketch"] = sketch;
  try {
    fpcad::Sketch s = fpcad::Sketch::fromJson(variantToJson(sketch));
    std::string message;
    bool ok = model_->convertFace(s, body, face, toCad(probe), &message);
    d["ok"] = ok;
    d["message"] = str(message);
    if (ok) d["sketch"] = jsonToVariant(s.toJson());
  } catch (const std::exception& e) {
    d["ok"] = false;
    d["message"] = str(e.what());
  }
  return d;
}

String CadPart::add_sketch(const Dictionary& sketch) {
  fpcad::Feature f;
  f.type = "sketch";
  f.params = variantToJson(sketch);
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  std::string id = model_->document().insert(f).id;
  Dictionary r = commitOrRevert(backup, "sketch added");
  return bool(r["ok"]) ? str(id) : String();
}

Dictionary CadPart::set_sketch(const String& id, const Dictionary& sketch) {
  fpcad::Feature* f = model_->document().find(str(id));
  if (!f || f->type != "sketch") return result(false, "that sketch no longer exists");
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  std::string name = f->name;
  f->params = variantToJson(sketch);
  return commitOrRevert(backup, name + " updated");
}

Dictionary CadPart::get_sketch(const String& id) const {
  const fpcad::Feature* f = model_->document().find(str(id));
  if (!f || f->type != "sketch") return Dictionary();
  return jsonToVariant(f->params);
}

Array CadPart::sketch_views() const {
  Array out;
  for (auto& v : model_->sketchViews()) {
    Dictionary d;
    d["id"] = str(v.featureId);
    d["name"] = str(v.name);
    d["plane_name"] = str(v.planeName);
    d["consumed"] = v.consumed;
    d["ok"] = v.ok;
    d["dof"] = v.dof;
    d["regions"] = v.regions;
    d["message"] = str(v.message);
    d["segments"] = points(v.segments);
    d["construction"] = points(v.constructionSegments);
    d["fill"] = points(v.fill);
    out.push_back(d);
  }
  return out;
}

Dictionary CadPart::pick_sketch(const Vector3& origin, const Vector3& direction, double max_distance,
                                double tolerance, bool include_consumed) const {
  auto h = model_->pickSketch(toCad(origin), toCad(direction), max_distance, tolerance, include_consumed);
  if (!h) return Dictionary();
  Dictionary d;
  d["feature_id"] = str(h->featureId);
  d["region"] = h->region;
  d["point"] = toGodot(h->point);
  d["distance"] = h->distance;
  if (const fpcad::Feature* f = model_->document().find(h->featureId)) d["name"] = str(f->name);
  return d;
}

String CadPart::latest_unused_sketch() const { return str(model_->latestUnusedSketch()); }

// ----- Dialog features with live preview -----

namespace {
Dictionary featureResult(fpcad::PartModel& m, const std::string& id) {
  fpcad::RebuildReport r = m.rebuild();
  Dictionary d = result(true, "");
  d["id"] = str(id);
  for (auto& st : r.features)
    if (!st.ok && st.featureId == id) {
      d["ok"] = false;
      d["message"] = str(st.message);
    }
  if (bool(d["ok"]) && !r.ok) {
    for (auto& st : r.features)
      if (!st.ok) {
        d["ok"] = false;
        d["message"] = str("a later feature fails: " + st.message);
        break;
      }
  }
  return d;
}
}  // namespace

Dictionary CadPart::insert_feature(const String& type, const String& op, const Dictionary& params) {
  fpcad::Feature f;
  f.type = str(type);
  try {
    f.op = fpcad::bodyOpFromString(op.is_empty() ? "add" : str(op));
  } catch (const std::exception& e) {
    return result(false, e.what());
  }
  f.params = variantToJson(params);
  std::string id = model_->document().insert(f).id;
  Dictionary d = featureResult(*model_, id);
  if (const fpcad::Feature* added = model_->document().find(id)) d["name"] = str(added->name);
  return d;
}

Dictionary CadPart::update_feature(const String& id, const String& op, const Dictionary& params) {
  fpcad::Feature* f = model_->document().find(str(id));
  if (!f) return result(false, "that feature no longer exists");
  if (!op.is_empty()) {
    try {
      f->op = fpcad::bodyOpFromString(str(op));
    } catch (const std::exception& e) {
      return result(false, e.what());
    }
  }
  fpcad::Json p = variantToJson(params);
  for (auto it = p.begin(); it != p.end(); ++it) {
    if (it.value().is_null()) f->params.erase(it.key());
    else f->params[it.key()] = it.value();
  }
  return featureResult(*model_, str(id));
}

void CadPart::abandon() {
  if (undo_.empty()) return;
  model_->document() = undo_.back();
  undo_.pop_back();
  model_->rebuild();
}

// ----- Challenge mode -----

Array CadPart::challenge_list() const {
  Array out;
  for (auto& c : fpcad::challenges()) {
    Dictionary d;
    d["id"] = str(c.id);
    d["name"] = str(c.name);
    d["brief"] = str(c.brief);
    d["hint"] = str(c.hint);
    out.push_back(d);
  }
  return out;
}

Dictionary CadPart::make_challenge(int index) {
  auto list = fpcad::challenges();
  if (index < 0 || index >= int(list.size())) return Dictionary();
  fpcad::Challenge& c = list[size_t(index)];
  model_ = std::make_unique<fpcad::PartModel>(c.target);
  undo_.clear();
  redo_.clear();
  Dictionary d;
  d["index"] = index;
  d["count"] = int(list.size());
  d["id"] = str(c.id);
  d["name"] = str(c.name);
  d["brief"] = str(c.brief);
  d["hint"] = str(c.hint);
  Array callouts;
  for (auto& k : c.callouts) {
    Dictionary e;
    e["a"] = toGodot(k.a);
    e["b"] = toGodot(k.b);
    e["text"] = str(k.text);
    callouts.push_back(e);
  }
  d["callouts"] = callouts;
  return d;
}

Dictionary CadPart::compare_to(Object* target) const {
  Dictionary d;
  const CadPart* t = Object::cast_to<CadPart>(target);
  if (t == nullptr) {
    d["match"] = false;
    d["message"] = "no target part";
    return d;
  }
  fpcad::ShapeMatch m = fpcad::compareParts(*model_, t->model());
  d["match"] = m.match;
  d["mirrored"] = m.mirrored;
  d["empty"] = m.empty;
  d["volume_ratio"] = m.volumeRatio;
  d["area_ratio"] = m.areaRatio;
  d["overlap"] = m.overlap;
  d["message"] = str(m.message);
  return d;
}

void CadPart::_bind_methods() {
  ClassDB::bind_method(D_METHOD("make_sample"), &CadPart::make_sample);
  ClassDB::bind_method(D_METHOD("make_training"), &CadPart::make_training);
  ClassDB::bind_method(D_METHOD("make_desk_sample"), &CadPart::make_desk_sample);
  ClassDB::bind_method(D_METHOD("new_blank", "name", "units"), &CadPart::new_blank);
  ClassDB::bind_method(D_METHOD("load_file", "path"), &CadPart::load_file);
  ClassDB::bind_method(D_METHOD("save_file", "path"), &CadPart::save_file);
  ClassDB::bind_method(D_METHOD("get_part_name"), &CadPart::get_part_name);
  ClassDB::bind_method(D_METHOD("get_units"), &CadPart::get_units);
  ClassDB::bind_method(D_METHOD("get_file_id"), &CadPart::get_file_id);
  ClassDB::bind_method(D_METHOD("get_material"), &CadPart::get_material);
  ClassDB::bind_method(D_METHOD("get_density"), &CadPart::get_density);
  ClassDB::bind_method(D_METHOD("get_mass_units"), &CadPart::get_mass_units);
  ClassDB::bind_method(D_METHOD("import_step", "path"), &CadPart::import_step);
  ClassDB::bind_method(D_METHOD("edge_near", "point", "tolerance"), &CadPart::edge_near);
  ClassDB::bind_method(D_METHOD("set_part_name", "name"), &CadPart::set_part_name);
  ClassDB::bind_method(D_METHOD("native_library_dir"), &CadPart::native_library_dir);
  ClassDB::bind_method(D_METHOD("material_library"), &CadPart::material_library);
  ClassDB::bind_method(D_METHOD("material_info"), &CadPart::material_info);
  ClassDB::bind_method(D_METHOD("set_material", "name", "density"), &CadPart::set_material, DEFVAL(0.0));
  ClassDB::bind_method(D_METHOD("set_units", "length", "mass"), &CadPart::set_units);
  ClassDB::bind_method(D_METHOD("get_boards"), &CadPart::get_boards);
  ClassDB::bind_method(D_METHOD("set_boards", "boards"), &CadPart::set_boards);
  ClassDB::bind_method(D_METHOD("rebuild"), &CadPart::rebuild);
  ClassDB::bind_method(D_METHOD("body_count"), &CadPart::body_count);
  ClassDB::bind_method(D_METHOD("build_mesh", "body", "deflection"), &CadPart::build_mesh);
  ClassDB::bind_method(D_METHOD("triangle_faces", "body"), &CadPart::triangle_faces);
  ClassDB::bind_method(D_METHOD("face_feature_ids", "body"), &CadPart::face_feature_ids);
  ClassDB::bind_method(D_METHOD("build_edges", "body", "deflection"), &CadPart::build_edges);
  ClassDB::bind_method(D_METHOD("face_vertices", "body", "face"), &CadPart::face_vertices);
  ClassDB::bind_method(D_METHOD("pick", "origin", "direction", "max_distance"), &CadPart::pick);
  ClassDB::bind_method(D_METHOD("push_pull", "hit", "delta"), &CadPart::push_pull);
  ClassDB::bind_method(D_METHOD("add_primitive", "type", "base", "dims", "op"), &CadPart::add_primitive);
  ClassDB::bind_method(D_METHOD("move_feature", "id", "delta"), &CadPart::move_feature);
  ClassDB::bind_method(D_METHOD("delete_feature", "id"), &CadPart::delete_feature);
  ClassDB::bind_method(D_METHOD("get_rollback"), &CadPart::get_rollback);
  ClassDB::bind_method(D_METHOD("set_section", "plane"), &CadPart::set_section);
  ClassDB::bind_method(D_METHOD("has_section"), &CadPart::has_section);
  ClassDB::bind_method(D_METHOD("face_measure", "hit"), &CadPart::face_measure);
  ClassDB::bind_method(D_METHOD("interference"), &CadPart::interference);
  ClassDB::bind_method(D_METHOD("set_rollback", "index"), &CadPart::set_rollback);
  ClassDB::bind_method(D_METHOD("reorder_feature", "id", "index"), &CadPart::reorder_feature);
  ClassDB::bind_method(D_METHOD("set_suppressed", "id", "suppressed"), &CadPart::set_suppressed);
  ClassDB::bind_method(D_METHOD("duplicate_feature", "id", "offset"), &CadPart::duplicate_feature);
  ClassDB::bind_method(D_METHOD("feature_dims", "id"), &CadPart::feature_dims);
  ClassDB::bind_method(D_METHOD("set_param", "id", "key", "value"), &CadPart::set_param);
  ClassDB::bind_method(D_METHOD("set_variable", "name", "expr"), &CadPart::set_variable);
  ClassDB::bind_method(D_METHOD("get_features"), &CadPart::get_features);
  ClassDB::bind_method(D_METHOD("get_variables"), &CadPart::get_variables);
  ClassDB::bind_method(D_METHOD("mass_properties"), &CadPart::mass_properties);
  ClassDB::bind_method(D_METHOD("export_file", "path", "units"), &CadPart::export_file);
  ClassDB::bind_method(D_METHOD("standard_plane", "name"), &CadPart::standard_plane);
  ClassDB::bind_method(D_METHOD("plane_from_hit", "hit"), &CadPart::plane_from_hit);
  ClassDB::bind_method(D_METHOD("plane_basis", "plane"), &CadPart::plane_basis);
  ClassDB::bind_method(D_METHOD("plane_point", "plane", "uv"), &CadPart::plane_point);
  ClassDB::bind_method(D_METHOD("plane_uv", "plane", "world"), &CadPart::plane_uv);
  ClassDB::bind_method(D_METHOD("solve_sketch", "sketch"), &CadPart::solve_sketch);
  ClassDB::bind_method(D_METHOD("sketch_fill", "sketch"), &CadPart::sketch_fill);
  ClassDB::bind_method(D_METHOD("sketch_curves", "sketch"), &CadPart::sketch_curves);
  ClassDB::bind_method(D_METHOD("project_face", "body", "face", "plane"), &CadPart::project_face);
  ClassDB::bind_method(D_METHOD("convert_face", "sketch", "body", "face", "probe"), &CadPart::convert_face);
  ClassDB::bind_method(D_METHOD("reference_views"), &CadPart::reference_views);
  ClassDB::bind_method(D_METHOD("reference_plane", "id"), &CadPart::reference_plane);
  ClassDB::bind_method(D_METHOD("straight_edge_near", "hit", "tolerance"), &CadPart::straight_edge_near);
  ClassDB::bind_method(D_METHOD("is_cylinder", "hit"), &CadPart::is_cylinder);
  ClassDB::bind_method(D_METHOD("bounding_box"), &CadPart::bounding_box);
  ClassDB::bind_method(D_METHOD("face_ref", "hit"), &CadPart::face_ref);
  ClassDB::bind_method(D_METHOD("cad_point", "p"), &CadPart::cad_point);
  ClassDB::bind_method(D_METHOD("add_sketch", "sketch"), &CadPart::add_sketch);
  ClassDB::bind_method(D_METHOD("set_sketch", "id", "sketch"), &CadPart::set_sketch);
  ClassDB::bind_method(D_METHOD("get_sketch", "id"), &CadPart::get_sketch);
  ClassDB::bind_method(D_METHOD("sketch_views"), &CadPart::sketch_views);
  ClassDB::bind_method(D_METHOD("pick_sketch", "origin", "direction", "max_distance", "tolerance", "include_consumed"),
                       &CadPart::pick_sketch);
  ClassDB::bind_method(D_METHOD("latest_unused_sketch"), &CadPart::latest_unused_sketch);
  ClassDB::bind_method(D_METHOD("insert_feature", "type", "op", "params"), &CadPart::insert_feature);
  ClassDB::bind_method(D_METHOD("update_feature", "id", "op", "params"), &CadPart::update_feature);
  ClassDB::bind_method(D_METHOD("abandon"), &CadPart::abandon);
  ClassDB::bind_method(D_METHOD("challenge_list"), &CadPart::challenge_list);
  ClassDB::bind_method(D_METHOD("make_challenge", "index"), &CadPart::make_challenge);
  ClassDB::bind_method(D_METHOD("compare_to", "target"), &CadPart::compare_to);
  ClassDB::bind_method(D_METHOD("undo"), &CadPart::undo);
  ClassDB::bind_method(D_METHOD("redo"), &CadPart::redo);
  ClassDB::bind_method(D_METHOD("can_undo"), &CadPart::can_undo);
  ClassDB::bind_method(D_METHOD("can_redo"), &CadPart::can_redo);
  ClassDB::bind_method(D_METHOD("checkpoint"), &CadPart::checkpoint);
  ClassDB::bind_method(D_METHOD("drop_checkpoint"), &CadPart::drop_checkpoint);
}

}  // namespace fpcad_gd
