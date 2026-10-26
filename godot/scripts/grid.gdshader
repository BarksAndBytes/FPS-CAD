// Ground grid that stays crisp at every player size: minor lines every `minor` metres, major
// lines every 10x, CAD X axis in red and CAD Y axis in green, fading into the fog.
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform float minor = 1.0;
uniform float fog_density = 0.012;
uniform vec3 base_color : source_color = vec3(0.196, 0.231, 0.278);
uniform vec3 minor_color : source_color = vec3(0.282, 0.325, 0.373);
uniform vec3 major_color : source_color = vec3(0.424, 0.478, 0.549);
uniform vec3 x_color : source_color = vec3(0.878, 0.467, 0.373);
uniform vec3 y_color : source_color = vec3(0.471, 0.749, 0.451);
uniform vec3 fog_color : source_color = vec3(0.227, 0.271, 0.325);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid(vec2 p, float spacing, float width) {
	vec2 c = p / spacing;
	vec2 fw = fwidth(c);
	vec2 g = abs(fract(c - 0.5) - 0.5) / (fw * width);
	float line = 1.0 - min(min(g.x, g.y), 1.0);
	return line * clamp(1.0 - max(fw.x, fw.y) * 1.6, 0.0, 1.0);  // fade before lines turn to moire
}

void fragment() {
	vec2 p = world_pos.xz;
	vec3 col = base_color;
	col = mix(col, minor_color, grid(p, minor, 1.0) * 0.75);
	col = mix(col, major_color, grid(p, minor * 10.0, 1.5));
	vec2 fw = fwidth(p);
	col = mix(col, x_color, 1.0 - min(abs(p.y) / (fw.y * 2.0), 1.0));  // CAD X runs along Godot x
	col = mix(col, y_color, 1.0 - min(abs(p.x) / (fw.x * 2.0), 1.0));  // CAD Y runs along Godot -z
	float d = length(world_pos - CAMERA_POSITION_WORLD) * fog_density;
	ALBEDO = mix(col, fog_color, 1.0 - exp(-d * d));
}
