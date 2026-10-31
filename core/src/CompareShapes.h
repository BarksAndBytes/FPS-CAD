#pragma once
// Shape-level comparison behind fpcad/Compare.h, exposed for the core tests.

#include <TopoDS_Shape.hxx>

#include "fpcad/Compare.h"

namespace fpcad {

ShapeMatch compareShapes(const TopoDS_Shape& player, const TopoDS_Shape& target, double tolerance = 0.002);

}  // namespace fpcad
