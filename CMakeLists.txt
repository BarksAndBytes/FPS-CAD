cmake_minimum_required(VERSION 3.21)
project(fpcad VERSION 0.1.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(FPCAD_BUILD_TESTS "Build the headless core tests" ON)
option(FPCAD_BUILD_CLI "Build the fpcad command-line tool" ON)
option(FPCAD_BUILD_EXTENSION "Build the Godot GDExtension (needs godot-cpp)" OFF)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(FpcadDependencies)

if(FPCAD_BUILD_TESTS)
  enable_testing()
endif()

add_subdirectory(core)

if(FPCAD_BUILD_EXTENSION)
  add_subdirectory(extension)
endif()
