shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform int palette_mode = 0;

void fragment() {
	vec4 source = textureLod(screen_texture, SCREEN_UV, 0.0);
	vec3 c = source.rgb;
	if (palette_mode == 1) {
		// Red/green safe: separate danger into warm orange and corruption into blue-violet.
		c = mat3(
			vec3(0.82, 0.16, 0.02),
			vec3(0.18, 0.72, 0.10),
			vec3(0.04, 0.20, 0.76)
		) * c;
	} else if (palette_mode == 2) {
		// Blue/yellow safe: preserve luminance while pushing important warm/cool axes apart.
		c = mat3(
			vec3(0.92, 0.06, 0.02),
			vec3(0.12, 0.80, 0.08),
			vec3(0.12, 0.26, 0.62)
		) * c;
	} else if (palette_mode == 3) {
		// High contrast: modest saturation and luminance expansion, not a harsh posterize.
		float luma = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(vec3(luma), c, 1.28);
		c = (c - vec3(0.5)) * 1.22 + vec3(0.5);
	}
	COLOR = vec4(clamp(c, vec3(0.0), vec3(1.0)), source.a);
}
