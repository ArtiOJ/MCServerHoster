// BlueMap lowres tiles: a grid displaced by the height in the bottom half of the tile PNG,
// coloured by its top half (BlueMap's shader, ported). Level 1 gives way to hires tiles
// where they are loaded (bm_hires_mask: one texel per hires tile around bm_hires_origin).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

global uniform float bm_distance;
global uniform float bm_sunlight;
global uniform float bm_ambient;
global uniform vec3 bm_void_color;
global uniform sampler2D bm_hires_mask : filter_nearest, repeat_disable;
global uniform vec2 bm_hires_origin;
global uniform float bm_hires_mask_size;
global uniform vec2 bm_hires_translate;
global uniform float bm_hires_tile_size;
// Top-down view: the camera sits far above, so distances are the zoom (bm_distance).
global uniform bool bm_flat;

uniform sampler2D tile_texture : filter_nearest, repeat_disable;
uniform vec2 texture_size = vec2(501.0, 1002.0);
uniform vec2 tile_size = vec2(500.0, 500.0);
uniform float lod = 1.0;
uniform float lod_scale = 1.0;

varying vec3 v_position;
varying vec3 v_world;
varying float v_distance;

float meta_to_height(vec4 meta) {
	float h = meta.g * 65280.0 + meta.b * 255.0;
	return h >= 32768.0 ? -(65535.0 - h) : h;
}

vec2 color_uv(vec2 pos) {
	return vec2(pos.x / texture_size.x, min(pos.y, tile_size.y) / texture_size.y);
}

vec2 meta_uv(vec2 pos) {
	return vec2(pos.x / texture_size.x, pos.y / texture_size.y + 0.5);
}

void vertex() {
	v_position = VERTEX;
	vec4 meta = textureLod(tile_texture, meta_uv(VERTEX.xz), 0.0);
	// A small tilt keeps overlapping levels from fighting.
	v_position.y = meta_to_height(meta) + 1.0 - VERTEX.x * 0.0001 - VERTEX.z * 0.0002;
	VERTEX.y = v_position.y;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_distance = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	if (lod == 1.0 && bm_distance < 1000.0) {
		vec2 tile = floor((v_world.xz - bm_hires_translate) / bm_hires_tile_size) - bm_hires_origin;
		if (tile.x >= 0.0 && tile.y >= 0.0 && tile.x < bm_hires_mask_size && tile.y < bm_hires_mask_size
				&& texelFetch(bm_hires_mask, ivec2(tile), 0).r > 0.75) {
			discard;
		}
	}
	vec4 color = texture(tile_texture, color_uv(v_position.xz));
	if (bm_distance < 800.0 && color.a == 0.0) {
		discard;
	}
	// Coarser levels give way near the camera.
	if (lod > 1.0 && (bm_flat ? bm_distance * 0.25 : v_distance) < 10.0 * lod_scale * lod) {
		discard;
	}
	vec4 meta = texture(tile_texture, meta_uv(v_position.xz));
	float height = meta_to_height(meta);
	float height_x = meta_to_height(texture(tile_texture, meta_uv(v_position.xz + vec2(1.0, 0.0))));
	float height_z = meta_to_height(texture(tile_texture, meta_uv(v_position.xz + vec2(0.0, 1.0))));
	float diff = ((height - height_x) + (height - height_z)) / lod_scale;
	float shade = clamp(diff * 0.06, -0.2, 0.04);
	float ao = 0.0;
	float ao_strength = 0.0;
	float dist_fac = smoothstep(200.0, 600.0, bm_distance);
	if (lod == 1.0) {
		ao_strength = smoothstep(PI - 0.8, PI - 0.2, acos(-clamp(VIEW_MATRIX[1][2], 0.0, 1.0)));
		ao_strength *= 1.0 - dist_fac;
		if (ao_strength > 0.0) {
			const float r = 3.0;
			const float step_size = 0.2;
			const float o = step_size / r * 0.1;
			for (float vx = -r; vx <= r; vx++) {
				for (float vz = -r; vz <= r; vz++) {
					if (height - meta_to_height(texture(tile_texture, meta_uv(v_position.xz + vec2(vx * step_size, vz * step_size)))) < 0.0) {
						ao -= o;
					}
				}
			}
		}
	}
	color.rgb += mix(shade, shade * 0.3 + ao, ao_strength);
	float light = mix(meta.r * 255.0, 15.0, bm_sunlight);
	color.rgb *= mix(bm_ambient, 1.0, light / 15.0);
	// Transparent texels are void.
	vec3 void_color = bm_void_color * max(bm_sunlight * bm_sunlight, bm_ambient);
	ALBEDO = mix(void_color, color.rgb, color.a);
}
