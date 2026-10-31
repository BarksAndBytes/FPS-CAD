extends RefCounted
## Solid lines of a fixed on-screen width (Godot's own lines are one pixel, which reads as faint
## on a phone). Each segment becomes a quad that the fat_lines shader turns to face the camera and
## widens in screen space, so outlines look the same from across the room or up close.

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float width_px = 3.0;

void vertex() {
	// Pull both ends very slightly towards the camera so the line wins over the faces it lies on.
	vec4 va = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 vb = MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0);
	va.xyz *= 0.997;
	vb.xyz *= 0.997;
	vec4 a = PROJECTION_MATRIX * va;
	vec4 b = PROJECTION_MATRIX * vb;
	vec2 half_vp = VIEWPORT_SIZE * 0.5;
	vec2 sa = a.xy / a.w * half_vp;
	vec2 sb = b.xy / b.w * half_vp;
	vec2 d = sb - sa;
	d = length(d) > 1e-5 ? normalize(d) : vec2(1.0, 0.0);
	vec2 n = vec2(-d.y, d.x) * CUSTOM0.w * width_px * 0.5;
	a.xy += n / half_vp * a.w;
	POSITION = a;
}

void fragment() {
	ALBEDO = color.rgb;
}
"""

static var _shader: Shader


## A mesh drawing every pair of points (a line list, as CadPart.build_edges returns) as a solid line.
static func mesh(points: PackedVector3Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var custom := PackedFloat32Array()
	var idx := PackedInt32Array()
	var segments := points.size() / 2
	verts.resize(segments * 4)
	custom.resize(segments * 16)
	idx.resize(segments * 6)
	for s in segments:
		var a := points[s * 2]
		var b := points[s * 2 + 1]
		var ends := [[a, b, -1.0], [a, b, 1.0], [b, a, 1.0], [b, a, -1.0]]
		for k in 4:
			var e: Array = ends[k]
			var here: Vector3 = e[0]
			var other: Vector3 = e[1]
			verts[s * 4 + k] = here
			custom[(s * 4 + k) * 4] = other.x
			custom[(s * 4 + k) * 4 + 1] = other.y
			custom[(s * 4 + k) * 4 + 2] = other.z
			custom[(s * 4 + k) * 4 + 3] = e[2]
		var base := s * 4
		idx[s * 6] = base
		idx[s * 6 + 1] = base + 1
		idx[s * 6 + 2] = base + 2
		idx[s * 6 + 3] = base
		idx[s * 6 + 4] = base + 2
		idx[s * 6 + 5] = base + 3
	var m := ArrayMesh.new()
	if segments == 0:
		return m
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = idx
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return m


static func material(color := Color.BLACK, width_px := 3.0) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("width_px", width_px)
	return mat
