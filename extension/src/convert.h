#pragma once
// Conversions between the CAD core (Z up, std types, JSON) and Godot (Y up, Variant).
//
// Godot axes = (x, z, -y) of CAD axes. Both are right-handed, so no mirroring happens.

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "fpcad/Assembly.h"
#include "fpcad/Document.h"
#include "fpcad/Model.h"

namespace fpcad_gd {

inline godot::Vector3 toGodot(const fpcad::Vec3& v) {
  return godot::Vector3(float(v[0]), float(v[2]), float(-v[1]));
}
inline godot::Vector3 toGodot(double x, double y, double z) {
  return godot::Vector3(float(x), float(z), float(-y));
}
inline fpcad::Vec3 toCad(const godot::Vector3& v) { return {v.x, -double(v.z), v.y}; }

inline godot::String str(const std::string& s) { return godot::String::utf8(s.c_str()); }
inline godot::String str(const char* s) { return godot::String::utf8(s); }
inline std::string str(const godot::String& s) { return std::string(s.utf8().get_data()); }

godot::Variant jsonToVariant(const fpcad::Json& j);
fpcad::Json variantToJson(const godot::Variant& v);

godot::Transform3D toGodot(const fpcad::Placement& p);
fpcad::Placement toCad(const godot::Transform3D& t);

godot::Dictionary hitToDict(const fpcad::PickHit& h);
fpcad::PickHit dictToHit(const godot::Dictionary& d);

}  // namespace fpcad_gd
