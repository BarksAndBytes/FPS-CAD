#include "fpcad/FileIO.h"

#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <functional>
#include <map>
#include <sstream>

#include <BinTools.hxx>
#include <TopoDS_Shape.hxx>
#include <miniz.h>

#include "fpcad/Model.h"

namespace fpcad {
namespace {

const char* kAppVersion = "0.1.0";

std::string isoNow() {
  std::time_t t = std::time(nullptr);
  char buf[32];
  std::strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", std::gmtime(&t));
  return buf;
}

std::string hashOf(const std::string& s) {
  // FNV-1a 64-bit: enough to tell whether cached geometry still matches the history.
  uint64_t h = 1469598103934665603ull;
  for (unsigned char c : s) { h ^= c; h *= 1099511628211ull; }
  char buf[17];
  std::snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(h));
  return buf;
}

class ZipWriter {
public:
  explicit ZipWriter(const std::string& path) : path_(path) {
    mz_zip_zero_struct(&zip_);
    if (!mz_zip_writer_init_file(&zip_, path.c_str(), 0)) throw FileError("cannot write " + path);
  }
  ~ZipWriter() { if (open_) mz_zip_writer_end(&zip_); }
  void add(const std::string& name, const std::string& data) {
    if (!mz_zip_writer_add_mem(&zip_, name.c_str(), data.data(), data.size(), MZ_DEFAULT_COMPRESSION))
      throw FileError("cannot add " + name + " to " + path_);
  }
  void finish() {
    bool ok = mz_zip_writer_finalize_archive(&zip_);
    mz_zip_writer_end(&zip_);
    open_ = false;
    if (!ok) throw FileError("cannot finish " + path_);
  }

private:
  std::string path_;
  mz_zip_archive zip_;
  bool open_ = true;
};

class ZipReader {
public:
  explicit ZipReader(const std::string& path) : path_(path) {
    mz_zip_zero_struct(&zip_);
    if (!mz_zip_reader_init_file(&zip_, path.c_str(), 0))
      throw FileError(path + " is not a readable FPS-CAD file");
  }
  ~ZipReader() { mz_zip_reader_end(&zip_); }
  bool has(const std::string& name) { return mz_zip_reader_locate_file(&zip_, name.c_str(), nullptr, 0) >= 0; }
  std::string read(const std::string& name) {
    size_t size = 0;
    void* p = mz_zip_reader_extract_file_to_heap(&zip_, name.c_str(), &size, 0);
    if (!p) throw FileError(path_ + " is missing " + name);
    std::string s(static_cast<const char*>(p), size);
    mz_free(p);
    return s;
  }
  Json json(const std::string& name) {
    try {
      return Json::parse(read(name));
    } catch (const Json::exception& e) {
      throw FileError(path_ + ": " + name + " is damaged (" + e.what() + ")");
    }
  }

private:
  std::string path_;
  mz_zip_archive zip_;
};

void atomicWrite(const std::string& path, const std::function<void(ZipWriter&)>& fill) {
  namespace fs = std::filesystem;
  std::string tmp = path + ".tmp";
  {
    ZipWriter z(tmp);
    fill(z);
    z.finish();
  }
  std::error_code ec;
  fs::rename(tmp, path, ec);
  if (ec) {
    fs::remove(path, ec);
    fs::rename(tmp, path, ec);
    if (ec) throw FileError("cannot replace " + path + ": " + ec.message());
  }
}

Json manifest(const char* kind, const std::string& fileId, const std::string& name,
              const std::string& units) {
  return {{"format", "fps-cad"}, {"formatVersion", kFormatVersion}, {"kind", kind},
          {"fileId", fileId},   {"name", name},                     {"units", units},
          {"app", std::string("FPS-CAD ") + kAppVersion},           {"modified", isoNow()}};
}

Json checkManifest(ZipReader& z, const std::string& path, const char* kind) {
  Json m = z.json("manifest.json");
  if (m.value("format", std::string()) != "fps-cad") throw FileError(path + " is not an FPS-CAD file");
  int v = m.value("formatVersion", 0);
  if (v > kFormatVersion)
    throw FileError(path + " was saved by a newer version of FPS-CAD (format " + std::to_string(v) +
                    "). Update the app to open it.");
  if (m.value("kind", std::string()) != kind)
    throw FileError(path + " is a " + m.value("kind", std::string("unknown")) + " file, not a " + kind);
  return m;  // older formats are migrated here as the format evolves
}

std::string partHistory(const PartDocument& d) {
  return d.featuresJson().dump() + d.variablesJson().dump() + d.units;
}

Json viewpointsJson(const PartDocument& d) {
  Json arr = Json::array();
  for (auto& v : d.viewpoints)
    arr.push_back({{"name", v.name}, {"position", v.position}, {"yaw", v.yaw}, {"pitch", v.pitch}, {"size", v.size}});
  return arr;
}

}  // namespace

FileKind fileKind(const std::string& path) {
  try {
    ZipReader z(path);
    std::string k = z.json("manifest.json").value("kind", std::string());
    if (k == "part") return FileKind::Part;
    if (k == "assembly") return FileKind::Assembly;
  } catch (...) {
  }
  return FileKind::Unknown;
}

void savePart(const std::string& path, const PartDocument& doc, const PartModel* model) {
  atomicWrite(path, [&](ZipWriter& z) {
    Json m = manifest("part", doc.fileId, doc.name, doc.units);
    m["material"] = doc.material;
    m["density"] = doc.density;
    m["historyHash"] = hashOf(partHistory(doc));
    int bodies = 0;
    if (model && partHistory(model->document()) == partHistory(doc)) {
      for (int b = 0; b < model->bodyCount(); ++b) {
        std::ostringstream os(std::ios::binary);
        BinTools::Write(model->body(b), os);
        z.add("geometry/body-" + std::to_string(b) + ".brep", os.str());
        ++bodies;
      }
    }
    m["cachedBodies"] = bodies;
    z.add("manifest.json", m.dump(2));
    z.add("history/features.json", doc.featuresJson().dump(2));
    z.add("history/variables.json", doc.variablesJson().dump(2));
    z.add("views/viewpoints.json", viewpointsJson(doc).dump(2));
  });
}

PartDocument loadPart(const std::string& path) {
  ZipReader z(path);
  Json m = checkManifest(z, path, "part");
  PartDocument d;
  d.fileId = m.value("fileId", newId());
  d.name = m.value("name", std::string("Part"));
  d.units = m.value("units", std::string("mm"));
  d.material = m.value("material", d.material);
  d.density = m.value("density", d.density);
  try {
    d.loadFeatures(z.json("history/features.json"));
    d.loadVariables(z.has("history/variables.json") ? z.json("history/variables.json") : Json::array());
  } catch (const FileError&) {
    throw;
  } catch (const std::exception& e) {
    throw FileError(path + ": feature history is damaged (" + e.what() + ")");
  }
  if (z.has("views/viewpoints.json")) {
    for (auto& v : z.json("views/viewpoints.json")) {
      Viewpoint vp;
      vp.name = v.value("name", std::string());
      vp.position = v.value("position", vp.position);
      vp.yaw = v.value("yaw", 0.0);
      vp.pitch = v.value("pitch", 0.0);
      vp.size = v.value("size", 1.0);
      d.viewpoints.push_back(vp);
    }
  }
  return d;
}

int cachedBodyCount(const std::string& path) {
  ZipReader z(path);
  Json m = checkManifest(z, path, "part");
  PartDocument d = loadPart(path);
  if (m.value("historyHash", std::string()) != hashOf(partHistory(d))) return 0;
  int n = 0;
  for (int b = 0; b < m.value("cachedBodies", 0); ++b) {
    std::istringstream is(z.read("geometry/body-" + std::to_string(b) + ".brep"), std::ios::binary);
    TopoDS_Shape s;
    BinTools::Read(s, is);
    if (!s.IsNull()) ++n;
  }
  return n;
}

void saveAssembly(const std::string& path, const AssemblyDocument& doc) {
  atomicWrite(path, [&](ZipWriter& z) {
    z.add("manifest.json", manifest("assembly", doc.fileId, doc.name, doc.units).dump(2));
    z.add("assembly/components.json", doc.componentsJson().dump(2));
    z.add("assembly/mates.json", doc.matesJson().dump(2));
  });
}

AssemblyDocument loadAssembly(const std::string& path) {
  ZipReader z(path);
  Json m = checkManifest(z, path, "assembly");
  AssemblyDocument d;
  d.fileId = m.value("fileId", newId());
  d.name = m.value("name", std::string("Assembly"));
  d.units = m.value("units", std::string("mm"));
  try {
    d.loadComponents(z.json("assembly/components.json"));
    d.loadMates(z.has("assembly/mates.json") ? z.json("assembly/mates.json") : Json::array());
  } catch (const FileError&) {
    throw;
  } catch (const std::exception& e) {
    throw FileError(path + ": assembly structure is damaged (" + e.what() + ")");
  }
  return d;
}

}  // namespace fpcad
