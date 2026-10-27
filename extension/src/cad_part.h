#pragma once
// CadPart: a parametric part as Godot sees it. All positions are Godot space (Y up, metres).

#include <deque>
#include <memory>
#include <vector>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "fpcad/Model.h"

namespace fpcad_gd {

class CadPart : public godot::RefCounted {
  GDCLASS(CadPart, godot::RefCounted)

public:
  CadPart();

  // Documents
  void make_sample();
  void make_training();
  void new_blank(const godot::String& name, const godot::String& units);
  godot::String load_file(const godot::String& path);  // "" on success, else the reason
  godot::String save_file(const godot::String& path);
  godot::String get_part_name() const;
  godot::String get_units() const;
  godot::String get_file_id() const;

  // Rebuild and display
  godot::Dictionary rebuild();
  int body_count() const;
  godot::Ref<godot::ArrayMesh> build_mesh(int body, double deflection);
  godot::PackedInt32Array triangle_faces(int body) const;  // face index per triangle of the last mesh
  godot::PackedStringArray face_feature_ids(int body) const;  // feature id per face of the last mesh
  godot::PackedVector3Array build_edges(int body, double deflection);
  godot::PackedVector3Array face_vertices(int body, int face) const;

  // Interaction
  godot::Dictionary pick(const godot::Vector3& origin, const godot::Vector3& direction, double max_distance);
  godot::Dictionary push_pull(const godot::Dictionary& hit, double delta);
  godot::String add_primitive(const godot::String& type, const godot::Vector3& base, const godot::Dictionary& dims,
                              const godot::String& op);
  godot::Dictionary move_feature(const godot::String& id, const godot::Vector3& delta);
  godot::Dictionary delete_feature(const godot::String& id);
  godot::String duplicate_feature(const godot::String& id, const godot::Vector3& offset);
  godot::Dictionary feature_dims(const godot::String& id) const;
  godot::Dictionary set_param(const godot::String& id, const godot::String& key, const godot::Variant& value);
  godot::Dictionary set_variable(const godot::String& name, const godot::String& expr);
  godot::Array get_features() const;
  godot::Array get_variables() const;
  godot::Dictionary mass_properties() const;
  godot::Dictionary export_file(const godot::String& path, const godot::String& units);

  // History
  bool undo();
  bool redo();
  bool can_undo() const { return !undo_.empty(); }
  bool can_redo() const { return !redo_.empty(); }
  void checkpoint();     // call before a series of edits that should undo as one step
  void drop_checkpoint();  // forget the last checkpoint (the edit was cancelled)

protected:
  static void _bind_methods();

private:
  godot::Dictionary commitOrRevert(const fpcad::PartDocument& backup, const std::string& what);

  std::unique_ptr<fpcad::PartModel> model_;
  std::vector<godot::PackedInt32Array> triFaces_;
  std::vector<godot::PackedStringArray> faceFeatures_;
  std::deque<fpcad::PartDocument> undo_, redo_;
};

}  // namespace fpcad_gd
