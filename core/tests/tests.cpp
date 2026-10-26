// Headless tests for the CAD core: expressions, rebuild, picking, push/pull, native files and
// every export format with read-back validation.

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

#include <miniz.h>

#include "fpcad/Assembly.h"
#include "fpcad/Export.h"
#include "fpcad/Expression.h"
#include "fpcad/FileIO.h"
#include "fpcad/Model.h"

using namespace fpcad;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(cond)                                                                  \
  do {                                                                               \
    ++checks;                                                                        \
    if (!(cond)) {                                                                   \
      ++failures;                                                                    \
      std::fprintf(stderr, "  FAILED %s:%d  %s\n", __FILE__, __LINE__, #cond);       \
    }                                                                                \
  } while (0)

#define CHECK_NEAR(a, b, tol) CHECK(std::abs((a) - (b)) <= (tol))

template <class F>
bool throws(F f) {
  try {
    f();
  } catch (...) {
    return true;
  }
  return false;
}

void run(const char* name, const std::function<void()>& t) {
  int before = failures;
  try {
    t();
  } catch (const std::exception& e) {
    ++failures;
    std::fprintf(stderr, "  FAILED %s threw: %s\n", name, e.what());
  }
  std::printf("%s %s\n", failures == before ? "PASS" : "FAIL", name);
}

const Feature& named(const PartModel& m, const std::string& name) {
  for (auto& f : m.document().features) if (f.name == name) return f;
  throw std::runtime_error("no feature " + name);
}

std::string zipEntry(const std::string& path, const std::string& name) {
  mz_zip_archive z;
  mz_zip_zero_struct(&z);
  if (!mz_zip_reader_init_file(&z, path.c_str(), 0)) return {};
  size_t n = 0;
  void* p = mz_zip_reader_extract_file_to_heap(&z, name.c_str(), &n, 0);
  std::string s = p ? std::string(static_cast<char*>(p), n) : std::string();
  if (p) mz_free(p);
  mz_zip_reader_end(&z);
  return s;
}

size_t count(const std::string& hay, const std::string& needle) {
  size_t n = 0;
  for (size_t p = hay.find(needle); p != std::string::npos; p = hay.find(needle, p + 1)) ++n;
  return n;
}

constexpr double kSampleVolume = 84.474;  // m^3, from the sample's dimensions (see tests notes)

}  // namespace

int main() {
  namespace fs = std::filesystem;
  fs::path out = fs::temp_directory_path() / "fpcad-tests";
  fs::remove_all(out);
  fs::create_directories(out);

  run("expressions", [] {
    VariableTable v{{"w", 0.1}};
    CHECK_NEAR(evaluate("12", v, Quantity::Length, 1e-3), 0.012, 1e-12);
    CHECK_NEAR(evaluate("12 mm", v, Quantity::Length, 1.0), 0.012, 1e-12);
    CHECK_NEAR(evaluate("2in", v, Quantity::Length, 1e-3), 0.0508, 1e-12);
    CHECK_NEAR(evaluate("w / 2 + 3 mm", v, Quantity::Length, 1e-3), 0.053, 1e-12);
    CHECK_NEAR(evaluate("w / 2 + 3", v, Quantity::Length, 1e-3), 0.053, 1e-12);
    CHECK_NEAR(evaluate("2 * (w + 10 mm)", v, Quantity::Length, 1e-3), 0.22, 1e-12);
    CHECK_NEAR(evaluate("-(5) cm", v, Quantity::Length, 1e-3), -0.05, 1e-12);
    CHECK_NEAR(evaluate("30 deg", v, Quantity::Angle, 1e-3), std::acos(-1.0) / 6, 1e-12);
    CHECK_NEAR(evaluate("4", v, Quantity::Count, 1e-3), 4.0, 1e-12);
    CHECK(throws([&] { evaluate("foo + 1", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("1 / 0", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("(1 + 2", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("5 mm mm", v, Quantity::Length, 1e-3); }));
    CHECK(throws([&] { evaluate("", v, Quantity::Length, 1e-3); }));
  });

  run("sample part rebuilds into one valid solid", [] {
    PartModel m(PartDocument::sample());
    auto r = m.rebuild();
    for (auto& st : r.features) if (!st.ok) std::fprintf(stderr, "    %s: %s\n", st.featureId.c_str(), st.message.c_str());
    CHECK(r.ok);
    CHECK(m.bodyCount() == 1);
    auto mp = m.massProperties();
    CHECK_NEAR(mp.volume, kSampleVolume, 0.05);
    CHECK_NEAR(mp.mass, mp.volume * 2700, 1e-6);
  });

  run("display mesh tags every face with its feature", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    BodyMesh mesh = m.mesh(0, 0.01);
    CHECK(mesh.indices.size() > 300);
    CHECK(mesh.indices.size() == mesh.triangleFace.size() * 3);
    CHECK(mesh.positions.size() == mesh.normals.size());
    CHECK(!mesh.edgeLines.empty());
    bool allTagged = !mesh.faces.empty();
    for (auto& f : mesh.faces) allTagged = allTagged && !f.featureId.empty();
    CHECK(allTagged);
  });

  run("picking finds the right feature and face drive", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    auto roof = m.pick({0.3, 0, 10}, {0, 0, -1});
    CHECK(roof && roof->featureId == named(m, "Roof").id);
    CHECK(roof && std::abs(roof->point[2] - 3.7) < 1e-6);
    CHECK(roof && roof->normal[2] > 0.99);
    auto drive = roof ? m.faceDrive(*roof) : std::nullopt;
    CHECK(drive && drive->param == "+h" && std::abs(drive->value - 0.3) < 1e-9);

    auto column = m.pick({2.6, -10, 2}, {0, 1, 0});
    CHECK(column && column->featureId == named(m, "Column 1").id);
    auto cd = column ? m.faceDrive(*column) : std::nullopt;
    CHECK(cd && cd->param == "r" && std::abs(cd->value - 0.3) < 1e-9);

    auto door = m.pick({-2.5, 1, 1.5}, {1, 0, 0});  // from inside the doorway toward its side
    CHECK(door && door->featureId == named(m, "Doorway").id);
    auto dd = door ? m.faceDrive(*door) : std::nullopt;
    CHECK(dd && dd->param == "p+w");
    CHECK(!m.pick({100, 100, 100}, {1, 0, 0}));
  });

  run("push/pull edits the driving parameter", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    double v0 = m.massProperties().volume;
    auto roof = m.pick({0.3, 0, 10}, {0, 0, -1});
    std::string msg;
    CHECK(roof && m.pushPull(*roof, 0.1, &msg));
    CHECK_NEAR(m.param(named(m, "Roof"), "h"), 0.4, 1e-9);
    CHECK_NEAR(m.massProperties().volume - v0, 9 * 6.2 * 0.1, 0.01);

    // Pushing a doorway wall out into the opening narrows the doorway; pulling widens it.
    auto door = m.pick({-2.5, 1, 1.5}, {1, 0, 0});
    double v1 = m.massProperties().volume;
    CHECK(door && m.pushPull(*door, 0.1, &msg));
    CHECK_NEAR(m.massProperties().volume - v1, 0.1 * 2.2 * 4, 1e-6);
    auto moved = m.pick({-2.5, 1, 1.5}, {1, 0, 0});
    CHECK(moved && std::abs(moved->point[0] - (-2.0)) < 1e-6);
    auto other = m.pick({-2.5, 1, 1.5}, {-1, 0, 0});  // the opposite wall stayed put
    CHECK(other && std::abs(other->point[0] - (-3.1)) < 1e-6);
    CHECK(moved && m.pushPull(*moved, -0.3, &msg));
    CHECK_NEAR(named(m, "Doorway").params["profile"]["w"].get<double>(), 1.4, 1e-9);

    auto bottom = m.pick({0, -2, -5}, {0, 0, 1});  // underside of the plinth
    CHECK(bottom && m.pushPull(*bottom, 0.05, &msg));
    CHECK_NEAR(m.param(named(m, "Plinth"), "z"), -0.05, 1e-9);
    CHECK_NEAR(m.param(named(m, "Plinth"), "h"), 0.45, 1e-9);
  });

  run("a broken edit is refused and rolled back", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    double v0 = m.massProperties().volume;
    auto roof = m.pick({-4.0, -2.9, 10}, {0, 0, -1});  // near a filleted corner of the roof
    (void)roof;
    // Grow the roof fillet far past what the slab can take.
    PickHit fake;
    fake.featureId = named(m, "Roof corners").id;
    fake.normal = {1, 0, 0};
    std::string msg;
    CHECK(!m.pushPull(fake, 50.0, &msg));
    CHECK(!msg.empty());
    CHECK(m.lastReport().ok);
    CHECK_NEAR(m.massProperties().volume, v0, 1e-9);
  });

  run("variables drive dependent features", [] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    double v0 = m.massProperties().volume;
    for (auto& v : m.document().variables) if (v.name == "storey") v.expr = "4000 mm";
    CHECK(m.rebuild().ok);
    // Core grows by 4x4x1 and the two columns by pi r^2 x 1; the roof rides up.
    double expected = 16 + 2 * std::acos(-1.0) * 0.09;
    CHECK_NEAR(m.massProperties().volume - v0, expected, 1e-6);
    CHECK_NEAR(m.variables().at("storey"), 4.0, 1e-12);
    for (auto& v : m.document().variables) if (v.name == "storey") v.expr = "nonsense +";
    CHECK(!m.rebuild().ok);
  });

  run("failed features are reported, not fatal", [] {
    PartModel m(PartDocument::sample());
    for (auto& f : m.document().features) if (f.type == "fillet") f.params["r"] = 5.0;
    auto r = m.rebuild();
    CHECK(!r.ok);
    CHECK(m.bodyCount() == 1);  // everything before and after the fillet still builds
    int failed = 0;
    for (auto& st : r.features) failed += st.ok ? 0 : 1;
    CHECK(failed == 1);
  });

  run("native part file round-trips with cached geometry", [&] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    std::string path = (out / "pavilion.fpprt").string();
    savePart(path, m.document(), &m);
    CHECK(fileKind(path) == FileKind::Part);
    CHECK(!fs::exists(path + ".tmp"));
    PartDocument back = loadPart(path);
    CHECK(back.featuresJson() == m.document().featuresJson());
    CHECK(back.variablesJson() == m.document().variablesJson());
    CHECK(back.fileId == m.document().fileId);
    CHECK(back.viewpoints.size() == 1);
    CHECK(cachedBodyCount(path) == 1);
    // Editing the history makes the cache stale.
    back.features[0].params["h"] = 0.5;
    savePart(path, back);
    CHECK(cachedBodyCount(path) == 0);
    CHECK(throws([&] { loadAssembly(path); }));
    CHECK(throws([&] { loadPart((out / "missing.fpprt").string()); }));
  });

  run("files from a newer format version are refused clearly", [&] {
    std::string path = (out / "future.fpprt").string();
    mz_zip_archive z;
    mz_zip_zero_struct(&z);
    mz_zip_writer_init_file(&z, path.c_str(), 0);
    std::string m = R"({"format":"fps-cad","formatVersion":99,"kind":"part"})";
    mz_zip_writer_add_mem(&z, "manifest.json", m.data(), m.size(), MZ_DEFAULT_COMPRESSION);
    mz_zip_writer_finalize_archive(&z);
    mz_zip_writer_end(&z);
    std::string msg;
    try {
      loadPart(path);
    } catch (const FileError& e) {
      msg = e.what();
    }
    CHECK(msg.find("newer version") != std::string::npos);
  });

  run("part exports to every format and reads back", [&] {
    PartModel m(PartDocument::sample());
    m.rebuild();
    const double mm3 = kSampleVolume * 1e9;
    for (const char* name : {"pavilion.step", "pavilion.igs", "pavilion.stl", "pavilion.3mf"}) {
      std::string path = (out / name).string();
      ExportResult r = exportPart(m, path, {});
      std::printf("    %-14s ok=%d validated=%d bodies=%d tris=%ld  %s\n", name, r.ok, r.validated, r.bodies,
                  r.triangles, r.message.c_str());
      CHECK(r.ok && r.validated);
      CHECK(fs::file_size(path) > 1000);
      CHECK_NEAR(r.sourceVolume / mm3, 1.0, 1e-3);
    }
    ExportOptions inches;
    inches.units = "in";
    inches.stepSchema = "AP214";
    ExportResult r = exportPart(m, (out / "pavilion-in.step").string(), inches);
    CHECK(r.ok && r.validated);
    ExportResult bad = exportPart(m, (out / "pavilion.dwg").string(), {});
    CHECK(!bad.ok && bad.message.find("unsupported") != std::string::npos);
    std::string model = zipEntry((out / "pavilion.3mf").string(), "3D/3dmodel.model");
    CHECK(model.find("unit=\"millimeter\"") != std::string::npos);
    CHECK(count(model, "<item ") == 1);
  });

  run("assembly saves, loads, instances parts and exports", [&] {
    std::string path = (out / "pins.fpasm").string();
    saveAssembly(path, AssemblyDocument::sample());
    CHECK(fileKind(path) == FileKind::Assembly);
    AssemblyModel a(loadAssembly(path), out.string());
    bool ok = a.rebuild();
    for (auto& c : a.components()) if (!c.ok) std::fprintf(stderr, "    %s: %s\n", c.name.c_str(), c.message.c_str());
    CHECK(ok);
    CHECK(a.components().size() == 5);
    CHECK(a.parts().size() == 2);  // plate + one shared pin part
    CHECK(a.document().mates.size() == 4);
    auto mp = a.massProperties();
    CHECK(mp.bodies == 5);
    CHECK(mp.volume > 0.2 * 0.12 * 0.01 * 0.9);

    ExportResult step = exportAssembly(a, (out / "pins.step").string(), {});
    std::printf("    pins.step ok=%d %s\n", step.ok, step.message.c_str());
    CHECK(step.ok && step.validated && step.bodies == 5);
    ExportResult tmf = exportAssembly(a, (out / "pins.3mf").string(), {});
    CHECK(tmf.ok && tmf.validated);
    std::string model = zipEntry((out / "pins.3mf").string(), "3D/3dmodel.model");
    CHECK(count(model, "<object ") == 2);
    CHECK(count(model, "<item ") == 5);
    ExportResult stl = exportAssembly(a, (out / "pins.stl").string(), {});
    CHECK(stl.ok && stl.validated);

    // A component pointing at a part file on disk, nested inside another assembly.
    PartModel plate(*a.document().components[0].virtualPart);
    plate.rebuild();
    savePart((out / "plate.fpprt").string(), plate.document(), &plate);
    AssemblyDocument outer;
    outer.name = "Outer";
    Component c1;
    c1.name = "Plate on disk";
    c1.path = "plate.fpprt";
    Component c2;
    c2.name = "Pin plate";
    c2.path = "pins.fpasm";
    c2.placement.t = {0, 0, 0.5};
    outer.components = {c1, c2};
    std::string outerPath = (out / "outer.fpasm").string();
    saveAssembly(outerPath, outer);
    AssemblyModel o(loadAssembly(outerPath), out.string());
    CHECK(o.rebuild());
    CHECK(o.components().size() == 6);
    Component missing;
    missing.name = "Gone";
    missing.path = "nowhere.fpprt";
    o.document().components.push_back(missing);
    CHECK(!o.rebuild());
  });

  std::printf("\n%d checks, %d failed\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
