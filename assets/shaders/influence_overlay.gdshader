shader_type canvas_item;

// The buildable sphere: a soft, amorphous boundary drawn from one R8 texture.
//
// Deliberately built to look like the SAME IDEA as the blight overlay it sits beside, because at
// the world scale the game repeats this geometry again (colonies shielding an arc of the Heart).
// One visual language for "influence falls off with distance" is worth more than two prettier
// unrelated ones.
//
// Almost all of it is edge. The interior is barely tinted — the player is going to be looking at
// their village through this for six hours, and a wash over the whole settlement would be
// unbearable. What matters is exactly one thing: where the line is.

uniform sampler2D influence_tex : filter_nearest, repeat_disable;
uniform vec2 grid_size = vec2(128.0, 128.0);
uniform float tile_px = 16.0;

// Must match World.INFLUENCE_MIN / 255. Passed in rather than written twice, or the line the
// player sees drifts away from the line placement actually enforces — which is the worst possible
// bug in a boundary.
uniform float threshold = 0.157;

// How wide the glowing rim is, in influence units either side of the threshold.
uniform float rim = 0.10;

uniform vec4 edge_color : source_color = vec4(0.996, 0.831, 0.494, 1.0);
uniform vec4 fill_color : source_color = vec4(0.996, 0.788, 0.451, 1.0);

// Strength of the interior wash. Very low on purpose — see above.
uniform float fill_strength = 0.055;
// Peak opacity of the rim itself.
uniform float edge_strength = 0.42;

// Ordered dither, same 4x4 Bayer matrix the blight overlay uses, so the two boundaries share a
// grain. Keeps the edge reading as pixel art instead of as a smooth gradient laid over pixel art.
float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	int i = y * 4 + x;
	float m[16] = {
		0.0,  8.0,  2.0, 10.0,
		12.0, 4.0, 14.0,  6.0,
		3.0, 11.0,  1.0,  9.0,
		15.0, 7.0, 13.0,  5.0
	};
	return m[i] / 16.0;
}

// Cheap value hash, per world pixel. Wobbles the threshold so the boundary is never a clean
// circle — that irregularity is the entire brief: "amorphous, grows directionally".
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	float v = texture(influence_tex, UV).r;

	// One sample per TILE, not per screen pixel, so the wobble sits on the grid the sphere is
	// actually measured on. Sampling per pixel would shimmer as the camera moved.
	vec2 tile = floor(UV * grid_size);
	float wobble = (hash12(tile) - 0.5) * rim * 0.9;
	float line = threshold + wobble;

	// Distance from the boundary, normalised across the rim.
	float d = abs(v - line) / rim;
	float edge = clamp(1.0 - d, 0.0, 1.0);
	edge *= edge;                                  // tighten it into a line rather than a haze

	float inside = step(line, v);

	// Dither both terms against the same matrix at tileset pixel density.
	vec2 px = floor(UV * grid_size * tile_px);
	float dither = bayer4(px);

	float a = edge * edge_strength + inside * fill_strength;
	// Quantise to a handful of steps and dither the remainder. A smooth alpha ramp on a 16px
	// tileset looks like a bug; a dithered one looks drawn.
	float steps = 5.0;
	a = floor(a * steps + dither) / steps;

	vec3 rgb = mix(fill_color.rgb, edge_color.rgb, edge);
	COLOR = vec4(rgb, clamp(a, 0.0, 1.0));
}
