"""Writes a GLB holding only some nodes of another, with textures re-encoded smaller.

Usage: python3 tools/repack_glb.py in.glb out.glb Node1,Node2 [u0:v0:u1:v1,...]
The optional UV rectangles are wiped clean on the colour texture (used for the whiteboard
panel). godot/models/whiteboard.glb was made with:
  python3 tools/repack_glb.py whiteboards.glb godot/models/whiteboard.glb WBoard_V1,WBoard_V1_Markers \\
    "0.0205:0.0164:0.4093:0.257,0.4153:0.5424:0.8041:0.783"
"""
import io, json, struct, sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
keep_names = set(sys.argv[3].split(","))
d = open(src, "rb").read()
clen, _ = struct.unpack("<II", d[12:20])
j = json.loads(d[20:20 + clen])
off = 20 + clen
blen, _ = struct.unpack("<II", d[off:off + 8])
binary = d[off + 8:off + 8 + blen]

nodes = j["nodes"]
parent = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}
keep = set()
for i, n in enumerate(nodes):
    if n.get("name") in keep_names:
        stack = [i]
        while stack:  # the node, everything under it ...
            k = stack.pop(); keep.add(k); stack += nodes[k].get("children", [])
        k = i
        while k in parent:  # ... and its ancestors
            k = parent[k]; keep.add(k)
old_to_new = {o: n for n, o in enumerate(sorted(keep))}
out = {"asset": j["asset"], "scene": 0, "nodes": [], "meshes": [], "accessors": [], "bufferViews": [],
       "buffers": [], "materials": [], "textures": [], "images": [], "samplers": j.get("samplers", [])}
blob = bytearray()

def add_view(data, target=None):
    while len(blob) % 4: blob.append(0)
    v = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
    if target: v["target"] = target
    blob.extend(data)
    out["bufferViews"].append(v)
    return len(out["bufferViews"]) - 1

acc_map, mesh_map = {}, {}
def copy_accessor(a):
    if a in acc_map: return acc_map[a]
    acc = dict(j["accessors"][a]); bv = j["bufferViews"][acc["bufferView"]]
    size = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}[acc["componentType"]]
    comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[acc["type"]]
    stride = bv.get("byteStride", size * comps)
    start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    data = bytearray()
    for k in range(acc["count"]):  # pack tightly
        data += binary[start + k * stride:start + k * stride + size * comps]
    acc["bufferView"] = add_view(bytes(data), bv.get("target"))
    acc.pop("byteOffset", None)
    out["accessors"].append(acc)
    acc_map[a] = len(out["accessors"]) - 1
    return acc_map[a]

for o in sorted(keep):
    n = dict(nodes[o])
    if "children" in n:
        n["children"] = [old_to_new[c] for c in n["children"] if c in keep]
    if "mesh" in n:
        m = n["mesh"]
        if m not in mesh_map:
            mesh = json.loads(json.dumps(j["meshes"][m]))
            for p in mesh["primitives"]:
                p["attributes"] = {k: copy_accessor(v) for k, v in p["attributes"].items()}
                if "indices" in p: p["indices"] = copy_accessor(p["indices"])
            out["meshes"].append(mesh)
            mesh_map[m] = len(out["meshes"]) - 1
        n["mesh"] = mesh_map[m]
    out["nodes"].append(n)
out["scenes"] = [{"nodes": [old_to_new[i] for i in j["scenes"][j.get("scene", 0)]["nodes"] if i in keep]}]

def clean(img, rects):
    """Wipes the board: each UV rect (u0:v0:u1:v1) loses its marker scribbles but keeps the
    board's soft shading (dark marks replaced by the median, then a wide blur)."""
    import numpy as np
    from PIL import ImageFilter
    a = np.asarray(img).astype(np.float32)
    W, H = img.size
    for u0, v0, u1, v1 in rects:
        x0, x1 = int(u0 * W) + 2, int(u1 * W) - 2
        y0, y1 = int(v0 * H) + 2, int(v1 * H) - 2
        region = a[y0:y1, x0:x1]
        lum = region.mean(axis=2)
        med = np.median(region.reshape(-1, 3), axis=0)
        mask = lum < np.median(lum) - 6
        region[mask] = med
        soft = Image.fromarray(region.clip(0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(24))
        a[y0:y1, x0:x1] = np.asarray(soft).astype(np.float32) * 0.6 + med * 0.4
    return Image.fromarray(a.clip(0, 255).astype(np.uint8))


# Textures: colour at 1024 px, the rest at 512 px, all JPEG; the board drawn opaque.
sizes = {}
for t in json.loads(json.dumps(j["materials"])):
    pbr = t.get("pbrMetallicRoughness", {})
    if "baseColorTexture" in pbr: sizes[pbr["baseColorTexture"]["index"]] = 1024
for i, im in enumerate(j["images"]):
    bv = j["bufferViews"][im["bufferView"]]
    img = Image.open(io.BytesIO(binary[bv.get("byteOffset", 0):bv.get("byteOffset", 0) + bv["byteLength"]])).convert("RGB")
    if sizes.get(i) == 1024 and len(sys.argv) > 4:
        img = clean(img, [[float(x) for x in r.split(":")] for r in sys.argv[4].split(",")])
    px = sizes.get(i, 512)
    img = img.resize((px, px), Image.LANCZOS)
    buf = io.BytesIO(); img.save(buf, "JPEG", quality=86)
    out["images"].append({"bufferView": add_view(buf.getvalue()), "mimeType": "image/jpeg"})
out["textures"] = j["textures"]
for m in j["materials"]:
    m = dict(m); m["alphaMode"] = "OPAQUE"; m.pop("alphaCutoff", None)
    out["materials"].append(m)
out["buffers"] = [{"byteLength": len(blob)}]
js = json.dumps(out, separators=(",", ":")).encode()
js += b" " * ((4 - len(js) % 4) % 4)
while len(blob) % 4: blob.append(0)
total = 12 + 8 + len(js) + 8 + len(blob)
with open(dst, "wb") as f:
    f.write(struct.pack("<III", 0x46546C67, 2, total))
    f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
    f.write(struct.pack("<II", len(blob), 0x004E4942)); f.write(blob)
print(dst, total, "bytes,", len(out["nodes"]), "nodes,", len(out["meshes"]), "meshes")
