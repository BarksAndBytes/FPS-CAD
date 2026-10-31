#pragma once
// Challenge mode: a series of target parts for the player to copy, from a plain block to parts
// that need revolves, sweeps, lofts and holes. A copy passes when compareParts() (Compare.h)
// says it is the same solid, however it was built or turned.

#include <string>
#include <vector>

#include "fpcad/Document.h"
#include "fpcad/Model.h"

namespace fpcad {

// A dimension shown on the target: a line from a to b (metres, CAD axes) labelled text.
struct Callout {
  Vec3 a{};
  Vec3 b{};
  std::string text;
};

struct Challenge {
  std::string id;
  std::string name;
  std::string brief;   // what to build, in a sentence
  std::string hint;    // a nudge towards the tools that do it
  std::vector<Callout> callouts;
  PartDocument target;
};

std::vector<Challenge> challenges();

}  // namespace fpcad
