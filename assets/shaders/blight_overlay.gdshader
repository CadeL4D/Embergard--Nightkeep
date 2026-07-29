shader_type canvas_item;
// Draws the whole Blight layer in one pass from a single W*H FORMAT_R8 texture
// where red = corruption intensity.
//
// The alternative — painting blight into a TileMapLayer — means thousands of
// set_cell calls every spread pass, which hitches badly on mobile. Here the CPU
// writes a ~16 KB texture every couple of seconds and the GPU does the rest, and
// we get organic crawling edges that no autotile could produce.

uniform sampler2D blight_tex : filter_nearest;
uniform vec2 grid_size = vec2(128.0, 128.0);
uniform float warp_speed = 0.08;
uniform float warp_strength = 0.7;

uniform vec3 deep_color : source_color = vec3(0.29, 0.05, 0.18);
uniform vec3 raw_color : source_color = vec3(0.62, 0.13, 0.36);
uniform vec3 rim_color : source_color = vec3(0.55, 0.18, 0.30);

void fragment() {
	// Warp the lookup so the corruption boundary crawls and breathes rather than
	// sitting on hard tile edges. Scaled by grid_size so the wobble is a fraction
	// of a tile regardless of map dimensions.
	float t = TIME * warp_speed;
	vec2 warp = vec2(
		sin(UV.y * 24.0 + t * 3.0),
		cos(UV.x * 24.0 - t * 2.3)
	) * (warp_strength / grid_size);

	float intensity = texture(blight_tex, UV + warp).r;
	if (intensity <= 0.003) {
		discard;
	}

	vec3 col = mix(raw_color, deep_color, intensity);

	// The thin low-intensity band is precisely where the Blight is currently
	// eating, so it glows — the player should be able to read the advancing
	// frontier at a glance, without a UI overlay.
	float rim = smoothstep(0.05, 0.30, intensity) * (1.0 - smoothstep(0.30, 0.55, intensity));
	col += rim_color * rim * (0.6 + 0.4 * sin(TIME * 2.0));

	COLOR = vec4(col, clamp(intensity * 1.5, 0.0, 0.88));
}
