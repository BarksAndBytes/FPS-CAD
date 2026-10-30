// Procedural planked wood for the table: long grain along X, growth rings warped by noise, fine
// pores, and a thin seam between planks. Works in the table's local space (metres), so it needs
// no texture files and stays sharp at any player size.
shader_type spatial;

uniform vec3 light_wood : source_color = vec3(0.80, 0.60, 0.40);
uniform vec3 dark_wood : source_color = vec3(0.56, 0.37, 0.22);
uniform float plank_width = 0.16;   // metres across the grain
uniform float ring_density = 34.0;  // rings per metre across the grain
uniform float roughness_base = 0.48;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	// Grain runs along X. On the sides of the top and on the legs, use the vertical axis instead.
	vec2 p = abs(NORMAL.y) > 0.5 ? local_pos.xz : vec2(local_pos.x + local_pos.z, local_pos.y);
	float plank = floor(p.y / plank_width);
	float offset = hash(vec2(plank, 7.0)) * 40.0;          // each plank cut from a different place
	float tone = hash(vec2(plank, 3.0)) * 0.18 - 0.09;      // and a slightly different colour
	vec2 q = vec2(p.x + offset, p.y);
	float warp = noise(q * vec2(1.6, 5.0)) * 1.2 + noise(q * vec2(5.0, 18.0)) * 0.25;
	float rings = fract(q.y * ring_density + warp * 3.0);
	float ring_line = smoothstep(0.0, 0.18, rings) * (1.0 - smoothstep(0.55, 1.0, rings));
	float pores = noise(q * vec2(220.0, 9.0));
	vec3 col = mix(dark_wood, light_wood, 0.35 + 0.5 * ring_line + 0.15 * pores);
	col *= 1.0 + tone;
	// The seam between planks.
	float edge = min(fract(p.y / plank_width), 1.0 - fract(p.y / plank_width)) * plank_width;
	col *= mix(0.55, 1.0, smoothstep(0.0, 0.0012, edge));
	ALBEDO = col;
	ROUGHNESS = roughness_base + 0.2 * (1.0 - ring_line);
	SPECULAR = 0.35;
}
