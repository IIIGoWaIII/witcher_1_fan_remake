shader_type spatial;
render_mode cull_disabled, unshaded;

// Witcher 1 static geometry: albedo (tiling UV1) * baked lightmap (atlas UV0).
//
// The original engine multiplied both in gamma space and added the node's ambient
// colour on top, so this mirrors that instead of doing a linear PBR multiply.
//
// Some surfaces ship with no diffuse texture at all (empty texture slot, lightmap
// only). Those are building interiors and back faces that you only see through
// windows and doorways, so the lightmap doubles as their colour: a white albedo
// would blow them out into glowing white holes.

uniform sampler2D d0 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D d1 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D d2 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D d3 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D lightmap_tex : source_color, filter_linear_mipmap, repeat_disable;

uniform bool painted = false;
uniform bool lightmap_albedo = false;
uniform bool alpha_cut = false;
uniform bool flat_shade = false;
uniform float lightmap_gain = 1.0;
uniform float ambient_add = 0.15;

void fragment() {
	vec3 lm = texture(lightmap_tex, UV).rgb;
	vec3 alb;
	float a = 1.0;

	if (flat_shade) {
		// Neither a diffuse texture nor a baked lightmap: the source data simply has no
		// surface information for this mesh, so show it as a neutral unlit grey instead
		// of a white slab.
		ALBEDO = vec3(0.32);
	} else if (lightmap_albedo) {
		alb = lm;
		lm = vec3(1.0);
	} else if (painted) {
		// COLOR holds the four texture-paint layer weights, never opacity.
		alb = texture(d0, UV2).rgb * COLOR.r;
		if (COLOR.g > 0.0) { alb += texture(d1, UV2).rgb * COLOR.g; }
		if (COLOR.b > 0.0) { alb += texture(d2, UV2).rgb * COLOR.b; }
		if (COLOR.a > 0.0) { alb += texture(d3, UV2).rgb * COLOR.a; }
	} else {
		vec4 t = texture(d0, UV2);
		alb = t.rgb;
		a = t.a;
	}

	ALBEDO = max(alb * (lm * lightmap_gain + vec3(ambient_add)), vec3(0.0));

	if (alpha_cut && !painted) {
		ALPHA = a;
		ALPHA_SCISSOR_THRESHOLD = 0.5;
	}
}
