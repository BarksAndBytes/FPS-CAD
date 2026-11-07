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

  // 0.8: building assemblies in the game.
  void new_blank(const godot::String& name, const godot::String& base_dir);
  void set_assembly_name(const godot::String& name);
  // Places a saved part (a path in base_dir or absolute) as a new component; the first is grounded.
  godot::Dictionary insert_part(const godot::String& path, const godot::Transform3D& t);
  godot::Dictionary remove_component(const godot::String& id);
  godot::Dictionary set_grounded(const godot::String& id, bool grounded);
  // A face reference for a mate from an assembly pick (part-local probe, normal, feature, role).
  godot::Dictionary face_ref(const godot::Dictionary& hit) const;
  // Measures the face behind a pick in assembly space: kind, normal/axis, centre, radius.
  godot::Dictionary face_measure(const godot::Dictionary& hit) const;
  godot::Dictionary add_mate(const godot::String& type, const godot::Dictionary& a, const godot::Dictionary& b,
                             const godot::Dictionary& params);
  godot::Dictionary delete_mate(const godot::String& id);
  godot::Array mates() const;                 // id, type, a, b (component names), ok, value
  godot::Dictionary mate_status() const;      // ok, message
  godot::Dictionary drag_component(const godot::String& id, const godot::Vector3& delta);
  godot::Array interference() const;          // a, b (names), volume, centre
  godot::Array bom() const;                   // name, quantity, material, mass (each)
  void set_explode(double factor);            // spreads components out from the centre (view only)
  double get_explode() const { return explode_; }
  godot::Array components() const;            // id, name, grounded, ok, part

  void checkpoint();
  bool undo();
  bool redo();

protected:
  static void _bind_methods();

private:
  std::unique_ptr<fpcad::AssemblyModel> model_;
  std::string baseDir_;
  double explode_ = 0;
  std::vector<fpcad::AssemblyDocument> undo_, redo_;
  fpcad::Placement shown(size_t index) const;  // a placed component's placement, exploded
  void reload(fpcad::AssemblyDocument doc);
};

}  // namespace fpcad_gd
