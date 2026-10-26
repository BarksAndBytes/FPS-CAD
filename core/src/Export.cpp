#include "fpcad/Export.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <tuple>
#include <unordered_map>

#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <IGESControl_Controller.hxx>
#include <IGESControl_Reader.hxx>
#include <IGESControl_Writer.hxx>
#include <Interface_Static.hxx>
#include <Poly_Triangulation.hxx>
#include <RWStl.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Quaternion.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_Printer.hxx>
#include <miniz.h>

#include "fpcad/Assembly.h"
#include "fpcad/Expression.h"
#include "fpcad/Model.h"

namespace fpcad {
namespace {

// One body in output units, ready to write.
struct OutPart {
  std::string name;
  std::vector<TopoDS_Shape> bodies;  // in output units, part space
};
struct OutInstance {
  std::string name;
  int part;
  gp_Trsf placement;  // translation in output units
};
struct OutScene {
  std::string name;
  std::vector<OutPart> parts;
  std::vector<OutInstance> instances;
  bool isAssembly = false;
  double scale = 1000;  // output units per metre
};

TopoDS_Shape scaled(const TopoDS_Shape& s, double k) {
  gp_Trsf t;
  t.SetScale(gp_Pnt(0, 0, 0), k);
  return BRepBuilderAPI_Transform(s, t, true).Shape();
}

gp_Trsf toTrsf(const Placement& p, double k) {
  gp_Trsf t;
  t.SetRotation(gp_Quaternion(p.q[0], p.q[1], p.q[2], p.q[3]).Normalized());
  t.SetTranslationPart(gp_Vec(p.t[0] * k, p.t[1] * k, p.t[2] * k));
  return t;
}

double volumeOf(const TopoDS_Shape& s) {
  GProp_GProps g;
  BRepGProp::VolumeProperties(s, g);
  return g.Mass();
}

int solidCount(const TopoDS_Shape& s) {
  int n = 0;
  for (TopExp_Explorer e(s, TopAbs_SOLID); e.More(); e.Next()) ++n;
  return n;
}

// Every placed body in output units, in scene space.
std::vector<TopoDS_Shape> flatten(const OutScene& sc) {
  std::vector<TopoDS_Shape> out;
  for (auto& inst : sc.instances)
    for (auto& b : sc.parts[static_cast<size_t>(inst.part)].bodies)
      out.push_back(inst.placement.Form() == gp_Identity ? b : b.Moved(TopLoc_Location(inst.placement)));
  return out;
}

TopoDS_Shape compound(const std::vector<TopoDS_Shape>& shapes) {
  TopoDS_Compound c;
  BRep_Builder bb;
  bb.MakeCompound(c);
  for (auto& s : shapes) bb.Add(c, s);
  return c;
}

double sceneVolume(const OutScene& sc) {
  double v = 0;
  for (auto& s : flatten(sc)) v += volumeOf(s);
  return v;
}

TCollection_ExtendedString ext(const std::string& s) { return TCollection_ExtendedString(s.c_str(), true); }

const char* stepUnit(const std::string& u) {
  if (u == "mm") return "MM";
  if (u == "cm") return "CM";
  if (u == "m") return "M";
  if (u == "in") return "INCH";
  throw std::invalid_argument("STEP export supports mm, cm, m and in");
}

const char* igesUnit(const std::string& u) {
  if (u == "mm") return "MM";
  if (u == "cm") return "CM";
  if (u == "m") return "M";
  if (u == "in") return "IN";
  throw std::invalid_argument("IGES export supports mm, cm, m and in");
}

const char* threeMfUnit(const std::string& u) {
  if (u == "mm") return "millimeter";
  if (u == "cm") return "centimeter";
  if (u == "m") return "meter";
  if (u == "in") return "inch";
  throw std::invalid_argument("3MF export supports mm, cm, m and in");
}

void check(ExportResult& r, double tolerance, const std::string& what) {
  r.volumeError = r.sourceVolume > 0 ? std::abs(r.readBackVolume - r.sourceVolume) / r.sourceVolume : 0;
  r.validated = r.volumeError <= tolerance;
  char buf[160];
  std::snprintf(buf, sizeof buf, "%s read back: volume differs by %.4f%% (limit %.4f%%)", what.c_str(),
                r.volumeError * 100, tolerance * 100);
  r.message = buf;
  r.ok = r.validated;
}

// ---------- STEP ----------

ExportResult writeStep(const OutScene& sc, const std::string& path, const ExportOptions& o) {
  ExportResult r;
  // Geometry is handed over in millimetres (Open CASCADE's working unit); the writer converts to
  // the requested file unit.
  const double toMm = 1000.0 / sc.scale;
  occ::handle<TDocStd_Document> doc;
  XCAFApp_Application::GetApplication()->NewDocument("MDTV-XCAF", doc);
  XCAFDoc_DocumentTool::SetLengthUnit(doc, 0.001);
  occ::handle<XCAFDoc_ShapeTool> shapes = XCAFDoc_DocumentTool::ShapeTool(doc->Main());
  occ::handle<XCAFDoc_ColorTool> colors = XCAFDoc_DocumentTool::ColorTool(doc->Main());
  const Quantity_Color partColour(0.82, 0.80, 0.76, Quantity_TOC_RGB);

  std::vector<TDF_Label> partLabels;
  for (auto& p : sc.parts) {
    std::vector<TopoDS_Shape> mm;
    for (auto& b : p.bodies) mm.push_back(toMm == 1.0 ? b : scaled(b, toMm));
    TopoDS_Shape s = mm.size() == 1 ? mm[0] : compound(mm);
    TDF_Label l = shapes->AddShape(s, false);
    TDataStd_Name::Set(l, ext(p.name));
    colors->SetColor(l, partColour, XCAFDoc_ColorSurf);
    partLabels.push_back(l);
  }
  if (sc.isAssembly) {
    TDF_Label assy = shapes->NewShape();
    TDataStd_Name::Set(assy, ext(sc.name));
    for (auto& inst : sc.instances) {
      gp_Trsf t = inst.placement;
      t.SetTranslationPart(t.TranslationPart() * toMm);
      TDF_Label c = shapes->AddComponent(assy, partLabels[static_cast<size_t>(inst.part)], TopLoc_Location(t));
      TDataStd_Name::Set(c, ext(inst.name));
    }
    shapes->UpdateAssemblies();
  }

  STEPCAFControl_Writer w;
  w.SetNameMode(true);
  w.SetColorMode(true);
  Interface_Static::SetCVal("write.step.unit", stepUnit(o.units));
  Interface_Static::SetIVal("write.step.schema", o.stepSchema == "AP214" ? 4 : 5);
  if (!w.Transfer(doc, STEPControl_AsIs)) throw std::runtime_error("STEP translation failed");
  if (w.Write(path.c_str()) != IFSelect_RetDone) throw std::runtime_error("cannot write " + path);

  r.bodies = static_cast<int>(flatten(sc).size());
  r.sourceVolume = sceneVolume(sc);
  if (!o.validate) { r.ok = true; r.message = "written"; return r; }
  STEPControl_Reader rd;
  if (rd.ReadFile(path.c_str()) != IFSelect_RetDone) throw std::runtime_error("written STEP file cannot be read back");
  rd.TransferRoots();
  TopoDS_Shape back = rd.OneShape();
  // The reader returns millimetres whatever the file unit, so convert back to output units.
  double k = sc.scale / 1000.0;
  r.readBackVolume = volumeOf(back) * k * k * k;
  check(r, 1e-4, "STEP");
  if (r.ok && solidCount(back) != r.bodies) {
    r.ok = false;
    r.message += "; expected " + std::to_string(r.bodies) + " solids, read " + std::to_string(solidCount(back));
  }
  return r;
}

// ---------- IGES ----------

ExportResult writeIges(const OutScene& sc, const std::string& path, const ExportOptions& o) {
  ExportResult r;
  const double toMm = 1000.0 / sc.scale;
  IGESControl_Controller::Init();
  IGESControl_Writer w(igesUnit(o.units), 1);  // 1 = B-rep solids (MSBO), not trimmed surfaces
  auto placed = flatten(sc);
  for (auto& s : placed) w.AddShape(toMm == 1.0 ? s : scaled(s, toMm));
  w.ComputeModel();
  if (!w.Write(path.c_str())) throw std::runtime_error("cannot write " + path);
  r.bodies = static_cast<int>(placed.size());
  r.sourceVolume = sceneVolume(sc);
  if (!o.validate) { r.ok = true; r.message = "written"; return r; }
  IGESControl_Reader rd;
  if (rd.ReadFile(path.c_str()) != IFSelect_RetDone) throw std::runtime_error("written IGES file cannot be read back");
  rd.TransferRoots();
  TopoDS_Shape back = rd.OneShape();
  double k = sc.scale / 1000.0;
  r.readBackVolume = volumeOf(back) * k * k * k;
  check(r, 1e-4, "IGES");
  return r;
}

// ---------- meshes for STL and 3MF ----------

struct Mesh {
  std::vector<double> xyz;
  std::vector<uint32_t> tri;
};

// Triangulates a shape and welds coincident vertices so the result is a closed, shared-vertex mesh.
Mesh triangulate(const TopoDS_Shape& s, double defl, double ang) {
  BRepMesh_IncrementalMesh(s, defl, false, ang, true);
  Mesh m;
  const double q = defl * 1e-3;  // weld tolerance, far below the chordal deviation
  std::map<std::tuple<long long, long long, long long>, uint32_t> welded;
  auto vid = [&](const gp_Pnt& p) {
    auto key = std::make_tuple(std::llround(p.X() / q), std::llround(p.Y() / q), std::llround(p.Z() / q));
    auto it = welded.find(key);
    if (it != welded.end()) return it->second;
    uint32_t id = static_cast<uint32_t>(m.xyz.size() / 3);
    m.xyz.insert(m.xyz.end(), {p.X(), p.Y(), p.Z()});
    welded.emplace(key, id);
    return id;
  };
  for (TopExp_Explorer e(s, TopAbs_FACE); e.More(); e.Next()) {
    const TopoDS_Face& f = TopoDS::Face(e.Current());
    TopLoc_Location loc;
    occ::handle<Poly_Triangulation> t = BRep_Tool::Triangulation(f, loc);
    if (t.IsNull()) continue;
    gp_Trsf tr = loc.Transformation();
    std::vector<uint32_t> ids(static_cast<size_t>(t->NbNodes()) + 1);
    for (int i = 1; i <= t->NbNodes(); ++i) ids[static_cast<size_t>(i)] = vid(t->Node(i).Transformed(tr));
    bool rev = f.Orientation() == TopAbs_REVERSED;
    for (int i = 1; i <= t->NbTriangles(); ++i) {
      int a, b, c;
      t->Triangle(i).Get(a, b, c);
      if (rev) std::swap(b, c);
      uint32_t ia = ids[static_cast<size_t>(a)], ib = ids[static_cast<size_t>(b)], ic = ids[static_cast<size_t>(c)];
      if (ia == ib || ib == ic || ia == ic) continue;  // collapsed by welding
      m.tri.insert(m.tri.end(), {ia, ib, ic});
    }
  }
  return m;
}

double meshVolume(const std::vector<double>& xyz, const std::vector<uint32_t>& tri) {
  double v = 0;
  for (size_t i = 0; i < tri.size(); i += 3) {
    const double* a = &xyz[tri[i] * 3];
    const double* b = &xyz[tri[i + 1] * 3];
    const double* c = &xyz[tri[i + 2] * 3];
    v += a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]);
  }
  return v / 6.0;
}

double autoDeflection(const OutScene& sc, const ExportOptions& o) {
  if (o.meshDeflection > 0) return o.meshDeflection;
  Bnd_Box box;
  for (auto& s : flatten(sc)) BRepBndLib::Add(s, box);
  if (box.IsVoid()) return 0.01;
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  double diag = std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0));
  return std::max(diag * 2e-4, 1e-6);
}

ExportResult writeStl(const OutScene& sc, const std::string& path, const ExportOptions& o) {
  ExportResult r;
  double defl = autoDeflection(sc, o);
  auto placed = flatten(sc);
  TopoDS_Shape all = compound(placed);  // triangulation honours each instance's location
  Mesh m = triangulate(all, defl, o.meshAngle);
  // Write our welded mesh so STL and 3MF carry identical triangles.
  occ::handle<Poly_Triangulation> t = new Poly_Triangulation(static_cast<int>(m.xyz.size() / 3),
                                                              static_cast<int>(m.tri.size() / 3), false);
  for (int i = 0; i < t->NbNodes(); ++i)
    t->SetNode(i + 1, gp_Pnt(m.xyz[i * 3], m.xyz[i * 3 + 1], m.xyz[i * 3 + 2]));
  for (int i = 0; i < t->NbTriangles(); ++i)
    t->SetTriangle(i + 1, Poly_Triangle(int(m.tri[i * 3]) + 1, int(m.tri[i * 3 + 1]) + 1, int(m.tri[i * 3 + 2]) + 1));
  bool written = o.binaryStl ? RWStl::WriteBinary(t, OSD_Path(path.c_str())) : RWStl::WriteAscii(t, OSD_Path(path.c_str()));
  if (!written) throw std::runtime_error("cannot write " + path);
  r.bodies = static_cast<int>(placed.size());
  r.triangles = static_cast<long>(m.tri.size() / 3);
  r.sourceVolume = sceneVolume(sc);
  if (!o.validate) { r.ok = true; r.message = "written"; return r; }
  occ::handle<Poly_Triangulation> back = RWStl::ReadFile(path.c_str());
  if (back.IsNull()) throw std::runtime_error("written STL file cannot be read back");
  std::vector<double> xyz;
  std::vector<uint32_t> tri;
  for (int i = 1; i <= back->NbNodes(); ++i) {
    gp_Pnt p = back->Node(i);
    xyz.insert(xyz.end(), {p.X(), p.Y(), p.Z()});
  }
  for (int i = 1; i <= back->NbTriangles(); ++i) {
    int a, b, c;
    back->Triangle(i).Get(a, b, c);
    tri.insert(tri.end(), {uint32_t(a - 1), uint32_t(b - 1), uint32_t(c - 1)});
  }
  r.readBackVolume = meshVolume(xyz, tri);
  check(r, 0.01, "STL");  // a mesh only approximates curved faces
  return r;
}

// ---------- 3MF (3MF Core Specification 1.3, written directly) ----------

std::string xmlEscape(const std::string& s) {
  std::string o;
  for (char c : s) {
    switch (c) {
      case '&': o += "&amp;"; break;
      case '<': o += "&lt;"; break;
      case '>': o += "&gt;"; break;
      case '"': o += "&quot;"; break;
      default: o += c;
    }
  }
  return o;
}

std::string num(double v) {
  char b[32];
  std::snprintf(b, sizeof b, "%.6g", v);
  return b;
}

ExportResult write3mf(const OutScene& sc, const std::string& path, const ExportOptions& o) {
  ExportResult r;
  double defl = autoDeflection(sc, o);
  std::ostringstream x;
  x << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    << "<model unit=\"" << threeMfUnit(o.units) << "\" xml:lang=\"en-US\" "
    << "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n"
    << " <metadata name=\"Title\">" << xmlEscape(sc.name) << "</metadata>\n"
    << " <metadata name=\"Application\">FPS-CAD</metadata>\n <resources>\n";
  long triangles = 0;
  double meshVol = 0;
  std::vector<double> partVolume(sc.parts.size(), 0.0);
  for (size_t p = 0; p < sc.parts.size(); ++p) {
    Mesh m = triangulate(compound(sc.parts[p].bodies), defl, o.meshAngle);
    partVolume[p] = meshVolume(m.xyz, m.tri);
    x << "  <object id=\"" << p + 1 << "\" type=\"model\" name=\"" << xmlEscape(sc.parts[p].name) << "\">\n"
      << "   <mesh>\n    <vertices>\n";
    for (size_t i = 0; i < m.xyz.size(); i += 3)
      x << "     <vertex x=\"" << num(m.xyz[i]) << "\" y=\"" << num(m.xyz[i + 1]) << "\" z=\"" << num(m.xyz[i + 2]) << "\"/>\n";
    x << "    </vertices>\n    <triangles>\n";
    for (size_t i = 0; i < m.tri.size(); i += 3)
      x << "     <triangle v1=\"" << m.tri[i] << "\" v2=\"" << m.tri[i + 1] << "\" v3=\"" << m.tri[i + 2] << "\"/>\n";
    x << "    </triangles>\n   </mesh>\n  </object>\n";
  }
  x << " </resources>\n <build>\n";
  for (auto& inst : sc.instances) {
    const gp_Trsf& t = inst.placement;
    // 3MF transforms are row-vector 3x4: m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32.
    x << "  <item objectid=\"" << inst.part + 1 << "\" transform=\"";
    for (int c = 1; c <= 3; ++c)
      for (int rr = 1; rr <= 3; ++rr) x << num(t.Value(rr, c)) << ' ';
    x << num(t.Value(1, 4)) << ' ' << num(t.Value(2, 4)) << ' ' << num(t.Value(3, 4)) << "\"/>\n";
    meshVol += partVolume[static_cast<size_t>(inst.part)];
  }
  x << " </build>\n</model>\n";
  std::string model = x.str();
  for (size_t p = model.find("<triangle "); p != std::string::npos; p = model.find("<triangle ", p + 1)) ++triangles;

  const std::string contentTypes =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n"
      " <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n"
      " <Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>\n"
      "</Types>\n";
  const std::string rels =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
      " <Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" "
      "Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>\n"
      "</Relationships>\n";
  mz_zip_archive zip;
  mz_zip_zero_struct(&zip);
  if (!mz_zip_writer_init_file(&zip, path.c_str(), 0)) throw std::runtime_error("cannot write " + path);
  bool ok = mz_zip_writer_add_mem(&zip, "[Content_Types].xml", contentTypes.data(), contentTypes.size(), MZ_DEFAULT_COMPRESSION) &&
            mz_zip_writer_add_mem(&zip, "_rels/.rels", rels.data(), rels.size(), MZ_DEFAULT_COMPRESSION) &&
            mz_zip_writer_add_mem(&zip, "3D/3dmodel.model", model.data(), model.size(), MZ_DEFAULT_COMPRESSION) &&
            mz_zip_writer_finalize_archive(&zip);
  mz_zip_writer_end(&zip);
  if (!ok) throw std::runtime_error("cannot write " + path);

  r.bodies = static_cast<int>(flatten(sc).size());
  r.triangles = triangles;
  r.sourceVolume = sceneVolume(sc);
  if (!o.validate) { r.ok = true; r.message = "written"; return r; }
  // Read the package back and make sure the model part survived intact.
  mz_zip_archive rd;
  mz_zip_zero_struct(&rd);
  if (!mz_zip_reader_init_file(&rd, path.c_str(), 0)) throw std::runtime_error("written 3MF file cannot be read back");
  size_t size = 0;
  void* data = mz_zip_reader_extract_file_to_heap(&rd, "3D/3dmodel.model", &size, 0);
  std::string back = data ? std::string(static_cast<char*>(data), size) : std::string();
  if (data) mz_free(data);
  mz_zip_reader_end(&rd);
  if (back != model) throw std::runtime_error("3MF model part did not read back intact");
  r.readBackVolume = meshVol;
  check(r, 0.01, "3MF");
  return r;
}

double outputScale(const ExportOptions& o) { return 1.0 / unitScale(o.units); }

}  // namespace

ExportFormat formatFromPath(const std::string& path) {
  auto dot = path.find_last_of('.');
  std::string ext = dot == std::string::npos ? "" : path.substr(dot + 1);
  std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
  if (ext == "step" || ext == "stp") return ExportFormat::Step;
  if (ext == "igs" || ext == "iges") return ExportFormat::Iges;
  if (ext == "stl") return ExportFormat::Stl;
  if (ext == "3mf") return ExportFormat::ThreeMF;
  throw std::invalid_argument("unsupported export type '." + ext + "' (use .step, .igs, .stl or .3mf)");
}

const char* formatName(ExportFormat f) {
  switch (f) {
    case ExportFormat::Step: return "STEP";
    case ExportFormat::Iges: return "IGES";
    case ExportFormat::Stl: return "STL";
    case ExportFormat::ThreeMF: return "3MF";
  }
  return "?";
}

// Translators print transfer statistics to stdout by default; keep only real failures.
static void quietTranslators() {
  static bool done = false;
  if (done) return;
  done = true;
  for (auto& p : Message::DefaultMessenger()->Printers()) p->SetTraceLevel(Message_Fail);
}

static ExportResult writeScene(const OutScene& sc, const std::string& path, const ExportOptions& o) {
  quietTranslators();
  try {
    if (sc.instances.empty()) throw std::runtime_error("nothing to export: the model has no solid bodies");
    switch (formatFromPath(path)) {
      case ExportFormat::Step: return writeStep(sc, path, o);
      case ExportFormat::Iges: return writeIges(sc, path, o);
      case ExportFormat::Stl: return writeStl(sc, path, o);
      case ExportFormat::ThreeMF: return write3mf(sc, path, o);
    }
  } catch (const Standard_Failure& e) {
    ExportResult r;
    r.message = std::string("geometry kernel error: ") + e.GetMessageString();
    return r;
  } catch (const std::exception& e) {
    ExportResult r;
    r.message = e.what();
    return r;
  }
  return {};
}

ExportResult exportPart(const PartModel& model, const std::string& path, const ExportOptions& o) {
  OutScene sc;
  sc.name = model.document().name;
  try {
    sc.scale = outputScale(o);
  } catch (const std::exception& e) {
    ExportResult r;
    r.message = e.what();
    return r;
  }
  if (model.bodyCount() > 0) {
    OutPart p;
    p.name = model.document().name;
    for (int b = 0; b < model.bodyCount(); ++b) p.bodies.push_back(scaled(model.body(b), sc.scale));
    sc.parts.push_back(p);
    sc.instances.push_back({p.name, 0, gp_Trsf()});
  }
  return writeScene(sc, path, o);
}

ExportResult exportAssembly(const AssemblyModel& model, const std::string& path, const ExportOptions& o) {
  OutScene sc;
  sc.name = model.document().name;
  sc.isAssembly = true;
  try {
    sc.scale = outputScale(o);
  } catch (const std::exception& e) {
    ExportResult r;
    r.message = e.what();
    return r;
  }
  std::vector<int> remap(model.parts().size(), -1);
  for (size_t i = 0; i < model.parts().size(); ++i) {
    const auto& ap = model.parts()[i];
    if (!ap.model || ap.model->bodyCount() == 0) continue;
    OutPart p;
    p.name = ap.name;
    for (int b = 0; b < ap.model->bodyCount(); ++b) p.bodies.push_back(scaled(ap.model->body(b), sc.scale));
    remap[i] = static_cast<int>(sc.parts.size());
    sc.parts.push_back(std::move(p));
  }
  for (auto& pc : model.components()) {
    if (pc.part < 0 || remap[static_cast<size_t>(pc.part)] < 0) continue;
    sc.instances.push_back({pc.name, remap[static_cast<size_t>(pc.part)], toTrsf(pc.placement, sc.scale)});
  }
  return writeScene(sc, path, o);
}

}  // namespace fpcad
