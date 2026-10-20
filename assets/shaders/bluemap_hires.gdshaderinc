// BlueMap hires tiles (see Prbm): BlueMap's own shading, ported. Per-vertex colour, ambient
// occlusion, light and material come from data textures indexed by VERTEX_ID. Colours are
// written as they are: the Compatibility renderer draws 3D without a linear-to-sRGB step,
// like BlueMap's web viewer.

global uniform float bm_distance;
global uniform float bm_sunlight;
global uniform float bm_ambient;

uniform sampler2D block_atlas : filter_nearest, repeat_disable;
uniform int atlas_columns = 64;
uniform int texture_size = 16;
uniform sampler2D data_color : filter_nearest, repeat_disable;
uniform sampler2D data_ao : filter_nearest, repeat_disable;
uniform sampler2D data_sun : filter_nearest, repeat_disable;
uniform sampler2D data_block : filter_nearest, repeat_disable;
uniform sampler2D data_material : filter_nearest, repeat_disable;
uniform int data_width = 1024;

varying vec3 v_color;
varying float v_ao;
varying float v_sun;
varying float v_block;
varying flat float v_material;
varying vec3 v_world;

void vertex() {
	ivec2 p = ivec2(VERTEX_ID % data_width, VERTEX_ID / data_width);
	v_color = texelFetch(data_color, p, 0).rgb;
	v_ao = texelFetch(data_ao, p, 0).r;
	v_sun = texelFetch(data_sun, p, 0).r * 255.0;
	v_block = texelFetch(data_block, p, 0).r * 255.0;
	v_material = texelFetch(data_material, p, 0).r;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// [param normal]: the face normal, facing the camera (BlueMap's tiles are flat-shaded blocks).
vec4 block_color(vec2 uv, vec3 normal) {
	int index = int(v_material * 0.5);
	ivec2 cell = ivec2(index % atlas_columns, index / atlas_columns) * texture_size;
	ivec2 texel = clamp(ivec2(floor(fract(uv) * float(texture_size))), ivec2(0), ivec2(texture_size - 1));
	vec4 color = texelFetch(block_atlas, cell + texel, 0);
	float ao = v_ao;
	if (normal.y != 0.0 || abs(abs(normal.x) - abs(normal.z)) != 0.0) {
		vec2 light_direction = normalize(vec2(1.0, 0.5));
		float dist_fac = 1.0 - smoothstep(50.0, 1000.0, bm_distance);  // BlueMap: smoothstep(1000, 50, d), undefined in GLSL.
		ao *= 1.0 - abs(dot(normal.xz, light_direction)) * 0.4 * dist_fac;
		ao *= 1.0 - max(0.0, -normal.y) * 0.6 * dist_fac;
	}
	color.rgb *= v_color * ao;
	float light = mix(v_block, max(v_sun, v_block), bm_sunlight);
	color.rgb *= mix(bm_ambient, 1.0, light / 15.0);
	return color;
}

vec3 face_normal(vec3 dx, vec3 dy, vec3 to_camera) {
	vec3 n = normalize(cross(dx, dy));
	return dot(n, to_camera) < 0.0 ? -n : n;
}
