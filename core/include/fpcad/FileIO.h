#pragma once
// Native files: .fpprt (part) and .fpasm (assembly), ZIP containers of versioned JSON plus
// cached B-rep. History is the source of truth; caches are rebuilt whenever they are stale.

#include <stdexcept>
#include <string>

#include "fpcad/Document.h"

namespace fpcad {

class PartModel;

class FileError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

enum class FileKind { Part, Assembly, Unknown };

FileKind fileKind(const std::string& path);  // reads the manifest, not the extension

// Writes to "<path>.tmp" and renames over the target, so a failed save never corrupts the file.
// When model is given and matches doc, its bodies are cached in geometry/.
void savePart(const std::string& path, const PartDocument& doc, const PartModel* model = nullptr);
PartDocument loadPart(const std::string& path);

void saveAssembly(const std::string& path, const AssemblyDocument& doc);
AssemblyDocument loadAssembly(const std::string& path);

// Number of cached bodies whose history hash still matches (0 when the cache is stale).
int cachedBodyCount(const std::string& path);

}  // namespace fpcad
