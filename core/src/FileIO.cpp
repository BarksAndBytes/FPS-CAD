#include "fpcad/FileIO.h"
#include "fpcad/Drawing.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <functional>
#include <map>
#include <set>
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
  std::string imported;
  for (auto& [id, data] : d.imports) imported += id + ":" + hashOf(data) + ";";
  return d.featuresJson().dump() + d.variablesJson().dump() + d.units + imported + "|rollback:" + std::to_string(d.rollback);
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
    if (k == "drawing") return FileKind::Drawing;
  } catch (...) {
  }
  return FileKind::Unknown;
}

void savePart(const std::string& path, const PartDocument& doc, const PartModel* model) {
  atomicWrite(path, [&](ZipWriter& z) {
    Json m = manifest("part", doc.fileId, doc.name, doc.units);
    m["material"] = doc.material;
    if (!doc.massUnits.empty()) m["massUnits"] = doc.massUnits;
    m["density"] = doc.density;
    m["rollback"] = doc.rollback;
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
    Json importIds = Json::array();
    for (auto& [id, data] : doc.imports) {
      z.add("imports/" + id + ".brep", data);
      importIds.push_back(id);
    }
    z.add("imports/index.json", importIds.dump());
    z.add("views/boards.json", (doc.boards.is_array() ? doc.boards : Json::array()).dump(2));
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
  d.massUnits = m.value("massUnits", std::string());
  d.density = m.value("density", d.density);
  d.rollback = m.value("rollback", -1);
  try {
    d.loadFeatures(z.json("history/features.json"));
    d.loadVariables(z.has("history/variables.json") ? z.json("history/variables.json") : Json::array());
  } catch (const FileError&) {
    throw;
  } catch (const std::exception& e) {
    throw FileError(path + ": feature history is damaged (" + e.what() + ")");
  }
  if (z.has("imports/index.json")) {
    for (auto& id : z.json("imports/index.json")) {
      std::string name = "imports/" + id.get<std::string>() + ".brep";
      if (!z.has(name)) throw FileError(path + ": " + name + " is missing");
      d.imports[id.get<std::string>()] = z.read(name);
    }
  }
  if (z.has("views/boards.json")) {
    try {
      Json b = z.json("views/boards.json");
      if (b.is_array()) d.boards = b;
    } catch (const std::exception&) {
      // A damaged layout only loses the boards, never the part.
    }
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

namespace {

const char* kBase64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string base64Encode(const std::string& in) {
  std::string out;
  out.reserve((in.size() + 2) / 3 * 4);
  size_t i = 0;
  for (; i + 2 < in.size(); i += 3) {
    unsigned v = (unsigned char)in[i] << 16 | (unsigned char)in[i + 1] << 8 | (unsigned char)in[i + 2];
    out += kBase64[v >> 18 & 63];
    out += kBase64[v >> 12 & 63];
    out += kBase64[v >> 6 & 63];
    out += kBase64[v & 63];
  }
  if (i < in.size()) {
    unsigned v = (unsigned char)in[i] << 16 | (i + 1 < in.size() ? (unsigned char)in[i + 1] << 8 : 0);
    out += kBase64[v >> 18 & 63];
    out += kBase64[v >> 12 & 63];
    out += i + 1 < in.size() ? kBase64[v >> 6 & 63] : '=';
    out += '=';
  }
  return out;
}

std::string base64Decode(const std::string& in) {
  int value[256];
  std::fill(value, value + 256, -1);
  for (int i = 0; i < 64; ++i) value[(unsigned char)kBase64[i]] = i;
  std::string out;
  out.reserve(in.size() / 4 * 3);
  unsigned acc = 0;
  int bits = 0;
  for (unsigned char c : in) {
    if (c == '=') break;
    if (value[c] < 0) throw FileError("part state: an imported shape isn't valid base64");
    acc = acc << 6 | value[c];
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += char(acc >> bits & 0xFF);
    }
  }
  return out;
}

}  // namespace

Json partState(const PartDocument& d, bool withImports) {
  Json j = {{"kind", "fpcad-part-state"}, {"version", 1}, {"fileId", d.fileId}, {"name", d.name},
            {"units", d.units}, {"massUnits", d.massUnits}, {"material", d.material},
            {"density", d.density}, {"rollback", d.rollback}, {"features", d.featuresJson()},
            {"variables", d.variablesJson()}, {"viewpoints", viewpointsJson(d)},
            {"boards", d.boards.is_array() ? d.boards : Json::array()}};
  if (withImports) {
    Json im = Json::object();
    for (auto& [id, data] : d.imports) im[id] = base64Encode(data);
    j["imports"] = im;
  }
  return j;
}

PartDocument partFromState(const Json& j, const PartDocument* keepImportsFrom) {
  if (!j.is_object() || j.value("kind", std::string()) != "fpcad-part-state")
    throw FileError("not a part state");
  PartDocument d;
  try {
    d.fileId = j.value("fileId", d.fileId);
    d.name = j.value("name", d.name);
    d.units = j.value("units", d.units);
    d.massUnits = j.value("massUnits", std::string());
    d.material = j.value("material", d.material);
    d.density = j.value("density", d.density);
    d.rollback = j.value("rollback", -1);
    d.loadFeatures(j.at("features"));
    d.loadVariables(j.value("variables", Json::array()));
    for (auto& v : j.value("viewpoints", Json::array())) {
      Viewpoint vp;
      vp.name = v.value("name", std::string());
      vp.position = v.value("position", vp.position);
      vp.yaw = v.value("yaw", 0.0);
      vp.pitch = v.value("pitch", 0.0);
      vp.size = v.value("size", 1.0);
      d.viewpoints.push_back(vp);
    }
    Json b = j.value("boards", Json::array());
    d.boards = b.is_array() ? b : Json::array();
  } catch (const FileError&) {
    throw;
  } catch (const std::exception& e) {
    throw FileError(std::string("part state is damaged (") + e.what() + ")");
  }
  if (keepImportsFrom) d.imports = keepImportsFrom->imports;
  if (j.contains("imports")) {
    for (auto& [id, data] : j.at("imports").items()) d.imports[id] = base64Decode(data.get<std::string>());
  }
  return d;
}

namespace {

const Json kNull;

const Json& member(const Json& j, const std::string& k) {
  return j.is_object() && j.contains(k) ? j.at(k) : kNull;
}

std::string text(const Json& j, const std::string& k) {
  const Json& v = member(j, k);
  return v.is_string() ? v.get<std::string>() : std::string();
}

// What tells items of a list apart: their key field, else (boards without an id) their kind.
std::string itemKey(const Json& item, const std::string& key) {
  if (!item.is_object()) return item.dump();
  std::string k = text(item, key);
  return !k.empty() ? k : "kind:" + text(item, "kind");
}

std::string itemLabel(const Json& item, const std::string& k) {
  std::string n = text(item, "name");
  return n.empty() ? k : n;
}

Json pick(const Json& base, const Json& theirs, const Json& mine, std::vector<std::string>& conflicts,
          const std::string& label) {
  if (mine == base || mine == theirs) return theirs;
  if (theirs == base) return mine;
  conflicts.push_back(label);
  return theirs;
}

Json mergeList(const Json& base, const Json& theirs, const Json& mine, const std::string& key,
               std::vector<std::string>& conflicts) {
  static const Json empty = Json::array();
  const Json& bl = base.is_array() ? base : empty;
  const Json& tl = theirs.is_array() ? theirs : empty;
  const Json& ml = mine.is_array() ? mine : empty;
  auto index = [&](const Json& list) {
    std::map<std::string, Json> d;
    for (auto& x : list) d[itemKey(x, key)] = x;
    return d;
  };
  auto b = index(bl), t = index(tl), m = index(ml);
  Json result = Json::array();
  for (auto& item : tl) {
    std::string k = itemKey(item, key);
    if (m.count(k)) {
      result.push_back(b.count(k) ? pick(b[k], item, m[k], conflicts, itemLabel(item, k)) : item);
    } else if (b.count(k)) {
      if (b[k] != item) {  // mine deleted it, theirs changed it: keep theirs
        result.push_back(item);
        conflicts.push_back(itemLabel(item, k) + " (deleted on one side, changed on the other)");
      }
    } else {
      result.push_back(item);  // theirs added it
    }
  }
  for (auto& [k, v] : m)
    if (b.count(k) && !t.count(k) && b[k] != v)
      conflicts.push_back(itemLabel(v, k) + " (deleted on one side, changed on the other)");
  auto find = [&](const std::string& k) -> long {
    for (size_t i = 0; i < result.size(); ++i)
      if (itemKey(result[i], key) == k) return long(i);
    return -1;
  };
  for (size_t i = 0; i < ml.size(); ++i) {  // mine's additions, after the item before them in mine
    std::string k = itemKey(ml[i], key);
    if (b.count(k) || t.count(k)) continue;
    size_t at = 0;
    for (size_t j = i; j-- > 0;) {
      long pos = find(itemKey(ml[j], key));
      if (pos >= 0) {
        at = size_t(pos) + 1;
        break;
      }
    }
    result.insert(result.begin() + long(at), ml[i]);
  }
  auto shared = [&](const Json& list) {
    std::vector<std::string> v;
    for (auto& x : list) {
      std::string k = itemKey(x, key);
      if (b.count(k) && t.count(k) && m.count(k)) v.push_back(k);
    }
    return v;
  };
  auto baseOrder = shared(bl), mineOrder = shared(ml);
  if (shared(tl) == baseOrder && mineOrder != baseOrder) {  // only mine moved items: mine's order
    std::set<std::string> moved(mineOrder.begin(), mineOrder.end());
    std::vector<size_t> slots;
    std::map<std::string, Json> byKey;
    for (size_t i = 0; i < result.size(); ++i) {
      std::string k = itemKey(result[i], key);
      byKey[k] = result[i];
      if (moved.count(k)) slots.push_back(i);
    }
    for (size_t n = 0; n < slots.size() && n < mineOrder.size(); ++n) result[slots[n]] = byKey[mineOrder[n]];
  }
  return result;
}

// The id of the first feature the rollback bar holds back, or "" when it is at the end.
std::string barId(const Json& state) {
  const Json& r = member(state, "rollback");
  const Json& f = member(state, "features");
  if (!r.is_number() || !f.is_array()) return "";
  long i = r.get<long>();
  return i >= 0 && i < long(f.size()) ? itemKey(f[size_t(i)], "id") : "";
}

}  // namespace

StateMerge mergePartStates(const Json& base, const Json& theirs, const Json& mine) {
  StateMerge r;
  r.state = theirs;
  static const std::map<std::string, std::string> lists = {
      {"features", "id"}, {"variables", "name"}, {"viewpoints", "name"}, {"boards", "id"}};
  for (auto& [k, key] : lists)
    r.state[k] = mergeList(member(base, k), member(theirs, k), member(mine, k), key, r.conflicts);
  if (mine.is_object()) {
    for (auto& [k, v] : mine.items()) {
      if (lists.count(k) || k == "rollback" || k == "imports" || k == "kind" || k == "version") continue;
      r.state[k] = pick(member(base, k), member(theirs, k), v, r.conflicts, k);
    }
  }
  Json bar = pick(Json(barId(base)), Json(barId(theirs)), Json(barId(mine)), r.conflicts, "the rollback bar");
  r.state["rollback"] = -1;
  std::string id = bar.get<std::string>();
  if (!id.empty()) {
    const Json& f = r.state["features"];
    for (size_t i = 0; i < f.size(); ++i)
      if (itemKey(f[i], "id") == id) r.state["rollback"] = long(i);
  }
  return r;
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

void saveDrawing(const std::string& path, const DrawingDocument& d) {
  atomicWrite(path, [&](ZipWriter& z) {
    Json m = manifest("drawing", newId(), d.name, "mm");
    z.add("manifest.json", m.dump(2));
    Json body = {{"part", {{"path", d.partPath}, {"fileId", d.partFileId}}},
                 {"views", Json::array({{{"kind", "standard"}, {"sheet", "A3"}, {"projection", "third-angle"}}})},
                 {"hidden", d.hidden},
                 {"dimensions", d.dimensions}};
    z.add("drawing.json", body.dump(2));
  });
}

DrawingDocument loadDrawing(const std::string& path) {
  ZipReader z(path);
  Json m = checkManifest(z, path, "drawing");
  DrawingDocument d;
  d.name = m.value("name", std::string("Drawing"));
  Json body = z.json("drawing.json");
  d.partPath = body["part"].value("path", std::string());
  d.partFileId = body["part"].value("fileId", std::string());
  d.hidden = body.value("hidden", true);
  d.dimensions = body.value("dimensions", true);
  return d;
}

}  // namespace fpcad
