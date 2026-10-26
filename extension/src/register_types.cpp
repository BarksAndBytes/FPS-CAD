#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "cad_assembly.h"
#include "cad_part.h"

using namespace godot;

static void initialize_fpcad(ModuleInitializationLevel level) {
  if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
  GDREGISTER_CLASS(fpcad_gd::CadPart);
  GDREGISTER_CLASS(fpcad_gd::CadAssembly);
}

static void uninitialize_fpcad(ModuleInitializationLevel level) {
  (void)level;
}

extern "C" {
GDExtensionBool GDE_EXPORT fpcad_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                              GDExtensionClassLibraryPtr library,
                                              GDExtensionInitialization* init) {
  GDExtensionBinding::InitObject obj(get_proc_address, library, init);
  obj.register_initializer(initialize_fpcad);
  obj.register_terminator(uninitialize_fpcad);
  obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
  return obj.init();
}
}
