# The Godot GDExtension: binds the CAD core to GDScript as CadPart and CadAssembly.
#
# godot-cpp is fetched at configure time. To use a local checkout instead, configure with
#   -DFETCHCONTENT_SOURCE_DIR_GODOT_CPP=/path/to/godot-cpp

include(FetchContent)
set(GODOTCPP_DISABLE_EXCEPTIONS OFF CACHE BOOL "" FORCE)  # the core reports errors with exceptions
FetchContent_Declare(godot_cpp
  GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
  GIT_TAG godot-4.5-stable
  GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(godot_cpp)

add_library(fpcad_gdext SHARED
  src/register_types.cpp
  src/convert.cpp
  src/cad_part.cpp
  src/cad_assembly.cpp)

target_link_libraries(fpcad_gdext PRIVATE fpcad_core godot::cpp)
target_include_directories(fpcad_gdext SYSTEM PRIVATE ${OpenCASCADE_INCLUDE_DIR})

# Name the library the way godot/bin/fpcad.gdextension expects: libfpcad.<platform>.<target>.<arch>
if(ANDROID)
  set(FPCAD_PLATFORM android)
elseif(WIN32)
  set(FPCAD_PLATFORM windows)
elseif(APPLE)
  set(FPCAD_PLATFORM macos)
else()
  set(FPCAD_PLATFORM linux)
endif()
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
  set(FPCAD_ARCH arm64)
else()
  set(FPCAD_ARCH x86_64)
endif()

set_target_properties(fpcad_gdext PROPERTIES
  OUTPUT_NAME "fpcad.${FPCAD_PLATFORM}.${GODOTCPP_TARGET}.${FPCAD_ARCH}"
  PREFIX "lib"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/godot/bin"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/godot/bin"
  BUILD_RPATH "$ORIGIN"
  INSTALL_RPATH "$ORIGIN")
foreach(cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
  set_target_properties(fpcad_gdext PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY_${cfg} "${CMAKE_SOURCE_DIR}/godot/bin"
    RUNTIME_OUTPUT_DIRECTORY_${cfg} "${CMAKE_SOURCE_DIR}/godot/bin")
endforeach()
