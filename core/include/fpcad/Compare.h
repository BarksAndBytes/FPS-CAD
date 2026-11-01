#pragma once
// Decides whether two parts are the same solid geometry, whatever their position, orientation
// or construction history. Used by the challenge mode to check a player's copy of a target part.
//
// Cheap invariants first (volume, surface area, principal moments of inertia), then candidate
// rotations from each part's principal axes, face normals and hole axes, filtered by inertia and
// point containment, confirmed by an exact boolean: the parts match when their common volume is
// all of both. Mirror images are recognised and reported, but do not match.

#include <string>

namespace fpcad {

class PartModel;

struct ShapeMatch {
  bool match = false;
  bool mirrored = false;     // the player's part is a mirror image of the target
  bool empty = false;        // the player has not built anything yet
  double volumeRatio = 0;    // player volume / target volume
  double areaRatio = 0;      // player surface area / target surface area
  double overlap = 0;        // best common volume / target volume (0 when no alignment was tried)
  std::string message;       // a short hint for the player
};

// tolerance: allowed relative difference in volume and in overlap (0.002 = 0.2 %).
ShapeMatch compareParts(const PartModel& player, const PartModel& target, double tolerance = 0.002);

}  // namespace fpcad
