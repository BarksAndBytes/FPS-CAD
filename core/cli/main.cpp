// fpcad — command-line access to the CAD core, for tests, CI and batch conversion.
//
//   fpcad sample <out.fpprt>                 write the sample pavilion part
//   fpcad sample-assembly <out.fpasm>        write the sample pin-plate assembly
//   fpcad info <file>                        rebuild and print features, bodies, mass
//   fpcad export <file> <out> [--units mm|cm|m|in] [--schema AP242|AP214] [--ascii]
//   fpcad set <file.fpprt> "<feature>.<param>=<value>"   edit a parameter, rebuild, save
//   fpcad push <file.fpprt> x y z dx dy dz <delta>       push/pull the face hit by a ray

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "fpcad/Assembly.h"
#include "fpcad/Export.h"
#include "fpcad/Expression.h"
#include "fpcad/FileIO.h"
#include "fpcad/Model.h"

using namespace fpcad;

namespace {

int usage() {
  std::fprintf(stderr,
               "usage:\n"
               "  fpcad sample <out.fpprt>\n"
               "  fpcad sample-assembly <out.fpasm>\n"
               "  fpcad info <file>\n"
               "  fpcad export <file> <out.step|.igs|.stl|.3mf> [--units mm] [--schema AP242] [--ascii]\n"
               "  fpcad set <file.fpprt> \"<feature>.<param>=<value>\"\n"
               "  fpcad push <file.fpprt> x y z dx dy dz <delta>\n");
  return 2;
}

void printReport(const PartModel& m) {
  const auto& r = m.lastReport();
  for (auto& st : r.features) {
    const Feature* f = m.document().find(st.featureId);
    std::string name = f ? f->name + " (" + f->type + ")" : st.featureId;
    std::printf("  %-4s %s%s%s\n", st.ok ? "ok" : "FAIL", name.c_str(), st.message.empty() ? "" : " - ",
                st.message.c_str());
  }
  std::printf("  rebuilt in %.1f ms\n", r.milliseconds);
}

void printMass(const MassProperties& mp, const std::string& units) {
  double k = 1.0 / unitScale(units);
  std::printf("bodies %d  volume %.6g %s^3  area %.6g %s^2  mass %.4g kg  centre (%.4g, %.4g, %.4g) %s\n",
              mp.bodies, mp.volume * k * k * k, units.c_str(), mp.area * k * k, units.c_str(), mp.mass,
              mp.centreOfMass[0] * k, mp.centreOfMass[1] * k, mp.centreOfMass[2] * k, units.c_str());
}

std::string dirOf(const std::string& path) {
  auto p = std::filesystem::path(path).parent_path();
  return p.empty() ? "." : p.string();
}

int info(const std::string& path) {
  FileKind k = fileKind(path);
  if (k == FileKind::Part) {
    PartModel m(loadPart(path));
    m.rebuild();
    std::printf("part \"%s\" (%s), %zu features, %d cached bodies\n", m.document().name.c_str(),
                m.document().units.c_str(), m.document().features.size(), cachedBodyCount(path));
    printReport(m);
    printMass(m.massProperties(), m.document().units);
    return m.lastReport().ok ? 0 : 1;
  }
  if (k == FileKind::Assembly) {
    AssemblyModel a(loadAssembly(path), dirOf(path));
    bool ok = a.rebuild();
    std::printf("assembly \"%s\", %zu components placed, %zu distinct parts, %zu mates\n",
                a.document().name.c_str(), a.components().size(), a.parts().size(), a.document().mates.size());
    for (auto& c : a.components())
      std::printf("  %-4s %s%s%s\n", c.ok ? "ok" : "FAIL", c.name.c_str(), c.message.empty() ? "" : " - ",
                  c.message.c_str());
    printMass(a.massProperties(), a.document().units);
    return ok ? 0 : 1;
  }
  std::fprintf(stderr, "%s is not an FPS-CAD part or assembly\n", path.c_str());
  return 1;
}

int exportFile(const std::string& in, const std::string& out, const ExportOptions& o) {
  ExportResult r;
  FileKind k = fileKind(in);
  if (k == FileKind::Part) {
    PartModel m(loadPart(in));
    m.rebuild();
    r = exportPart(m, out, o);
  } else if (k == FileKind::Assembly) {
    AssemblyModel a(loadAssembly(in), dirOf(in));
    a.rebuild();
    r = exportAssembly(a, out, o);
  } else {
    std::fprintf(stderr, "%s is not an FPS-CAD part or assembly\n", in.c_str());
    return 1;
  }
  std::printf("%s %s: %d bodies%s, %s\n", r.ok ? "exported" : "FAILED", out.c_str(), r.bodies,
              r.triangles ? (", " + std::to_string(r.triangles) + " triangles").c_str() : "",
              r.message.c_str());
  return r.ok ? 0 : 1;
}

int setParam(const std::string& path, const std::string& assignment) {
  auto eq = assignment.find('=');
  auto dot = assignment.rfind('.', eq);
  if (eq == std::string::npos || dot == std::string::npos) return usage();
  std::string feature = assignment.substr(0, dot), param = assignment.substr(dot + 1, eq - dot - 1);
  std::string value = assignment.substr(eq + 1);
  PartModel m(loadPart(path));
  Feature* target = nullptr;
  for (auto& f : m.document().features) if (f.name == feature || f.id == feature) target = &f;
  if (!target) {
    std::fprintf(stderr, "no feature named \"%s\"\n", feature.c_str());
    return 1;
  }
  char* end = nullptr;
  double num = std::strtod(value.c_str(), &end);
  bool plainNumber = end && *end == '\0';
  // Plain numbers are in document units, like typing them into the parameter panel.
  if (plainNumber) target->params[param] = num * unitScale(m.document().units);
  else target->params[param] = value;
  m.rebuild();
  printReport(m);
  if (!m.lastReport().ok) {
    std::fprintf(stderr, "not saved: the change breaks the model\n");
    return 1;
  }
  savePart(path, m.document(), &m);
  std::printf("saved %s\n", path.c_str());
  return 0;
}

int push(const std::string& path, char** v) {
  PartModel m(loadPart(path));
  m.rebuild();
  double k = unitScale(m.document().units);
  Vec3 o{std::atof(v[0]) * k, std::atof(v[1]) * k, std::atof(v[2]) * k};
  Vec3 d{std::atof(v[3]), std::atof(v[4]), std::atof(v[5])};
  double delta = std::atof(v[6]) * k;
  auto hit = m.pick(o, d);
  if (!hit) {
    std::fprintf(stderr, "the ray hits nothing\n");
    return 1;
  }
  std::string msg;
  if (!m.pushPull(*hit, delta, &msg)) {
    std::fprintf(stderr, "push/pull refused: %s\n", msg.c_str());
    return 1;
  }
  std::printf("%s\n", msg.c_str());
  savePart(path, m.document(), &m);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) return usage();
  std::string cmd = argv[1];
  try {
    if (cmd == "sample") {
      PartModel m(PartDocument::sample());
      m.rebuild();
      savePart(argv[2], m.document(), &m);
      printReport(m);
      return m.lastReport().ok ? 0 : 1;
    }
    if (cmd == "sample-assembly") {
      saveAssembly(argv[2], AssemblyDocument::sample());
      return info(argv[2]);
    }
    if (cmd == "info") return info(argv[2]);
    if (cmd == "export" && argc >= 4) {
      ExportOptions o;
      for (int i = 4; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--units") && i + 1 < argc) o.units = argv[++i];
        else if (!std::strcmp(argv[i], "--schema") && i + 1 < argc) o.stepSchema = argv[++i];
        else if (!std::strcmp(argv[i], "--ascii")) o.binaryStl = false;
        else return usage();
      }
      return exportFile(argv[2], argv[3], o);
    }
    if (cmd == "set" && argc == 4) return setParam(argv[2], argv[3]);
    if (cmd == "push" && argc == 10) return push(argv[2], argv + 3);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "error: %s\n", e.what());
    return 1;
  }
  return usage();
}
