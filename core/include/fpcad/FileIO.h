#pragma once
// Native files: .fpprt (part) and .fpasm (assembly), ZIP containers of versioned JSON plus
// cached B-rep. History is the source of truth; caches are rebuilt whenever they are stale.

#include <stdexcept>
#include <string>
#include <vector>

#include "fpcad/Document.h"

namespace fpcad {

class PartModel;

class FileError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

enum class FileKind { Part, Assembly, Drawing, Unknown };

FileKind fileKind(const std::string& path);  // reads the manifest, not the extension

// Writes to "<path>.tmp" and renames over the target, so a failed save never corrupts the file.
// When model is given and matches doc, its bodies are cached in geometry/.
void savePart(const std::string& path, const PartDocument& doc, const PartModel* model = nullptr);
PartDocument loadPart(const std::string& path);

void saveAssembly(const std::string& path, const AssemblyDocument& doc);
AssemblyDocument loadAssembly(const std::string& path);

// Number of cached bodies whose history hash still matches (0 when the cache is stale).
int cachedBodyCount(const std::string& path);

// A part's whole document as one JSON value, for sending between players (multiplayer): the
// history, variables, settings, rollback bar, viewpoints and boards; with withImports, also the
// imported shapes (base64), which can be large, so senders include them only when they change.
Json partState(const PartDocument& doc, bool withImports);
// The document a partState describes. Its imports are those of keepImportsFrom (when given) plus
// any in the state, which replace ones with the same id. Throws FileError when the JSON isn't a
// part state.
PartDocument partFromState(const Json& state, const PartDocument* keepImportsFrom = nullptr);

// Combines two changes to a shared part (multiplayer), both made from base: theirs (the host's
// copy) and mine (a change that arrived). Item by item, like a version control merge: features by
// id, variables and viewpoints by name, boards by id; what only one side changed, added or deleted
// is kept, additions go after the item before them; when both changed the same item, theirs wins
// and the item's name goes in conflicts. Feature order is theirs unless only mine moved features.
// Single values (name, units, material, density) come from the side that changed them. The
// rollback bar stays before the same feature. Numbers keep their types.
struct StateMerge {
  Json state;
  std::vector<std::string> conflicts;
};
StateMerge mergePartStates(const Json& base, const Json& theirs, const Json& mine);

}  // namespace fpcad
