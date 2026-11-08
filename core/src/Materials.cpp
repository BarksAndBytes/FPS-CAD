#include "fpcad/Materials.h"

namespace fpcad {

namespace {

constexpr double GPa = 1e9;
constexpr double MPa = 1e6;

Material metal(const char* name, double rho, double e, double nu, std::optional<double> sy, double su, double k, double cp,
               double alpha, const char* color, double rough) {
  Material m;
  m.name = name;
  m.category = "Metal";
  m.density = rho;
  m.youngsModulus = e * GPa;
  m.poissonsRatio = nu;
  if (sy) m.yieldStrength = *sy * MPa;
  m.tensileStrength = su * MPa;
  m.thermalConductivity = k;
  m.specificHeat = cp;
  m.thermalExpansion = alpha * 1e-6;
  m.color = color;
  m.metallic = 1.0;
  m.roughness = rough;
  return m;
}

Material other(const char* category, const char* name, double rho, double e, double nu, std::optional<double> sy,
               double su, double k, double cp, double alpha, const char* color, double rough, double opacity = 1.0) {
  Material m = metal(name, rho, e, nu, sy, su, k, cp, alpha, color, rough);
  m.category = category;
  m.metallic = 0.0;
  m.opacity = opacity;
  return m;
}

}  // namespace

const std::vector<Material>& materialLibrary() {
  // name, density kg/m³, E GPa, ν, yield MPa, UTS MPa, k W/m·K, cp J/kg·K, α µm/m·K, colour, roughness
  static const std::vector<Material> lib = {
      metal("Aluminium 6061-T6", 2700, 68.9, 0.33, 276, 310, 167, 896, 23.6, "#c9cdd2", 0.35),
      metal("Aluminium 7075-T6", 2810, 71.7, 0.33, 503, 572, 130, 960, 23.4, "#bec3c9", 0.35),
      metal("Steel AISI 1020", 7870, 200, 0.29, 350, 420, 51.9, 486, 11.7, "#7f8389", 0.45),
      metal("Stainless steel 304", 8000, 193, 0.29, 215, 505, 16.2, 500, 17.3, "#b5b8bb", 0.25),
      metal("Grey cast iron", 7200, 110, 0.26, std::nullopt, 214, 46, 490, 10.8, "#5d6064", 0.7),
      metal("Titanium Ti-6Al-4V", 4430, 113.8, 0.342, 880, 950, 6.7, 526, 8.6, "#9c9b96", 0.4),
      metal("Brass C360", 8500, 97, 0.31, 310, 385, 115, 380, 20.5, "#c8a24a", 0.3),
      metal("Copper C110", 8890, 115, 0.31, 69, 220, 388, 385, 17.0, "#c4774c", 0.3),
      other("Plastic", "ABS", 1050, 2.3, 0.35, 40, 44, 0.17, 1400, 90, "#e9e5db", 0.6),
      other("Plastic", "PLA", 1240, 3.5, 0.36, std::nullopt, 50, 0.13, 1800, 68, "#f3f1ec", 0.5),
      other("Plastic", "Nylon 6/6", 1140, 2.9, 0.39, 70, 82, 0.25, 1670, 80, "#f1ece0", 0.55),
      other("Plastic", "Polycarbonate", 1200, 2.4, 0.37, 62, 66, 0.20, 1200, 65, "#dfe9ef", 0.15, 0.55),
      other("Plastic", "Acrylic (PMMA)", 1190, 3.2, 0.35, std::nullopt, 72, 0.19, 1470, 70, "#d6eef4", 0.05, 0.45),
      other("Other", "Oak", 750, 12.5, 0.37, std::nullopt, 90, 0.17, 2000, 5, "#a8794a", 0.8),
      other("Other", "Concrete", 2400, 30, 0.2, std::nullopt, 3, 1.7, 880, 12, "#8d8c86", 0.9),
      other("Other", "Glass (soda-lime)", 2500, 72, 0.22, std::nullopt, 40, 1.0, 840, 9, "#cfe6e2", 0.05, 0.4),
  };
  return lib;
}

const Material* findMaterial(const std::string& name) {
  const std::string n = name == "Aluminium 6061" ? "Aluminium 6061-T6" : name;
  for (const auto& m : materialLibrary())
    if (m.name == n) return &m;
  return nullptr;
}

}  // namespace fpcad
