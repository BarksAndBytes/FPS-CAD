#pragma once
// Engineering materials: typical room-temperature properties and how the part looks when made of
// one. Values are representative handbook figures for the named grade and temper, good for mass
// and first estimates, not a substitute for a supplier's datasheet.

#include <optional>
#include <string>
#include <vector>

namespace fpcad {

struct Material {
  std::string name;
  std::string category;           // "Metal", "Plastic", "Other"
  double density = 0;             // kg/m^3
  double youngsModulus = 0;       // Pa
  double poissonsRatio = 0;
  std::optional<double> yieldStrength;    // Pa; none for brittle materials
  std::optional<double> tensileStrength;  // Pa, ultimate
  double thermalConductivity = 0; // W/(m·K)
  double specificHeat = 0;        // J/(kg·K)
  double thermalExpansion = 0;    // 1/K
  // Appearance: base colour (sRGB hex), PBR metallic and roughness, and opacity (1 = opaque).
  std::string color = "#b7bfc8";
  double metallic = 0;
  double roughness = 0.8;
  double opacity = 1;
};

// The library, metals first. Stable order: the game lists it as given.
const std::vector<Material>& materialLibrary();

// The library material of that name (older files' "Aluminium 6061" is 6061-T6), or null.
const Material* findMaterial(const std::string& name);

// The name the part shows when its density was typed in rather than taken from the library.
inline const char* kCustomMaterial = "Custom";

}  // namespace fpcad
