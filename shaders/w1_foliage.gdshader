shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_opaque;

// Foliage for the third-party trees.
//
// The area geometry is unshaded: its light is baked into the lightmaps and simply
// multiplied into the albedo. The trees cannot use that bake, so they get the same
// treatment from a fixed sun direction instead - a constant ambient term plus a
// Lambert term. That keeps them in the same tonal range as the ground no matter what
// the Sky3D cycle is doing, and avoids real-time shadows that nothing would receive.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 sun_color : source_color = vec4(1.0, 0.96, 0.88, 1.0);

// Direction towards the sun, in world space. Roughly matches the noon light bake.
uniform vec3 sun_dir = vec3(-0.45, 0.82, 0.36);
uniform float sun_energy = 0.62;
uniform float ambient = 0.42;
uniform float alpha_cut = 0.35;

void fragment() {
	vec4 t = texture(albedo_tex, UV);
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Leaf cards face every direction, so half the tree would go black under a plain
	// Lambert term. Wrap it around instead.
	float wrap = 0.5 + 0.5 * dot(n, normalize(sun_dir));
	vec3 lit = t.rgb * (ambient + sun_energy * wrap) * sun_color.rgb;
	ALBEDO = lit;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
}
