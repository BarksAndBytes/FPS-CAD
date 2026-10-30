#include "cad_part.h"

#include <algorithm>
#include <set>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include "convert.h"
#include "fpcad/Challenges.h"
#include "fpcad/Compare.h"
#include "fpcad/Expression.h"
#include "fpcad/Export.h"
#include "fpcad/FileIO.h"

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
String CadPart::get_units() const { return str(model_->document().units); }
String CadPart::get_file_id() const { return str(model_->document().fileId); }

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
  model_->document() = undo_.back();
  undo_.pop_back();
  model_->rebuild();
  return true;
}

bool CadPart::redo() {
  if (redo_.empty()) return false;
  undo_.push_back(model_->document());
  model_->document() = redo_.back();
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
  std::string id = model_->document().add(f).id;
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
  if (f->type == "box" || f->type == "cylinder" || f->type == "sphere" || f->type == "cone") {
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
  feats.erase(std::remove_if(feats.begin(), feats.end(), [&](const fpcad::Feature& x) { return gone.count(x.id) > 0; }),
              feats.end());
  model_->rebuild();
  return result(true, name + " deleted" + (extra ? " with " + std::to_string(extra) + " feature" + (extra > 1 ? "s" : "") + " built on it" : ""));
}

String CadPart::duplicate_feature(const String& id, const Vector3& offset) {
  const fpcad::Feature* f = model_->document().find(str(id));
  if (!f || f->type == "fillet" || f->type == "chamfer") return "";
  fpcad::Feature copy = *f;
  copy.id.clear();
  copy.name.clear();
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  std::string nid = model_->document().add(copy).id;
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
    for (auto& st : rep.features)
      if (st.featureId == f.id) { d["ok"] = st.ok; d["message"] = str(st.message); }
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
  fpcad::SketchPlane p = planeOf(plane);
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

String CadPart::add_sketch(const Dictionary& sketch) {
  fpcad::Feature f;
  f.type = "sketch";
  f.params = variantToJson(sketch);
  checkpoint();
  fpcad::PartDocument backup = model_->document();
  std::string id = model_->document().add(f).id;
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
  std::string id = model_->document().add(f).id;
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
