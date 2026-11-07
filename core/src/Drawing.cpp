#include "fpcad/Drawing.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>

#include <BRepAdaptor_Curve.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <HLRAlgo_Projector.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <Standard_Failure.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <gp_Ax2.hxx>

namespace fpcad {
namespace {

constexpr double kPi = 3.14159265358979323846;

struct Pt {
  double x, y;
};

struct Circle {
  double x, y, r;  // model millimetres, in the view
};

// One projected view: polylines in model millimetres in the view plane.
struct View {
  std::vector<std::vector<Pt>> visible, hidden;
  std::vector<Circle> circles;
  double minx = 1e300, miny = 1e300, maxx = -1e300, maxy = -1e300;
  bool empty() const { return minx > maxx; }
  double w() const { return empty() ? 0 : maxx - minx; }
  double h() const { return empty() ? 0 : maxy - miny; }
  void grow(const Pt& p) {
    minx = std::min(minx, p.x);
    maxx = std::max(maxx, p.x);
    miny = std::min(miny, p.y);
    maxy = std::max(maxy, p.y);
  }
};

void sample(const TopoDS_Shape& s, std::vector<std::vector<Pt>>& out, View& v, std::vector<Circle>* circles) {
  if (s.IsNull()) return;
  for (TopExp_Explorer e(s, TopAbs_EDGE); e.More(); e.Next()) {
    const TopoDS_Edge& edge = TopoDS::Edge(e.Current());
    if (BRep_Tool::Degenerated(edge)) continue;
    try {
      BRepAdaptor_Curve c(edge);
      if (circles && c.GetType() == GeomAbs_Circle) {
        gp_Circ ci = c.Circle();
        double span = std::abs(c.LastParameter() - c.FirstParameter());
        if (span > 2 * kPi - 1e-6)
          circles->push_back({ci.Location().X() * 1000, ci.Location().Y() * 1000, ci.Radius() * 1000});
      }
      GCPnts_TangentialDeflection pts(c, 0.08, 1e-5);
      std::vector<Pt> line;
      for (int i = 1; i <= pts.NbPoints(); ++i) {
        gp_Pnt p = pts.Value(i);
        Pt q{p.X() * 1000, p.Y() * 1000};
        line.push_back(q);
        v.grow(q);
      }
      if (line.size() >= 2) out.push_back(std::move(line));
    } catch (const Standard_Failure&) {
    }
  }
}

// Hidden-line projection of the part, looking along -dir (dir points at the viewer), with xdir
// to the right.
View project(const PartModel& part, const gp_Dir& dir, const gp_Dir& xdir, bool hidden) {
  View v;
  if (part.bodyCount() == 0) return v;
  occ::handle<HLRBRep_Algo> algo = new HLRBRep_Algo();
  for (int b = 0; b < part.bodyCount(); ++b) algo->Add(part.body(b));
  algo->Projector(HLRAlgo_Projector(gp_Ax2(gp::Origin(), dir, xdir)));
  algo->Update();
  algo->Hide();
  HLRBRep_HLRToShape shapes(algo);
  sample(shapes.VCompound(), v.visible, v, &v.circles);
  sample(shapes.OutLineVCompound(), v.visible, v, nullptr);
  if (hidden) {
    sample(shapes.HCompound(), v.hidden, v, nullptr);
    sample(shapes.OutLineHCompound(), v.hidden, v, nullptr);
  }
  return v;
}

std::string fmt(double v, int digits) {
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.*f", digits, v);
  std::string s = buf;
  if (s.find('.') != std::string::npos) {
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
  }
  return s == "-0" ? "0" : s;
}

// Sheet builder: model millimetres to sheet millimetres for one view.
struct Placer {
  Sheet& sheet;
  double s;       // scale
  double ox, oy;  // sheet position of the view's (minx, miny)
  const View& v;
  Pt at(const Pt& p) const { return {ox + (p.x - v.minx) * s, oy + (p.y - v.miny) * s}; }
  void lines(const std::vector<std::vector<Pt>>& polys, DrawLayer layer) const {
    for (auto& poly : polys)
      for (size_t i = 1; i < poly.size(); ++i) {
        Pt a = at(poly[i - 1]), b = at(poly[i]);
        sheet.lines.push_back({a.x, a.y, b.x, b.y, layer});
      }
  }
};

void line(Sheet& s, double x1, double y1, double x2, double y2, DrawLayer l) { s.lines.push_back({x1, y1, x2, y2, l}); }

void arrow(Sheet& s, double x, double y, double dx, double dy) {
  // A 3 mm arrowhead at (x, y) pointing along (dx, dy).
  double n = std::hypot(dx, dy);
  if (n < 1e-12) return;
  dx /= n;
  dy /= n;
  double L = 3.0, W = 1.0;
  double bx = x - dx * L, by = y - dy * L;
  line(s, x, y, bx - dy * W, by + dx * W, DrawLayer::Dimension);
  line(s, x, y, bx + dy * W, by - dx * W, DrawLayer::Dimension);
  line(s, bx - dy * W, by + dx * W, bx + dy * W, by - dx * W, DrawLayer::Dimension);
}

// A linear dimension between sheet points a and b, drawn offset to one side (normal (nx, ny)).
void dimension(Sheet& s, Pt a, Pt b, double nx, double ny, double offset, const std::string& text) {
  Pt da{a.x + nx * offset, a.y + ny * offset}, db{b.x + nx * offset, b.y + ny * offset};
  line(s, a.x + nx * 1.5, a.y + ny * 1.5, da.x + nx * 2, da.y + ny * 2, DrawLayer::Dimension);
  line(s, b.x + nx * 1.5, b.y + ny * 1.5, db.x + nx * 2, db.y + ny * 2, DrawLayer::Dimension);
  line(s, da.x, da.y, db.x, db.y, DrawLayer::Dimension);
  arrow(s, da.x, da.y, da.x - db.x, da.y - db.y);
  arrow(s, db.x, db.y, db.x - da.x, db.y - da.y);
  double angle = std::atan2(db.y - da.y, db.x - da.x);
  if (angle > kPi / 2 + 1e-9 || angle < -kPi / 2 - 1e-9) angle += kPi;
  s.texts.push_back({(da.x + db.x) / 2 + nx * 2.8, (da.y + db.y) / 2 + ny * 2.8, 3.5, angle, text});
}

double unitMm(const std::string& u) {
  if (u == "cm") return 10;
  if (u == "m") return 1000;
  if (u == "in") return 25.4;
  if (u == "ft") return 304.8;
  return 1;
}

std::string modelLength(double mm, const std::string& units) {
  double v = mm / unitMm(units);
  int digits = units == "mm" ? 2 : units == "in" || units == "ft" ? 3 : 3;
  return fmt(v, digits);
}

// Overall width and height of a view, and the diameters of its full circles (deduplicated).
void dimensionView(Sheet& s, const Placer& p, const std::string& units) {
  const View& v = p.v;
  if (v.empty()) return;
  Pt bl = p.at({v.minx, v.miny}), br = p.at({v.maxx, v.miny}), tl = p.at({v.minx, v.maxy});
  if (v.w() > 1e-6) dimension(s, bl, br, 0, -1, 8, modelLength(v.w(), units));
  if (v.h() > 1e-6) dimension(s, bl, tl, -1, 0, 8, modelLength(v.h(), units));
  std::vector<Circle> seen;
  int shown = 0;
  for (auto& c : v.circles) {
    bool dup = false;
    for (auto& k : seen)
      if (std::abs(k.x - c.x) < 1e-3 && std::abs(k.y - c.y) < 1e-3 && std::abs(k.r - c.r) < 1e-3) dup = true;
    if (dup) continue;
    seen.push_back(c);
    if (++shown > 6) break;
    Pt ctr = p.at({c.x, c.y});
    double r = c.r * p.s;
    double a = kPi / 4;
    Pt edge{ctr.x + r * std::cos(a), ctr.y + r * std::sin(a)};
    Pt knee{edge.x + 6, edge.y + 6};
    line(s, edge.x, edge.y, knee.x, knee.y, DrawLayer::Dimension);
    line(s, knee.x, knee.y, knee.x + 10, knee.y, DrawLayer::Dimension);
    arrow(s, edge.x, edge.y, edge.x - knee.x, edge.y - knee.y);
    s.texts.push_back({knee.x + 12, knee.y + 2.2, 3.5, 0, "Ø" + modelLength(2 * c.r, units)});
    // Centre marks.
    line(s, ctr.x - 1.5, ctr.y, ctr.x + 1.5, ctr.y, DrawLayer::Dimension);
    line(s, ctr.x, ctr.y - 1.5, ctr.x, ctr.y + 1.5, DrawLayer::Dimension);
  }
}

std::string scaleText(double s) {
  if (s >= 1) return fmt(s, 2) + ":1";
  return "1:" + fmt(1 / s, 2);
}

void rect(Sheet& s, double x, double y, double w, double h, DrawLayer l) {
  line(s, x, y, x + w, y, l);
  line(s, x + w, y, x + w, y + h, l);
  line(s, x + w, y + h, x, y + h, l);
  line(s, x, y + h, x, y, l);
}

}  // namespace

std::string lengthText(double metres, const std::string& units) {
  return modelLength(metres * 1000, units) + " " + units;
}

Sheet standardViews(const PartModel& part, const DrawingInfo& info) {
  Sheet s;
  s.title = info.partName;
  View front = project(part, gp_Dir(0, -1, 0), gp_Dir(1, 0, 0), info.hidden);
  View top = project(part, gp_Dir(0, 0, 1), gp_Dir(1, 0, 0), info.hidden);
  View right = project(part, gp_Dir(1, 0, 0), gp_Dir(0, 1, 0), info.hidden);
  View iso = project(part, gp_Dir(1, -1, 1), gp_Dir(1, 1, 0), false);
  // Border and title block.
  const double m = 10, tbw = 180, tbh = 30;
  rect(s, m, m, s.width - 2 * m, s.height - 2 * m, DrawLayer::Border);
  // Usable area: above the title block row on the right, the whole height on the left.
  const double gap = 25;  // between views, with room for dimensions
  double availW = s.width - 2 * m - 3 * gap - 20;
  double availH = s.height - 2 * m - tbh - 3 * gap - 10;
  double needW = front.w() + right.w(), needH = front.h() + top.h();
  // Leave a third of the width for the isometric.
  double scale = 1;
  if (needW > 1e-9 || needH > 1e-9) {
    double fit = std::min(needW > 1e-9 ? availW * 0.68 / needW : 1e9, needH > 1e-9 ? availH / needH : 1e9);
    static const double steps[] = {50, 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001};
    scale = steps[sizeof steps / sizeof steps[0] - 1];
    for (double st : steps)
      if (st <= fit) {
        scale = st;
        break;
      }
  }
  s.scale = scale;
  double x0 = m + gap + 10, y0 = m + tbh + gap;
  Placer pf{s, scale, x0, y0, front};
  Placer pt{s, scale, x0, y0 + front.h() * scale + gap, top};
  Placer pr{s, scale, x0 + front.w() * scale + gap, y0, right};
  for (const Placer* p : {&pf, &pt, &pr}) {
    p->lines(p->v.hidden, DrawLayer::Hidden);
    p->lines(p->v.visible, DrawLayer::Visible);
    if (info.dimensions) dimensionView(s, *p, info.units);
  }
  // The isometric fills the top-right space at the same scale or smaller.
  if (!iso.empty()) {
    double left = x0 + (front.w() + right.w()) * scale + 2 * gap;
    double room = s.width - m - gap - left, roomH = s.height - m - gap - (m + tbh + gap);
    double si = std::min({scale, room > 0 ? room / std::max(iso.w(), 1e-9) : scale, roomH / std::max(iso.h(), 1e-9)});
    if (si > 0) {
      Placer pi{s, si, s.width - m - gap - iso.w() * si, s.height - m - gap - iso.h() * si, iso};
      pi.lines(iso.visible, DrawLayer::Visible);
    }
  }
  // Labels under each view.
  auto label = [&](const Placer& p, const char* name) {
    if (p.v.empty()) return;
    Pt c = p.at({(p.v.minx + p.v.maxx) / 2, p.v.miny});
    s.texts.push_back({c.x, c.y - 17, 3.5, 0, name});
  };
  label(pf, "FRONT");
  label(pt, "TOP");
  label(pr, "RIGHT");
  // Title block, bottom right.
  double bx = s.width - m - tbw, by = m;
  rect(s, bx, by, tbw, tbh, DrawLayer::Border);
  line(s, bx, by + tbh / 2, bx + tbw, by + tbh / 2, DrawLayer::Border);
  line(s, bx + 110, by, bx + 110, by + tbh, DrawLayer::Border);
  s.texts.push_back({bx + 55, by + tbh * 0.75, 6, 0, info.partName});
  s.texts.push_back({bx + 55, by + tbh * 0.25, 3, 0, info.material.empty() ? "FPS-CAD" : info.material});
  s.texts.push_back({bx + 145, by + tbh * 0.75, 3.5, 0, "SCALE " + scaleText(scale)});
  s.texts.push_back({bx + 145, by + tbh * 0.25, 3, 0, "UNITS " + info.units + " · THIRD ANGLE"});
  return s;
}

Sheet flatView(const std::vector<std::vector<std::array<double, 2>>>& polylines, const std::string& title,
               const std::string& units, bool dimensions) {
  Sheet s;
  s.trueSize = true;
  s.title = title;
  View v;
  for (auto& poly : polylines) {
    std::vector<Pt> line;
    for (auto& p : poly) {
      Pt q{p[0] * 1000, p[1] * 1000};
      line.push_back(q);
      v.grow(q);
    }
    if (line.size() >= 2) v.visible.push_back(std::move(line));
  }
  if (v.empty()) {
    s.width = s.height = 0;
    return s;
  }
  // True size: sheet coordinates are model millimetres, with a 20 mm margin around for dims.
  Placer p{s, 1.0, v.minx, v.miny, v};
  p.lines(v.visible, DrawLayer::Visible);
  if (dimensions) dimensionView(s, p, units);
  s.width = v.w();
  s.height = v.h();
  return s;
}

// ---------- DXF ----------

std::string writeDxf(const Sheet& sheet, const std::string& path) {
  std::ofstream f(path, std::ios::binary);
  if (!f) return "cannot write " + path;
  auto g = [&](int code, const std::string& v) { f << code << "\r\n" << v << "\r\n"; };
  auto gd = [&](int code, double v) { g(code, fmt(v, 6)); };
  const char* layers[] = {"VISIBLE", "HIDDEN", "DIMENSIONS", "BORDER", "OUTLINE"};
  g(0, "SECTION");
  g(2, "HEADER");
  g(9, "$ACADVER");
  g(1, "AC1009");
  g(9, "$INSUNITS");
  g(70, "4");  // millimetres
  g(0, "ENDSEC");
  g(0, "SECTION");
  g(2, "TABLES");
  g(0, "TABLE");
  g(2, "LTYPE");
  g(70, "2");
  g(0, "LTYPE");
  g(2, "CONTINUOUS");
  g(70, "0");
  g(3, "Solid line");
  g(72, "65");
  g(73, "0");
  gd(40, 0);
  g(0, "LTYPE");
  g(2, "HIDDEN");
  g(70, "0");
  g(3, "Hidden __ __ __");
  g(72, "65");
  g(73, "2");
  gd(40, 4.5);
  gd(49, 3);
  gd(49, -1.5);
  g(0, "ENDTAB");
  g(0, "TABLE");
  g(2, "LAYER");
  g(70, "5");
  const int colours[] = {7, 8, 1, 7, 5};
  for (int i = 0; i < 5; ++i) {
    g(0, "LAYER");
    g(2, layers[i]);
    g(70, "0");
    g(62, std::to_string(colours[i]));
    g(6, i == 1 ? "HIDDEN" : "CONTINUOUS");
  }
  g(0, "ENDTAB");
  g(0, "ENDSEC");
  g(0, "SECTION");
  g(2, "ENTITIES");
  for (auto& l : sheet.lines) {
    g(0, "LINE");
    g(8, layers[static_cast<int>(l.layer)]);
    gd(10, l.x1);
    gd(20, l.y1);
    gd(30, 0);
    gd(11, l.x2);
    gd(21, l.y2);
    gd(31, 0);
  }
  for (auto& t : sheet.texts) {
    std::string txt = t.text;
    // DXF R12 text: Ø is %%c, ° is %%d; other non-ASCII is dropped to '?'.
    std::string out;
    for (size_t i = 0; i < txt.size(); ++i) {
      unsigned char c = static_cast<unsigned char>(txt[i]);
      if (c < 0x80) {
        out += static_cast<char>(c);
        continue;
      }
      if (txt.compare(i, 2, "\xC3\x98") == 0) { out += "%%c"; ++i; continue; }
      if (txt.compare(i, 2, "\xC2\xB0") == 0) { out += "%%d"; ++i; continue; }
      if (txt.compare(i, 2, "\xC2\xB7") == 0) { out += "-"; ++i; continue; }
      while (i + 1 < txt.size() && (static_cast<unsigned char>(txt[i + 1]) & 0xC0) == 0x80) ++i;
      out += '?';
    }
    g(0, "TEXT");
    g(8, "DIMENSIONS");
    gd(10, t.x);
    gd(20, t.y);
    gd(30, 0);
    gd(40, t.height);
    g(1, out);
    gd(50, t.angle * 180 / kPi);
    g(72, "1");  // centred
    g(73, "2");  // middle
    gd(11, t.x);
    gd(21, t.y);
    gd(31, 0);
  }
  g(0, "ENDSEC");
  g(0, "EOF");
  f.close();
  return f ? "" : "cannot write " + path;
}

// ---------- PDF ----------

namespace {

// UTF-8 to a PDF string in WinAnsiEncoding (Helvetica's built-in encoding).
std::string pdfString(const std::string& s) {
  std::string out = "(";
  for (size_t i = 0; i < s.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if (c == '(' || c == ')' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x80) {
      out += static_cast<char>(c);
    } else {
      unsigned code = 0;
      int extra = 0;
      if ((c & 0xE0) == 0xC0) { code = c & 0x1F; extra = 1; }
      else if ((c & 0xF0) == 0xE0) { code = c & 0x0F; extra = 2; }
      else { code = c & 0x07; extra = 3; }
      for (int k = 0; k < extra && i + 1 < s.size(); ++k) code = (code << 6) | (static_cast<unsigned char>(s[++i]) & 0x3F);
      int b = code >= 0xA0 && code <= 0xFF ? static_cast<int>(code) : code == 0x2300 ? 0xD8 : '?';
      char buf[8];
      std::snprintf(buf, sizeof buf, "\\%03o", b);
      out += buf;
    }
  }
  return out + ")";
}

// Helvetica's average width as a fraction of the size, for centring text.
double textWidth(const std::string& s, double size) {
  size_t n = 0;
  for (unsigned char c : s) if ((c & 0xC0) != 0x80) ++n;
  return static_cast<double>(n) * size * 0.55;
}

}  // namespace

std::string writePdf(const Sheet& sheet, const std::string& path) {
  const double pt = 72.0 / 25.4;  // points per millimetre
  double pageW = sheet.width, pageH = sheet.height, k = 1, ox = 0, oy = 0;
  std::string note;
  if (sheet.trueSize) {
    // The smallest A-size landscape page that holds it at 1:1 with a margin; else A0, scaled.
    static const double sizes[][2] = {{297, 210}, {420, 297}, {594, 420}, {841, 594}, {1189, 841}};
    double w = sheet.width + 50, h = sheet.height + 50;
    pageW = 1189;
    pageH = 841;
    bool fits = false;
    for (auto& a : sizes)
      if (w <= a[0] && h <= a[1]) {
        pageW = a[0];
        pageH = a[1];
        fits = true;
        break;
      }
    if (!fits) k = std::min((pageW - 50) / std::max(sheet.width, 1e-9), (pageH - 50) / std::max(sheet.height, 1e-9));
    ox = (pageW - sheet.width * k) / 2;
    oy = (pageH - sheet.height * k) / 2;
    note = sheet.title + "  ·  " + (fits ? std::string("1:1 (print at 100%)") : "scaled " + scaleText(k));
  }
  std::ostringstream c;
  c.setf(std::ios::fixed);
  c.precision(3);
  auto X = [&](double x) { return (ox + x * k) * pt; };
  auto Y = [&](double y) { return (oy + y * k) * pt; };
  const double widths[] = {0.5, 0.3, 0.25, 0.7, 0.35};
  for (int layer : {1, 0, 4, 2, 3}) {  // hidden lines first, so visible ones draw over them
    bool any = false;
    for (auto& l : sheet.lines)
      if (static_cast<int>(l.layer) == layer) any = true;
    if (!any) continue;
    c << widths[layer] * pt << " w ";
    c << (layer == 1 ? "[3 1.5] 0 d " : "[] 0 d ");
    c << (layer == 2 ? "0.1 0.25 0.6 RG\n" : "0 0 0 RG\n");
    for (auto& l : sheet.lines) {
      if (static_cast<int>(l.layer) != layer) continue;
      c << X(l.x1) << " " << Y(l.y1) << " m " << X(l.x2) << " " << Y(l.y2) << " l S\n";
    }
  }
  auto text = [&](double x, double y, double size, double angle, const std::string& t) {
    double ca = std::cos(angle), sa = std::sin(angle);
    double w = textWidth(t, size), h = size * 0.7;
    // Move from the centre to the baseline start.
    double bx = x - ca * w / 2 + sa * h / 2, by = y - sa * w / 2 - ca * h / 2;
    c << "BT /F1 " << size * k * pt << " Tf " << ca << " " << sa << " " << -sa << " " << ca << " " << X(bx) << " "
      << Y(by) << " Tm " << pdfString(t) << " Tj ET\n";
  };
  c << "0 0 0 rg\n";
  for (auto& t : sheet.texts) text(t.x, t.y, t.height, t.angle, t.text);
  if (!note.empty()) {
    double save = k;
    k = 1;
    double sox = ox, soy = oy;
    ox = 0;
    oy = 0;
    text(pageW / 2, 12, 4, 0, note);
    k = save;
    ox = sox;
    oy = soy;
  }
  std::string content = c.str();
  std::vector<std::string> objs;
  objs.push_back("<< /Type /Catalog /Pages 2 0 R >>");
  objs.push_back("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
  std::ostringstream page;
  page.setf(std::ios::fixed);
  page.precision(2);
  page << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " << pageW * pt << " " << pageH * pt
       << "] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>";
  objs.push_back(page.str());
  objs.push_back("<< /Length " + std::to_string(content.size()) + " >>\nstream\n" + content + "endstream");
  objs.push_back("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
  objs.push_back("<< /Title " + pdfString(sheet.title) + " /Producer (FPS-CAD) >>");
  std::ofstream f(path, std::ios::binary);
  if (!f) return "cannot write " + path;
  std::string out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
  std::vector<size_t> offsets;
  for (size_t i = 0; i < objs.size(); ++i) {
    offsets.push_back(out.size());
    out += std::to_string(i + 1) + " 0 obj\n" + objs[i] + "\nendobj\n";
  }
  size_t xref = out.size();
  out += "xref\n0 " + std::to_string(objs.size() + 1) + "\n0000000000 65535 f \n";
  for (size_t o : offsets) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%010zu 00000 n \n", o);
    out += buf;
  }
  out += "trailer\n<< /Size " + std::to_string(objs.size() + 1) + " /Root 1 0 R /Info 6 0 R >>\nstartxref\n" + std::to_string(xref) + "\n%%EOF\n";
  f << out;
  f.close();
  return f ? "" : "cannot write " + path;
}

}  // namespace fpcad
