// Terrain3D ground for the Vizima comparison scene.
//
// The visible ground is the original W1T surface rendered from above (albedo
// times baked noon lightmap) into a 1 m/px color map. Terrain3D drapes that image
// over the baked heightfield, so this shader only needs the projected color map,
// the height data for the clipmap vertices and the control map for holes.
//
// It is unshaded on purpose: the original ground is unshaded and lit entirely by
// its lightmap, so adding dynamic lighting on top would double the light.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded, skip_vertex_transform;

#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2

uniform vec3 _camera_pos = vec3(0.0);
uniform float _mesh_size = 48.0;
uniform uint _background_mode = 0u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0;
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // 1 / region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
uniform highp sampler2DArray _color_maps : source_color, filter_linear_mipmap_anisotropic, repeat_disable;

// Returns region-local XY and the texture-array layer, or -1 outside a region.
ivec3 get_index_coord(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv, _region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, SKIP_PASS, FRAGMENT_PASS); i++) {
		if ((layer_index == -1 && _background_mode == 0u) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor(r_uv * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = _region_map[pos.y * _region_map_size + pos.x] * bounds - 1;
		}
	}
	return ivec3(ivec2(mod(r_uv, _region_size)), layer_index);
}

// UV2 is world XZ divided by region size. Returns region-local UV and layer.
vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[pos.y * _region_map_size + pos.x] * bounds - 1;
	int safe_layer = max(layer_index, 0);
	return vec3(uv2 - _region_locations[safe_layer], float(layer_index));
}

void vertex() {
	vec3 v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp = smoothstep(0.55, 0.95,
		(v_vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0));
	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
	vec2 shift = (scale < _vertex_spacing + 1e-6) ?
		mix(v_fract, vec2(v_fract.x, -v_fract.y),
			round(fract(round(mod(v_vertex.z * _vertex_density, 4.0)) *
			round(mod(v_vertex.x * _vertex_density, 4.0)) * 0.25))) :
		v_fract * round((fract(v_vertex.xz * 0.25 / scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	UV = v_vertex.xz * _vertex_density;
	UV2 = UV * _region_texel_size + vec2(0.5 * _region_texel_size);

	ivec3 v_region = get_index_coord(start_pos, VERTEX_PASS);
	uint control = v_region.z >= 0 ? floatBitsToUint(texelFetch(_control_maps, v_region, 0).r) : 0u;
	bool hole = bool(control >> 2u & 0x1u);

	if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer) &&
			(hole || (_background_mode == 0u && v_region.z == -1))) {
		v_vertex.x = 0.0 / 0.0;
	} else {
		ivec3 uv_a = get_index_coord(start_pos, VERTEX_PASS);
		ivec3 uv_b = get_index_coord(end_pos, VERTEX_PASS);
		if (uv_a.z < 0 || uv_b.z < 0) {
			v_vertex.x = 0.0 / 0.0;
		} else {
			float h = mix(texelFetch(_height_maps, uv_a, 0).r,
				texelFetch(_height_maps, uv_b, 0).r, vertex_lerp);
			v_vertex.y = h;

			float u = mix(texelFetch(_height_maps, get_index_coord(start_pos + vec2(1, 0), VERTEX_PASS), 0).r,
				texelFetch(_height_maps, get_index_coord(end_pos + vec2(1, 0), VERTEX_PASS), 0).r, vertex_lerp);
			float v = mix(texelFetch(_height_maps, get_index_coord(start_pos + vec2(0, 1), VERTEX_PASS), 0).r,
				texelFetch(_height_maps, get_index_coord(end_pos + vec2(0, 1), VERTEX_PASS), 0).r, vertex_lerp);
			vec3 n = normalize(vec3(h - u, _vertex_spacing, h - v));

			vec3 w_tangent = normalize(cross(n, vec3(0.0, 0.0, 1.0)));
			vec3 w_binormal = normalize(cross(n, w_tangent));
			NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
			BINORMAL = normalize((VIEW_MATRIX * vec4(w_binormal, 0.0)).xyz);
			TANGENT = normalize((VIEW_MATRIX * vec4(w_tangent, 0.0)).xyz);
		}
	}

	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
}

void fragment() {
	vec2 uv2 = UV2;
	vec3 region_uv = get_index_uv(uv2);
	vec4 color_map = region_uv.z > -1.0
		? textureLod(_color_maps, region_uv, 0.0)
		: vec4(1.0, 1.0, 1.0, 0.5);
	ALBEDO = color_map.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
