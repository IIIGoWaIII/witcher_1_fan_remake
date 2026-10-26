shader_type spatial;
render_mode cull_disabled, unshaded;

// Approximation of the Witcher 1 "proc_water" surface. The real one is a
// reflective/refractive shader driven by per-area water settings that ship in the
// area's ARE resource, which this module does not contain, so this rebuilds the
// look from the shader's own behaviour: a dark green body, an animated ripple
// normal, and a view-dependent blend towards the sky at grazing angles.
//
// Colours are authored as sRGB and the uniforms are marked source_color, so the
// shader receives them linear and can write ALBEDO directly.

uniform vec4 deep : source_color = vec4(0.09, 0.15, 0.13, 1.0);
uniform vec4 shallow : source_color = vec4(0.16, 0.24, 0.20, 1.0);
uniform vec4 sky_color : source_color = vec4(0.55, 0.66, 0.80, 1.0);

uniform float ripple_scale = 2.1;
uniform float ripple_speed = 0.55;
uniform float ripple_strength = 0.20;
uniform float reflectivity = 0.45;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Height of a couple of crossing ripple trains, used to tilt the surface normal.
// The second train is rotated against the first so the surface does not read as
// one periodic grid.
float ripple(vec2 p, float t) {
	vec2 q = vec2(p.x * 0.94 - p.y * 0.34, p.x * 0.34 + p.y * 0.94);
	return sin(p.x * ripple_scale + t) * 0.5
		+ sin(p.y * ripple_scale * 1.31 - t * 1.17) * 0.35
		+ sin(dot(q, vec2(1.0, 1.0)) * ripple_scale * 0.57 + t * 0.61) * 0.15;
}

void fragment() {
	float t = TIME * ripple_speed;
	vec2 p = world_pos.xz;

	// Ripples are a few centimetres across, so far away they would alias into a moire
	// grid. Fade the normal detail out with distance and let the surface flatten.
	float dist = length(CAMERA_POSITION_WORLD - world_pos);
	float detail = 1.0 - smoothstep(60.0, 260.0, dist);

	// Finite difference normal, then tilt it towards the wave slope.
	float e = 0.35;
	float h = ripple(p, t);
	float hx = ripple(p + vec2(e, 0.0), t);
	float hz = ripple(p + vec2(0.0, e), t);
	vec3 n = normalize(vec3((h - hx) * ripple_strength * detail, 1.0,
		(h - hz) * ripple_strength * detail));

	vec3 view_dir = normalize(CAMERA_POSITION_WORLD - world_pos);
	float facing = clamp(dot(n, view_dir), 0.0, 1.0);

	// Schlick-ish: the flatter the view, the more the surface becomes a mirror.
	float fres = pow(1.0 - facing, 3.0);

	// Body colour drifts slightly with the ripple so the surface is not a flat slab.
	vec3 body = mix(deep.rgb, shallow.rgb, 0.5 + 0.5 * h);

	vec3 col = mix(body, sky_color.rgb, fres * reflectivity);
	ALBEDO = col;
}
