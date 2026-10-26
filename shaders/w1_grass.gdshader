shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_opaque;

// Witcher 1 grass clump. The meshes and the blade textures are the original ones
// (trawa_set* models, trw_* textures); the original lights them dynamically, which
// does not exist here because the ground is baked, so the tint comes from the area
// .set file (DiffuseRed/Green/Blue, 0.588 for every type in this area).

uniform sampler2D d0 : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 tint : source_color = vec3(0.588, 0.588, 0.588);
uniform float light = 1.0;
uniform float sway = 0.05;
uniform float wind_speed = 1.4;

void vertex() {
	// The clumps are modelled with their base at y = 0, so height is a usable
	// stiffness weight: tips move, roots stay planted.
	float phase = dot(MODEL_MATRIX[3].xz, vec2(0.31, 0.23));
	float t = TIME * wind_speed + phase;
	vec2 push = vec2(sin(t), cos(t * 0.77)) * sway;
	VERTEX.xz += push * max(VERTEX.y, 0.0) * 8.0;
}

void fragment() {
	vec4 t = texture(d0, UV);
	ALBEDO = t.rgb * tint * light;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.35;
}
