shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never;

#include "res://assets/shaders/bluemap_hires.gdshaderinc"

void fragment() {
	vec4 color = block_color(UV, face_normal(dFdx(v_world), dFdy(v_world), CAMERA_POSITION_WORLD - v_world));
	if (color.a <= 0.01) {
		discard;
	}
	ALBEDO = color.rgb;
	ALPHA = color.a;
}
