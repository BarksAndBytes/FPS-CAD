#include "convert.h"

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/quaternion.hpp>

using namespace godot;

namespace fpcad_gd {

Variant jsonToVariant(const fpcad::Json& j) {
  switch (j.type()) {
    case fpcad::Json::value_t::null: return Variant();
    case fpcad::Json::value_t::boolean: return j.get<bool>();
    case fpcad::Json::value_t::number_integer:
    case fpcad::Json::value_t::number_unsigned: return static_cast<int64_t>(j.get<int64_t>());
    case fpcad::Json::value_t::number_float: return j.get<double>();
    case fpcad::Json::value_t::string: return str(j.get<std::string>());
    case fpcad::Json::value_t::array: {
      Array a;
      for (auto& e : j) a.push_back(jsonToVariant(e));
      return a;
    }
    case fpcad::Json::value_t::object: {
      Dictionary d;
      for (auto it = j.begin(); it != j.end(); ++it) d[str(it.key())] = jsonToVariant(it.value());
      return d;
    }
    default: return Variant();
  }
}

fpcad::Json variantToJson(const Variant& v) {
  switch (v.get_type()) {
    case Variant::NIL: return nullptr;
    case Variant::BOOL: return bool(v);
    case Variant::INT: return int64_t(v);
    case Variant::FLOAT: return double(v);
    case Variant::STRING:
    case Variant::STRING_NAME: return str(String(v));
    case Variant::ARRAY: {
      fpcad::Json a = fpcad::Json::array();
      Array arr = v;
      for (int64_t i = 0; i < arr.size(); ++i) a.push_back(variantToJson(arr[i]));
      return a;
    }
    case Variant::PACKED_STRING_ARRAY: {
      fpcad::Json a = fpcad::Json::array();
      PackedStringArray arr = v;
      for (int64_t i = 0; i < arr.size(); ++i) a.push_back(str(arr[i]));
      return a;
    }
    case Variant::PACKED_FLOAT32_ARRAY:
    case Variant::PACKED_FLOAT64_ARRAY: {
      fpcad::Json a = fpcad::Json::array();
      PackedFloat64Array arr = v;
      for (int64_t i = 0; i < arr.size(); ++i) a.push_back(arr[i]);
      return a;
    }
    case Variant::DICTIONARY: {
      fpcad::Json o = fpcad::Json::object();
      Dictionary d = v;
      Array keys = d.keys();
      for (int64_t i = 0; i < keys.size(); ++i) o[str(String(keys[i]))] = variantToJson(d[keys[i]]);
      return o;
    }
    default: return str(String(v));
  }
}

// Godot basis = C * R * C^T, with C mapping CAD axes to Godot axes.
Transform3D toGodot(const fpcad::Placement& p) {
  Quaternion q(float(p.q[0]), float(p.q[1]), float(p.q[2]), float(p.q[3]));
  Basis r(q.normalized());
  const Basis c(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0));  // columns: cad x,y,z in godot
  return Transform3D(c * r * c.transposed(), toGodot(p.t));
}

fpcad::Placement toCad(const Transform3D& t) {
  const Basis c(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0));
  Basis r = c.transposed() * t.basis * c;
  Quaternion q = r.orthonormalized().get_quaternion();
  fpcad::Placement p;
  p.q = {q.x, q.y, q.z, q.w};
  p.t = toCad(t.origin);
  return p;
}

Dictionary hitToDict(const fpcad::PickHit& h) {
  Dictionary d;
  d["hit"] = true;
  d["body"] = h.body;
  d["face"] = h.face;
  d["feature_id"] = str(h.featureId);
  d["point"] = toGodot(h.point);
  d["normal"] = toGodot(h.normal);
  d["distance"] = h.distance;
  return d;
}

fpcad::PickHit dictToHit(const Dictionary& d) {
  fpcad::PickHit h;
  h.body = int(d.get("body", -1));
  h.face = int(d.get("face", -1));
  h.featureId = str(String(d.get("feature_id", "")));
  h.point = toCad(Vector3(d.get("point", Vector3())));
  h.normal = toCad(Vector3(d.get("normal", Vector3())));
  h.distance = double(d.get("distance", 0.0));
  return h;
}

}  // namespace fpcad_gd
