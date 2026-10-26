#pragma once
// Offline export to STEP, IGES, STL and 3MF, each checked by reading the file back.

#include <string>

namespace fpcad {

class PartModel;
class AssemblyModel;

enum class ExportFormat { Step, Iges, Stl, ThreeMF };

struct ExportOptions {
  std::string units = "mm";        // mm, cm, m or in
  std::string stepSchema = "AP242";  // AP242 or AP214
  double meshDeflection = 0;       // in output units; 0 picks one from the model size
  double meshAngle = 0.35;         // radians
  bool binaryStl = true;
  bool validate = true;
};

struct ExportResult {
  bool ok = false;
  std::string message;
  int bodies = 0;
  long triangles = 0;
  double sourceVolume = 0;    // in output units cubed
  double readBackVolume = 0;  // in output units cubed, from the written file
  double volumeError = 0;     // relative
  bool validated = false;
};

// Picks the format from the extension (.step/.stp, .igs/.iges, .stl, .3mf). Throws for others.
ExportFormat formatFromPath(const std::string& path);
const char* formatName(ExportFormat f);

ExportResult exportPart(const PartModel& model, const std::string& path, const ExportOptions& opts = {});
ExportResult exportAssembly(const AssemblyModel& model, const std::string& path, const ExportOptions& opts = {});

}  // namespace fpcad
