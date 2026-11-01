add_library(fpcad_core STATIC
  src/Expression.cpp
  src/Document.cpp
  src/Model.cpp
  src/FileIO.cpp
  src/Assembly.cpp
  src/Sketch.cpp
  src/SketchGeom.cpp
  src/Compare.cpp
  src/Challenges.cpp
  src/Export.cpp)

target_include_directories(fpcad_core PUBLIC include)
target_include_directories(fpcad_core SYSTEM PRIVATE ${OpenCASCADE_INCLUDE_DIR})

# Open CASCADE toolkits the core uses. They stay shared libraries (LGPL relinking).
set(FPCAD_OCCT_LIBS
  TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKGeomAlgo TKTopAlgo TKPrim TKBO TKBool
  TKFillet TKOffset TKMesh TKShHealing TKXSBase TKDE TKDESTEP TKDEIGES TKDESTL TKLCAF TKCAF TKCDF
  TKXCAF TKService TKV3d TKVCAF)

target_link_libraries(fpcad_core
  PUBLIC nlohmann_json::nlohmann_json ${FPCAD_OCCT_LIBS}
  PRIVATE miniz)

if(MSVC)
  target_compile_options(fpcad_core PRIVATE /W4 /permissive- /utf-8)
else()
  target_compile_options(fpcad_core PRIVATE -Wall -Wextra -Wno-deprecated-declarations)
endif()

if(FPCAD_BUILD_CLI)
  add_executable(fpcad cli/main.cpp)
  target_link_libraries(fpcad PRIVATE fpcad_core)
endif()

if(FPCAD_BUILD_TESTS)
  enable_testing()
  add_executable(fpcad_tests tests/tests.cpp)
  target_link_libraries(fpcad_tests PRIVATE fpcad_core miniz)
  target_include_directories(fpcad_tests SYSTEM PRIVATE ${OpenCASCADE_INCLUDE_DIR})
  add_test(NAME core COMMAND fpcad_tests WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})
endif()
