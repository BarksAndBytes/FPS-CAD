#pragma once
// CadAssembly: an assembly as Godot sees it — distinct parts with display meshes, and placed
// components with Godot-space transforms.

#include <memory>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "fpcad/Assembly.h"

namespace fpcad_gd {

class CadAssembly : public godot::RefCounted {
  GDCLASS(CadAssembly, godot::RefCounted)

public:
  CadAssembly();

  void make_sample();
  godot::String load_file(const godot::String& path);
  godot::String save_file(const godot::String& path);
  godot::String get_assembly_name() const;

  godot::Dictionary rebuild();
  int part_count() const;
  godot::String part_name(int part) const;
  godot::Ref<godot::ArrayMesh> part_mesh(int part, double deflection) const;
  godot::PackedVector3Array part_edges(int part, double deflection) const;

  int component_count() const;
  godot::Dictionary component(int index) const;  // name, part, transform, ok, message, id
  godot::Dictionary set_component_transform(const godot::String& id, const godot::Transform3D& t);
  godot::Dictionary pick(const godot::Vector3& origin, const godot::Vector3& direction, double max_distance) const;

  godot::Dictionary mass_properties() const;
  godot::Dictionary export_file(const godot::String& path, const godot::String& units);

protected:
  static void _bind_methods();

private:
  std::unique_ptr<fpcad::AssemblyModel> model_;
  std::string baseDir_;
};

}  // namespace fpcad_gd
