# Third-party dependencies for the CAD core.
#
# Open CASCADE is found as an installed package (build it once per platform; see docs/BUILDING.md).
# nlohmann/json and miniz are small and fetched from GitHub at configure time.

include(FetchContent)

# OCCT's version file only accepts exact matches, so check the minimum ourselves.
find_package(OpenCASCADE REQUIRED CONFIG)
if(OpenCASCADE_VERSION VERSION_LESS 8.0)
  message(FATAL_ERROR "Open CASCADE 8.0 or newer is required (found ${OpenCASCADE_VERSION})")
endif()
message(STATUS "Open CASCADE ${OpenCASCADE_VERSION} at ${OpenCASCADE_INSTALL_PREFIX}")

set(JSON_BuildTests OFF CACHE INTERNAL "")
set(JSON_Install OFF CACHE INTERNAL "")
FetchContent_Declare(nlohmann_json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG v3.11.3
  GIT_SHALLOW TRUE)

set(BUILD_EXAMPLES OFF CACHE INTERNAL "")
set(BUILD_FUZZERS OFF CACHE INTERNAL "")
set(BUILD_TESTS OFF CACHE INTERNAL "")
set(AMALGAMATE_SOURCES OFF CACHE INTERNAL "")
FetchContent_Declare(miniz
  GIT_REPOSITORY https://github.com/richgel999/miniz.git
  GIT_TAG 3.0.2
  GIT_SHALLOW TRUE)

FetchContent_MakeAvailable(nlohmann_json miniz)
