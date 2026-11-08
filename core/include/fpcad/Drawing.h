#pragma once
// Drawings (0.9): a sheet of 2D lines and text made from a part — the standard views (front, top,
// right in third-angle projection, plus an isometric) with hidden lines and model dimensions,
// or a true-size flat view of a sketch or a face — written as DXF or PDF, and the .fpdrw file
// that records which part a drawing shows.

#include <array>
#include <string>
#include <vector>

#include "fpcad/Model.h"

namespace fpcad {

enum class DrawLayer { Visible, Hidden, Dimension, Border, Outline };

struct DrawLine {
  double x1 = 0, y1 = 0, x2 = 0, y2 = 0;  // sheet millimetres
  DrawLayer layer = DrawLayer::Visible;
};

struct DrawText {
  double x = 0, y = 0;  // sheet millimetres: the text's centre
  double height = 3.5;  // millimetres
  double angle = 0;     // radians, anticlockwise
  std::string text;     // UTF-8; Ø ° × · are kept, other non-ASCII becomes '?' in PDF
};

struct Sheet {
  double width = 420, height = 297;  // millimetres (A3 landscape for standard views)
  double scale = 1;                  // sheet mm per model mm
  bool trueSize = false;             // a flat view: coordinates are model millimetres, no border
  std::string title;
  std::vector<DrawLine> lines;
  std::vector<DrawText> texts;
};

struct DrawingInfo {
  std::string partName = "Part";
  std::string units = "mm";      // the length unit dimensions are written in
  std::string material;
  bool hidden = true;            // draw hidden lines (dashed)
  bool dimensions = true;        // overall sizes and hole diameters
};

// Front, top and right views in third-angle projection and an isometric, laid out on A3 at a
// standard scale that fits, with a border and a title block.
Sheet standardViews(const PartModel& part, const DrawingInfo& info);

// A true-size view of polylines in a plane (metres): a sketch or a face's outline.
Sheet flatView(const std::vector<std::vector<std::array<double, 2>>>& polylines, const std::string& title,
               const std::string& units, bool dimensions = true);

// Writes the sheet as DXF (R12, millimetres) or PDF (vector, one page the sheet's size; a
// true-size view goes on the smallest A-size page that fits it at 1:1, or is scaled to A0).
// Returns "" or a reason.
std::string writeDxf(const Sheet& sheet, const std::string& path);
std::string writePdf(const Sheet& sheet, const std::string& path);

// Formats a length in metres in a unit ("12.5", "1.25 in").
std::string lengthText(double metres, const std::string& units);

// The .fpdrw file: which part the drawing shows (path relative to the drawing, and its file id)
// and the drawing's options.
struct DrawingDocument {
  std::string name = "Drawing";
  std::string partPath;
  std::string partFileId;
  bool hidden = true;
  bool dimensions = true;
};
void saveDrawing(const std::string& path, const DrawingDocument& d);
DrawingDocument loadDrawing(const std::string& path);

}  // namespace fpcad
